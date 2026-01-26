# Protocol Gateway + Pub/Sub Event Bus*

## 1) Canonical pattern definition

### Name

**Edge Vision Command/Result Gateway (Protocol Bridge) over an Internal Pub/Sub Bus**

### Intent

Decouple a real-time vision worker (tracking) from:

* external control clients (GUI/ground station/mission logic), and
* external consumers of results,
  by translating between a simple external protocol (UDP) and an internal event bus (ZMQ pub/sub).

### Core architectural elements

1. **External Control Plane**

   * Simple, low-latency command messages: *start tracking*, *stop tracking*, optionally *set ROI*, *set mode*.
   * In your case: UDP + pickle.

2. **Internal Data Plane (Event Bus)**

   * High-rate streams: camera frames, tracking results, vehicle state, telemetry.
   * In your case: ZMQ topics.

3. **Protocol Gateway / Bridge**

   * Converts external commands into internal bus events.
   * Converts internal results into external responses.
   * In your case: the UDP↔ZMQ bridge script.

4. **Stateful Worker**

   * Runs the tracker.
   * Subscribes to frames + commands, publishes bbox results.
   * In your case: the tracker node.

### Typical diagram (architecture style)

```
         (External world)                              (Internal system)
+-------------------------+                      +----------------------------+
| Ground UI / Controller  |                      |  ZMQ Pub/Sub Topic Bus     |
|  - click ROI            |                      |  - Frames topic            |
|  - start/stop           |                      |  - TrackCmd topic          |
+-----------+-------------+                      |  - TrackRes topic          |
            | UDP (commands/results)             |  - Telemetry topics        |
            v                                    +-------------+--------------+
+-------------------------+                                    |
| Protocol Gateway        |                                    |
|  UDP <-> ZMQ Bridge     |   publishes TrackCmd               |
|  - parse/validate       +----------------------------------->|
|  - translate topics     |                                    |
|  - optional filtering   |                                    |
|                         |   forwards TrackRes back to UDP    |
|                         |<-----------------------------------+
+-------------------------+                                    |
                                                               v
                                                     +------------------+
                                                     | Tracking Worker  |
                                                     |  - subscribes    |
                                                     |    Frames+Cmd    |
                                                     |  - publishes bbox|
                                                     +------------------+
```

---

## 2) Why this pattern is common (the “why”)

It is common because it optimizes for three constraints that robotics/vision stacks often have:

1. **Real-time-ish latency**

   * UDP commands are low overhead.
   * ZMQ pub/sub is low overhead for intra-host or LAN.

2. **Loose coupling**

   * The tracker does not care who issued start/stop.
   * The UI does not care how the tracker is implemented.

3. **Multiplexing and fan-out**

   * Many internal consumers can subscribe to results without changing the tracker.
   * Many internal producers (different cameras) can publish frames.

---

## 3) Typical failure modes / architectural “tax”

If you keep this pattern, it is worth being explicit about the costs:

1. **Synchronization ambiguity**

   * “Start tracking at point X” must correspond to a particular frame/time.
   * Your current system carries `frameId`, but it is not enforced.

2. **Reliability gaps**

   * UDP can drop start/stop or result packets.

3. **Security exposure**

   * Pickle across a network is a high-risk design if any untrusted access exists.

4. **Observability**

   * Debugging race conditions across UDP + pub/sub is harder without trace IDs, frame IDs, and structured logging.

5. **Schema drift**

   * ZMQ messages are essentially “convention-based APIs.” Without strict schemas, producers/consumers drift.

---

## 4) Architectural alternatives (and when to use them)

### Alternative A: Single internal bus, no external protocol (UI becomes a bus client)

**Replace UDP bridge** with the ground UI speaking ZMQ directly (or via a secured proxy).

**Pros**

* One messaging system, fewer translations.
* Easier traceability, less code.

**Cons**

* ZMQ is not a “standard external API”; harder to integrate non-Python tools.
* Exposes your internal bus to the network unless you isolate or proxy it.

**Use when**

* You control both ends (UI + tracker).
* Network is trusted or you can secure the endpoint.

---

### Alternative B: Request/Reply command plane + Pub/Sub data plane

Use a **reliable command plane** (RPC) for start/stop, keep pub/sub for frames/results.

Example command plane options:

* gRPC
* HTTP/REST
* ZeroMQ REQ/REP (or DEALER/ROUTER)

**Pros**

* Commands become reliable and confirmable (“ACK start”, “tracker initialized on frame X”).
* You can enforce synchronization (frameId acknowledged).

**Cons**

* More moving parts (service definitions, server lifecycle).
* Requires careful timeout/backpressure strategy.

**Use when**

* Start/stop must be reliable.
* You need explicit acknowledgements and stronger API contracts.

---

### Alternative C: Full message broker (ROS 2 / DDS, NATS, MQTT, or Kafka-lite choices)

Replace ad-hoc ZMQ topics with a brokered system.

**Pros**

* Schema governance, tooling, introspection, discovery (especially ROS 2).
* Better multi-host scaling and lifecycle tools.

**Cons**

* Complexity, operational overhead.
* Latency and tuning might be harder, depending on tech.

**Use when**

* System is growing (multiple nodes/hosts/teams).
* You need standardization and tools more than minimal latency.

---

### Alternative D: Shared-memory / zero-copy data plane + small command plane

Frames are huge; control is tiny. Architecture splits them explicitly:

* Frames: shared memory ring buffer (or v4l2 DMA buf / GStreamer shared memory)
* Commands: small reliable channel (Unix socket, gRPC, ZMQ)
* Results: small pub/sub or direct callback

**Pros**

* High performance, minimal copying.
* Cleaner separation: data plane optimized for throughput, control plane for correctness.

**Cons**

* More engineering (shm lifecycle, ring buffer management).
* Cross-host streaming still needs a transport.

**Use when**

* Single host or tightly coupled host pair.
* Performance is the priority (high-res / multi-camera).

---

### Alternative E: “Commanded tracking as a service” (single process owns state)

Instead of separate bridge + tracker processes, put it behind one service boundary:

* One process owns:

  * frame ingestion
  * command API
  * tracker state
  * result publication

**Pros**

* Eliminates cross-process synchronization bugs.
* Simplest mental model, fewer race conditions.

**Cons**

* Less modular; scaling requires careful internal architecture.
* Harder to swap components independently.

**Use when**

* You want correctness and maintainability over maximal modularity.
* The tracker is tightly coupled to the camera pipeline.

---

## 5) How to choose (practical decision criteria)

Ask these questions:

1. **Do you require guaranteed start/stop delivery?**

* If yes: prefer Alternative B (RPC) or add ACK/retry to UDP.

2. **Do you require “start at frameId” semantics?**

* If yes: you need a command plane that can negotiate/ack frame alignment (RPC or structured bus).

3. **Is this across hosts or mostly same host?**

* Same host: shared memory + small control channel is strong (Alternative D).
* Across hosts: prefer RPC + pub/sub with clear schema.

4. **Will more teams/components integrate?**

* If yes: ROS 2/DDS or NATS/MQTT with schemas becomes attractive.

5. **Is the network untrusted or exposed?**

* If yes: remove pickle immediately; use protobuf/msgpack + authentication/encryption.

---

## 6) If you keep your current pattern, the “minimum architecture hardening”

Without changing tech choices, you can harden the pattern:

* Replace pickle with msgpack/protobuf.
* Add `trace_id`, `frame_id`, `cmd_seq` to every command/result.
* Introduce command ACK:

  * UI sends `start(seq, pos, frame_id)`
  * tracker publishes `ack(seq, accepted, init_frame_ts)`
* Enforce ROI init on the nearest frame to `frame_id` (or a window).

This preserves your modularity and latency while addressing the biggest correctness gaps.

---

If you tell me one detail—whether your ground UI is on the same machine as the tracker (most of the time) or always remote—I can recommend a “best next architecture” among these and sketch a concrete message schema (commands + results) aligned to your current topics.

