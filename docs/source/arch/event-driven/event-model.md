---
typora-root-url: ../../
---

# Event-Driven Framework

## Design

Everyone sees Envoy as a proxy, mainly implementing request forwarding with customizable logic. That’s not wrong. But like other middleware that require high throughput and low latency, the design must take into account load scheduling and flow control. A good scheduling mechanism should balance throughput, response time, and resource footprint.

:::{figure-md} Figure: Event-Driven Framework Design

<img src="/arch/event-driven/event-driven.assets/event-model.drawio.svg" alt="Figure: Event-Driven Framework Design">

*Figure: Event-Driven Framework Design*
:::
*[Open in Draw.io](https://app.diagrams.net/?ui=sketch#Uhttps%3A%2F%2Fenvoy-insider.mygraphql.com%2Fzh_CN%2Flatest%2F_images%2Fevent-model.drawio.svg)*

1. Dispatcher thread event loop: The `Dispatcher Thread` waits for events (epoll wait), and processes them when timeout occurs or events are triggered.

2. The following events can wake up epoll wait:

   - Receiving inter-thread post callback messages. Mainly used for updating Thread Local Storage (TLS) data, such as cluster/stats updates.
     - Dispatcher handles inter-thread events.

   - Timer timeout events

   - File/socket/inotify events

   - Internal active events. Events triggered explicitly by other threads or the dispatcher thread itself.

3. Event handling

One full loop of event processing includes the above three steps. This full cycle is called an `event loop`, or sometimes an `event loop iteration`.

## Implementation

The above describes how event processing works at the kernel syscall level. Now we’ll look at how it is abstracted and encapsulated in Envoy's codebase.

Envoy uses `libevent`, a C-based event library, and adds further abstraction with C++ OOP wrappers.

:::{figure-md} Figure: Envoy Event Abstraction Model

<img src="/arch/event-driven/event-driven.assets/abstract-event-model.drawio.svg" alt="Figure: Envoy Event Abstraction Model">

*Figure: Envoy Event Abstraction Model*
:::
*[Open in Draw.io](https://app.diagrams.net/?ui=sketch#Uhttps%3A%2F%2Fenvoy-insider.mygraphql.com%2Fzh_CN%2Flatest%2F_images%2Fabstract-event-model.drawio.svg)*

How do you quickly understand the core logic of a project that makes heavy (even excessive) use of OOP encapsulation and design patterns, without getting lost in the sea of source code? The answer: follow the main thread. For Envoy’s event handling, that thread starts with the core `libevent` objects:

- `libevent::event_base`
- `libevent::event`

If you're unfamiliar with libevent, check the section *Core Concepts of libevent* in this book.

- `libevent::event` is wrapped in `ImplBase` objects.
- `libevent::event_base` is included in `LibeventScheduler` ← `DispatcherImpl` ← `WorkerImpl` ← `ThreadImplPosix`

Different types of `libevent::event` are further wrapped into different `ImplBase` subclasses:
- `TimerImpl` – used for timer-based functions like connection timeouts or idle timeouts.
- `SchedulableCallbackImpl` – Under heavy load, Envoy needs to balance event responsiveness with throughput. To prevent a single `event loop` from doing too much work and delaying subsequent event handling, certain internal or timed processes can be scheduled to complete at the end of the current `event loop` or be deferred to the next one. `SchedulableCallbackImpl` encapsulates this kind of schedulable task. Use cases include thread callback posts and retry logic.
- `FileEventImpl` – handles file/socket events.

Additional details are already well explained in the diagram above, so we won’t elaborate further.




## Extended reading

If you are interested in studying the implementation details, I recommend checking out the articles on my Blog:

 - [Reverse Engineering and Cloud Native Field Analysis Part3 -- eBPF Trace Istio/Envoy Event Driven Model, Connection Establishment, TLS Handshake and filter_chain Selection](https://blog.mygraphql.com/zh/posts/low-tec/trace/trace-istio/trace-istio-part3/)
 - [BPF tracing istio/Envoy - Part4: Upstream/Downstream Event-Driven Collaboration of Envoy@Istio](https://blog.mygraphql.com/en/posts/low-tec/trace/trace-istio/trace-istio-part4/)

And last but not least: Envoy author Matt Klein: [Envoy threading model](https://blog.envoyproxy.io/envoy-threading-model-a8d44b922310)