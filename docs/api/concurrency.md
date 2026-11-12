# concurrency

## Structs

### `Chan` *(std/concurrency.qz:198)*

Channel wrapper with automatic cleanup.

| Field | Type |
|-------|------|
| `handle` | `Int` |

#### Trait Implementations

**impl Drop for Chan**

##### `drop(): Void`

### `Mtx` *(std/concurrency.qz:209)*

Mutex wrapper with automatic cleanup.

| Field | Type |
|-------|------|
| `handle` | `Int` |

#### Trait Implementations

**impl Drop for Mtx**

##### `drop(): Void`

### `RwLk` *(std/concurrency.qz:220)*

Read-write lock wrapper with automatic cleanup.

| Field | Type |
|-------|------|
| `handle` | `Int` |

#### Trait Implementations

**impl Drop for RwLk**

##### `drop(): Void`

### `WaitGrp` *(std/concurrency.qz:231)*

WaitGroup wrapper with automatic cleanup.

| Field | Type |
|-------|------|
| `handle` | `Int` |

#### Trait Implementations

**impl Drop for WaitGrp**

##### `drop(): Void`

### `Once` *(std/concurrency.qz:242)*

OnceCell wrapper with automatic cleanup.

| Field | Type |
|-------|------|
| `handle` | `Int` |

#### Trait Implementations

**impl Drop for Once**

##### `drop(): Void`

## Functions

### `go(): Int` *(std/concurrency.qz:34)*

std/concurrency.qz — Structured Concurrency for Quartz

Provides higher-level concurrency abstractions built on top of the
compiler intrinsics (spawn, channels, atomics, mutex, task_group,
cancel_token, rwlock, waitgroup, oncecell).

Usage:
  import concurrency

Primitives (re-exported from intrinsics):
  - spawn/await: OS thread creation
  - channel_new/send/recv: Buffered MPMC channels
  - atomic_new/load/store/add/sub/exchange/cas: Atomic integers
  - mutex_new/lock/unlock/try_lock: Mutual exclusion with protected value
  - rwlock_new/read/write: Read-write lock (multiple readers OR one writer)
  - waitgroup_new/done/wait: Counter-based synchronization
  - oncecell_new/get_or_init/get: Thread-safe lazy initialization
  - cancel_token_new/cancel/is_cancelled: Cooperative cancellation
  - cancel_token_with_deadline: Timeout-based cancellation
  - task_group: Scoped thread pool parallelism

Structured concurrency:
  - scope: All children must complete; child panic propagates to parent
  - supervisor: Like scope but child failures don't cancel siblings
Spawn a lightweight task on the M:N scheduler.
The function is wrapped in an async frame and enqueued.
Returns the task frame handle (can be used with await later).
Requires sched_init() to have been called first.

---

### `go_cancellable(): Int` *(std/concurrency.qz:44)*

Spawn a cancellable task on the M:N scheduler.
Sets frame[3] to the given cancel token before spawning.
The task will be cancelled at its next suspension point if the token fires.
Returns the task frame handle.

---

### `scope(): Int` *(std/concurrency.qz:59)*

Scope — structured concurrency block.
All spawned children must complete before the scope exits.
If any child returns -1 (panic sentinel), the scope panics.
Returns 0 on success.

---

### `supervisor(): Vec<Int>` *(std/concurrency.qz:77)*

Supervisor — like scope but child failures don't cancel siblings.
Returns Vec<Int> of results (including -1 for failed tasks).

---

### `scope_with_timeout(): Int` *(std/concurrency.qz:87)*

Scope with timeout — runs body in a task_group with a deadline.
If the timeout fires before tasks complete, the group is cancelled.
Returns 0 on normal completion, 1 on timeout.

---

### `scope_cancel_on_failure(): Int` *(std/concurrency.qz:107)*

Scope with cancel-on-failure policy.
All spawned children share a cancel token. If any child returns -1
(error/panic), the scheduler automatically cancels the shared token.
Other children will exit at their next suspension point.
The body receives the cancel token — use go_cancellable(f, tok) to spawn.
Returns 0 on success, -1 if any child failed.

---

### `sched_map(): Vec<Int>` *(std/concurrency.qz:121)*

Apply f to each item using M:N scheduler, collect results in order.
Lighter than async_map (OS threads). Re-exported from std/futures.

---

### `go_cancel_on_success(): Int` *(std/concurrency.qz:147)*

Spawn a task with cancel-on-success policy.
Stores -(tok) at frame[3] — the scheduler cancels the token when
this task completes successfully (result != -1).
Returns the task frame handle.

---

### `async_recv(): Int` *(std/concurrency.qz:164)*

Async receive — suspends the async task (not the OS thread) when the channel is empty.
Uses io_suspend on the channel's notification pipe fd for event-driven wakeup.
When a sender writes to the channel, it notifies the pipe, waking this task.
Returns the received value, or -1 if the channel is closed and empty.

---

### `async_send(): Int` *(std/concurrency.qz:183)*

Async send — suspends the async task when the channel is full.
Uses sched_yield for now — send-side backpressure via io_suspend requires
a second notification pipe (write-ready notification). Send-blocking is rare
compared to recv-blocking in practice.

---

## FFI Functions

### `read(fd: CInt, buf: CPtr, count: CInt): CInt` *(std/concurrency.qz:158)*

