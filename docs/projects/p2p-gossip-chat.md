# Project: P2P Gossip Chat

> **Status**: Planning | **Priority**: Dogfooding validation project
> **Depends on**: Phase N (Networking & Concurrency Hardening)

## Overview

A peer-to-peer chat program using a gossip protocol, implemented entirely in Quartz.
This is the first real networked application built in the language and serves as
a validation project that stress-tests concurrency, networking, and the stdlib.

## Architecture

```
                    ┌─────────────┐
                    │  Acceptor   │ ← listen(), accept() in loop
                    │   Thread    │
                    └──────┬──────┘
                           │ spawn per connection
              ┌────────────┼────────────┐
              ▼            ▼            ▼
         ┌─────────┐ ┌─────────┐ ┌─────────┐
         │ Peer  1 │ │ Peer  2 │ │ Peer  N │  ← reads from socket
         │ Reader  │ │ Reader  │ │ Reader  │    sends into central channel
         └────┬────┘ └────┬────┘ └────┬────┘
              │            │            │
              ▼            ▼            ▼
         ┌──────────────────────────────────┐
         │        Central Channel           │  ← all incoming messages
         └───────────────┬──────────────────┘
                         ▼
                  ┌──────────────┐
                  │  Dispatcher  │ ← reads channel, broadcasts
                  │   Thread     │   to all peers via mutex-guarded
                  └──────────────┘   peer list
```

Thread-per-connection with CSP channels — the same architecture Go uses.

## Gossip Protocol

1. Each node maintains a peer list (mutex-protected)
2. Periodically (via timer thread), send own peer list to random subset of peers
3. On receiving a peer list, merge with own list (new peers get connection attempts)
4. Heartbeat: periodic ping to detect dead peers, remove after N missed heartbeats
5. Message dedup: seen-message set (atomic CAS or mutex) prevents infinite rebroadcast

## Message Types

```quartz
enum Message
  Chat(sender: String, text: String, id: Int)
  PeerList(peers: Vec<String>)
  Ping(sender: String)
  Pong(sender: String)
  Join(addr: String)
  Leave(addr: String)
end
```

## Quartz Primitives Used

| Need | Primitive | Notes |
|------|-----------|-------|
| Accept connections | `spawn` + FFI socket `accept()` | One thread per peer |
| Internal message bus | `channel_new` / `send` / `recv` | Buffered MPMC |
| Multiplex channels | `select` statement | Dispatcher reads from multiple sources |
| Shared peer list | `mutex_new` / `mutex_lock` / `mutex_unlock` | Thread-safe peer registry |
| Message dedup | `mutex`-guarded `Set` or `Map` | Track seen message IDs |
| Heartbeat timing | `sleep_ms` in dedicated thread | Periodic peer health check |
| Graceful shutdown | `is_cancelled()` | Cooperative cancellation |
| TCP I/O | FFI to libc sockets | `socket`, `connect`, `bind`, `listen`, `accept`, `read`, `write` |
| Message serialization | Simple text protocol or JSON | Use existing `std/json` |
| Static deployment | `quartz chat.qz -o chat` | Single binary, no runtime |

## Implementation Estimate

~300-500 lines of Quartz for a minimal working prototype:
- ~50 lines: message types and serialization
- ~80 lines: socket wrapper (FFI to libc)
- ~100 lines: acceptor + per-peer reader threads
- ~80 lines: dispatcher + broadcast logic
- ~50 lines: gossip protocol (peer exchange, heartbeat)
- ~40 lines: CLI and main loop

## Scale Characteristics

| Scale | Viability | Notes |
|-------|-----------|-------|
| 2-10 peers | Excellent | Well within thread limits |
| 10-100 peers | Good | OS thread overhead manageable |
| 100-1000 peers | Marginal | Approaching pthread limits |
| 1000+ peers | Requires async I/O | Need epoll/kqueue or green threads |

## Language Gaps (Resolved)

All previously identified language gaps have been addressed:

1. **Networking stdlib** — `std/net/tcp.qz` with `tcp_read_all`, `tcp_write_all`, error codes. **DONE**
2. **recv with timeout** — `recv_timeout(ch, timeout_ms)` via pthread_cond_timedwait. **DONE**
3. **Non-blocking I/O** — `std/ffi/event.qz` (kqueue/epoll) + `std/net/event_loop.qz`. **DONE**
4. **Thread pool runtime** — Current per-task pthreads sufficient for chat scale. **DONE**
5. **Compound field assignment** — `self.current += 1` parses and lowers correctly. **DONE**
6. **String formatting** — `format("Hello, {}!", name)` intrinsic. **DONE**

## Future Improvements

- **Supervision / error recovery** — Currently, if a peer handler thread crashes (segfault, nil dereference), the connection is silently lost with no recovery. A future improvement could add application-level supervision: a monitor thread that detects crashed peer handlers and respawns them. This could be implemented as a library pattern (supervisor loop with retry logic) rather than a core language feature, using `spawn` + a health-check channel.

## Success Criteria

- [ ] Two nodes can discover each other and exchange messages
- [ ] New node joins by connecting to any existing node (gossip propagation)
- [ ] Dead node detected and removed within 10 seconds
- [ ] Messages delivered to all connected nodes (dedup prevents loops)
- [ ] Single static binary, runs on macOS and Linux
- [ ] Under 500 lines of Quartz
