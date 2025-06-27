---
typora-root-url: ../../..
---

# Event-driven

:::{figure-md} Figure: Event Loop of Envoy

<img src="/arch/event-driven/event-driven.assets/envoy-event-model-loop.drawio.svg" alt="Figure - Event Loop of Envoy">

*Figure: Event Loop of Envoy*
:::
*[Open with Draw.io](https://app.diagrams.net/?ui=sketch#Uhttps%3A%2F%2Fenvoy-insider.mygraphql.com%2Fzh_CN%2Flatest%2F_images%2Fenvoy-event-model-loop.drawio.svg)*


Unsurprisingly, Envoy uses `libevent`, a C event library, which uses the Linux Kernel's epoll event driver API.

Let's explain the flow in the diagram:
1. The Envoy worker thread hangs in the `epoll_wait()` method, registering with the kernel to wait for an event to occur on the socket of interest to epoll. The thread is moved out of the kernel's runnable queue, and the thread sleeps. 
2. The kernel receives a TCP network packet, which triggers an event. 
3. the operating system moves the Envoy worker thread into the kernel's runnable queue. the Envoy worker thread wakes up and becomes runnable. the operating system finds an available cpu resource and schedules the runnable Envoy worker thread onto the cpu. (Note that thread runnable and scheduling on a cpu are not completed at once)
4. Envoy analyzes the event list and schedules to different callback functions of `FileEventImpl` class according to the fd of the event list (see `FileEventImpl::assignEvents` for implementation).
5. the callback function of the `FileEventImpl` class calls the actual upper layer callback function
6. Execute the actual proxy behavior of the Envoy
7. When callback tasks done, go back to step 1.



## General flow of HTTP Reverse Proxy

The overall flow of the socket event-driven HTTP reverse proxy is as follows:
![Figure: Socket event-driven HTTP reverse proxy general flow](/arch/event-driven/event-driven.assets/envoy-event-model-proxy.drawio.svg)

The diagram shows that there are 5 types of events driving the whole process. Each of them will be analyzed in later sections.

## Downstream TCP connection establishment

Now let's look at the process and the relationship between the event drivers and the connection establishment:
![envoy-event-model-accept](/arch/event-driven/event-driven.assets/envoy-event-model-accept.drawio.svg)


1. The Envoy worker thread hangs in the `epoll_wait()` method. The thread is moved out of the kernel's runnable queue. the thread sleeps.
2. client establishes a connection. server kernel completes 3 step handshakes, triggering a listen socket event.
   - The operating system moves the Envoy worker thread into the kernel's runnable queue. the Envoy worker thread wakes up and becomes runnable. the operating system discovers the available cpu resources and schedules the runnable Envoy worker thread onto the cpu (note that runnable and scheduling onto the cpu are not done at the same time).
3. Envoy analyzes the event list and schedules to different callback functions of `FileEventImpl` class according to the fd of the event list (see `FileEventImpl::assignEvents` for implementation).
4. The callback function of `FileEventImpl` class calls the actual upper layer callback function, performs syscall `accept` and completes the socket connection. Get the FD of the new socket: `$new_socket_fd`. 5.
5. The business callback function adds `$new_socket_fd` to the epoll listener by calling `epoll_ctl`. 6.
6. Return to step 1.






```{toctree}
libevent.md
event-model.md
```

