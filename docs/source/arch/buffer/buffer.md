# Buffer

Envoy's `Buffer` (`Buffer::OwnedImpl`) is one of the cornerstones of its high-performance design. In traditional network programming, continuous memory buffers like `char*` arrays or `std::vector<char>` are common. However, these can incur significant performance costs when data needs to grow or shift frequently due to memory reallocation and data copying.

To solve this, Envoy’s `Buffer` follows several core principles: **Zero-Copy**, **Slice-based Management**, and **Watermark-based Flow Control**.

## Overview

### 1. Core Data Structure: Non-contiguous “Chain of Slices”

The core design of Envoy Buffer is that it **is not a contiguous block of memory**. Instead, it internally maintains a **double-ended queue (`Buffer::SliceDeque`)**, where each element is a memory slice called `Slice`.

* **What is a `Slice`?**

  * A `Slice` is an independent and **contiguous** memory block. It usually contains a pointer to memory and a data length.
  * `Buffer::OwnedImpl` is essentially a `Buffer::SliceDeque`.
* **What are the advantages of this design?**

  * **Avoid memory reallocations and copying**: When adding data to a buffer, Envoy doesn't need to reallocate a larger block and copy old data like `std::vector`. It simply appends a new `Slice` to the end of the queue, making append operations very efficient.
  * **Efficient data drain**: When consuming data from the buffer, Envoy just removes the front `Slice` or adjusts its starting pointer—no need to shift the rest of the data.

### 2. Zero-Copy Operations

Thanks to the slice chain design, Envoy enables highly efficient zero-copy operations, which are critical to proxy performance.

* The `move()` operation:

  This is the most typical zero-copy use case. When moving data from one buffer to another (e.g., from a downstream read buffer to an upstream write buffer), Envoy does not copy any bytes. It simply transfers ownership of the source buffer’s slice deque to the destination buffer—a pointer operation that is extremely fast.

### 3. Memory Management and Allocation

To further improve efficiency and reduce fragmentation, Envoy optimizes how it allocates `Slice` memory:

* **Fixed-size memory blocks**: `Slices` are usually allocated from a memory pool and have a fixed size (e.g., 16KB). When adding small amounts of data, it tries to reuse remaining space in the last `Slice`; if insufficient, a new standard-sized `Slice` is allocated.
* **Fewer `malloc` calls**: By pooling and fixed-size allocations, Envoy reduces frequent `malloc`/`free` system calls, lowering memory management overhead.

### 4. Watermarks and Flow Control

Buffer size is key to Envoy’s network flow control:

* **High watermark**: Each connection buffer has a configured “high watermark.” When buffer size exceeds it, Envoy stops reading from the data source (e.g., downstream TCP connection). This prevents memory exhaustion when the upstream is slow—a mechanism known as **backpressure**.
* **Low watermark**: Once the buffer drains below the low watermark, Envoy resumes reading from the source.

This stop-start mechanism ensures Envoy can handle mismatched upstream/downstream speeds stably and robustly.

### 5. Linearize

Though the non-contiguous design is efficient, some scenarios (e.g., calls to external libraries requiring contiguous memory) need a single memory block. Envoy provides the `linearize()` method for this.

* `linearize(size)`: Allocates a new contiguous block and copies the specified amount of data from slices into it.
* This is a **performance-expensive** operation as it breaks the zero-copy principle. Envoy minimizes its use and only calls it when absolutely necessary.

### Summary

In summary, Envoy Proxy’s `Buffer` is a highly optimized design based on:

* **Non-contiguous memory using `Slice` chains**, avoiding expensive reallocations and shifts.
* **Efficient zero-copy operations using `move()`**, dramatically improving internal data flow performance.
* **Watermark-based flow control**, ensuring resilience under varying network conditions.

## Buffer Framework

\::: {.figure-md}
\:class: full-width

<img src="buffer-classes.drawio.svg" alt="Diagram: Buffer class diagram">

*Diagram: Buffer class diagram*
\:::
*[Open with Draw.io](https://app.diagrams.net/?ui=sketch#Uhttps%3A%2F%2Fenvoy-insider.mygraphql.com%2Fzh_CN%2Flatest%2F_images%2Fbuffer-classes.drawio.svg)*

This diagram is dense; those interested may study it in detail. A brief overview:

1. Basic buffer abstraction design:

   1. Basic read/write operations such as `Buffer::Instance`'s `add`/`prepend`
   2. Watermark concept
   3. Reservation concept
   4. Buffer Memory Account concept
2. Buffer implementation:

   1. Slice concept
   2. Slice queue via `Buffer::SliceDeque`
3. Buffer interaction with external subsystems:

   1. How flow control settings apply across subsystems
   2. How subsystems leverage buffer watermarks and flow control

## Flow Control and Buffer

In Envoy Proxy, stream buffer limits are mainly managed through **flow control mechanisms** and **HTTP/2/3 settings**.

### Flow Control and Watermarks

Envoy uses **high** and **low watermarks** to manage flow control. When a buffer (e.g., for a stream) exceeds the high watermark, Envoy signals the source (upstream/downstream) to pause sending data. Data flow resumes once the buffer drops below the low watermark.

When using **non-streaming L7 filters** (e.g., transcoders or the [HTTP buffer filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/buffer_filter)), flow control can cause **hard-limit errors** if body size exceeds configured buffer limits.

* For **requests**, if buffering is required and the body exceeds the limit, Envoy returns a **413 error** and increments `downstream_rq_too_large`.
* For **responses**, if the body must be buffered and exceeds the limit, Envoy increments `rs_too_large`, and may:

  * **Interrupt** the response (if headers are already sent)
  * Return a **500 error**

Conceptually, flow control operates at two levels:

* **Network Flow Control (L3/L4)**: TCP/IP level

  * Listener limits (downstream)
  * Cluster limits (upstream)
* **HTTP Flow Control (L7)**: HTTP level

  * HTTP/2 stream limits

### Network Flow Control

#### `listener.per_connection_buffer_limit_bytes`

Listener limits control raw data read via `read()` and buffered between Envoy and downstream.

Listener limits also propagate to the `HttpConnectionManager`. So:

* For HTTP/1.1: Limits apply per-stream to L7 HTTP buffers, capping buffered HTTP request/response body size.
* For HTTP/2 and HTTP/3: Since multiple streams share a connection, L7 and L4 buffer limits can be separately configured. The `initial_connection_window_size` applies to all L7 buffers.

For all HTTP versions, Envoy can proxy arbitrarily large bodies if filters are fully streaming. But many filters (like the transcoder or [buffer filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/buffer_filter)) require full buffering, making listener limits effective.

```yaml
static_resources:
  listeners:
    name: http
    address:
      socket_address:
        address: '::1'
        portValue: 0
    filter_chains:
      filters:
        name: envoy.filters.network.http_connection_manager
        ...
    per_connection_buffer_limit_bytes: 1024
```

#### `cluster.per_connection_buffer_limit_bytes`

This is a cluster-level soft limit on read/write buffer sizes for upstream connections. If not set, a default (typically 1MiB) applies.

It affects both the raw read amount per `read()` call and total buffered data between Envoy and upstream.

**Cluster config example**:

```yaml
clusters:
- name: my_upstream_cluster
  connect_timeout: 5s
  type: LOGICAL_DNS
  per_connection_buffer_limit_bytes: 32768 # 32 KB, useful for untrusted upstreams
  lb_policy: ROUND_ROBIN
  load_assignment:
    cluster_name: my_upstream_cluster
    endpoints:
    - lb_endpoints:
      - endpoint:
          address:
            socket_address:
              address: example.com
              port_value: 80
```

**Scope**: This setting applies to **each connection** Envoy opens to the cluster.

**Purpose**: Controls the size of user-space buffers per TCP connection (HTTP/1.1 or HTTP/2), mainly to prevent memory exhaustion.

**Nature**: It’s an **internal resource management and backpressure mechanism**. When buffer limits are hit, Envoy halts reading to propagate backpressure.

**Impact**: It affects memory usage under high concurrency or with slow upstreams/downstreams. Defaults to 1MiB if unset.

### HTTP Flow Control

#### `initial_stream_window_size`

For HTTP/2 and HTTP/3, the main control for **per-stream buffer** size is the **initial stream-level flow-control receive window**.

`initial_stream_window_size` is part of `http2_protocol_options` or `quic_protocol_options`.

* **HTTP/2**: Configurable under cluster/listener `http_protocol_options` or `http2_protocol_options`, defining soft byte limits per stream.
* **HTTP/3 (QUIC)**: Configurable via `quic_protocol_options`.

#### `initial_connection_window_size`

* **Scope**: Applies to **HTTP/2 connections**, controlling the **total connection-level window**.
* **Purpose**: HTTP/2 has both stream-level and connection-level windows. This sets the connection-wide max byte count before needing window updates.
* **Nature**: Protocol-level backpressure. When full, Envoy halts further transmission until a WINDOW\_UPDATE arrives.
* **Impact**: Influences throughput and buffer usage and is defined by the HTTP/2 spec.

Example HTTP/2 config (cluster-level):

```yaml
clusters:
- name: my_upstream_cluster
  connect_timeout: 5s
  type: LOGICAL_DNS
  lb_policy: ROUND_ROBIN
  typed_extension_protocol_options:
    envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
      "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
      explicit_http_config:
        http2_protocol_options:
          initial_stream_window_size: ...
          initial_connection_window_size: ...
  load_assignment:
    cluster_name: my_upstream_cluster
    endpoints:
    - lb_endpoints:
      - endpoint:
          address:
            socket_address:
              address: example.com
              port_value: 80
```

### Why These Settings Matter

* **Resource Management**: Limiting buffer sizes prevents Envoy from consuming excessive memory, especially when upstreams are slow.
* **Flow Control**: Critical for **backpressure**, ensuring slow receivers aren't overwhelmed—avoiding OOM.
* **DDoS Protection**: Buffers can shield upstreams from slowloris-style attacks by fully buffering requests at Envoy speed.

## References

* [How do I configure flow control?](https://www.envoyproxy.io/docs/envoy/latest/faq/configuration/flow_control#how-do-i-configure-flow-control)

