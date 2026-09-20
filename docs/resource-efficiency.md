# Resource and energy efficiency

Measurements and changes recorded 20 September 2026. The goal is to avoid unnecessary work while preserving terminal input, history, independent viewports and process persistence. Lower callback counts or process CPU time are useful evidence, but do not by themselves establish longer battery life.

This Mac was connected to AC power and charging during the initial measurements. No battery-discharge-duration claim is supported. The tests use private socket fixtures, a dedicated preferences domain and read-only process counters. They do not restart the user's service or terminate existing terminal sessions.

## Native connection and model findings

| Finding | Evidence | Action / remaining limit |
| --- | --- | --- |
| Unavailable hosts retried every two seconds indefinitely. Each window owns a connection per configured host, so an offline host can repeatedly launch a helper/SSH attempt. | An actual Unix-socket fixture repeatedly accepted and closed connections without a greeting. Before the change, its second retry arrived after 2.008 seconds rather than increasing its delay. | `ServiceConnection` now uses exponential intervals based on 2, 4, 8, 16 and 30 seconds, with modest jitter and a 30-second cap. A successful greeting resets the backoff; explicit connect remains immediate. The pending retry task is canceled on close/replacement. Actual-socket regressions verify these boundaries. This is per connection, not global host deduplication across windows. |
| Removed remote profiles left native terminal replicas and their history retained in `engines`/`engineHosts`. | A real `WorkspaceModel` created a remote replica, removed that host, and retained a weakly observed engine before the fix. No network or live host was required to reproduce it. | Host removal now discards that host's engines, host bookkeeping, remembered session decks and stale search/pending state. A socket-driven state update verifies deleted blocks also release replicas and search state. An unrelated host's engine remains alive. |
| Queued search callbacks could restore stale state after a block disappeared. | The old global search callback could schedule a UI result after its block had disappeared. | Search now belongs to a per-pane state object removed with its engine. Deferred publication cannot recreate a removed entry; cleanup tests cover this ownership boundary. |
| Healthy connections do not poll. | `ServiceConnection` uses a blocking POSIX read on the background reader, with one scheduled bounded main-thread drain and an `NSCondition` wait only when its mailbox is full. | Keep this event-driven behavior. A blocked thread is not evidence of CPU polling. The inbound mailbox targets 8 MiB/1,024 items, permitting one larger bounded wire message alone so snapshots cannot deadlock. |
| Every visited or previewed block remains subscribed and its native parser/history stays allocated while it remains valid. | `WorkspaceModel.engine(for:)` caches and attaches replicas. Hiding tabs removes presentation but does not detach the stream or remove the engine. | Deliberately unchanged: dropping replicas would otherwise lose independent viewport/history state. A future inactive-replica policy needs explicit snapshot/viewport restoration semantics and reconnect tests. Renderer idling does not solve hidden parser cost when those terminals continue producing output. |
| Outbound work accumulated behind a stalled peer. | An actual non-reading Unix peer retained 2,048 callbacks after 2,048 requests containing approximately 32 MiB of input. The old implementation offered no admission-failure interface. | Fixed with an 8 MiB encoded-byte / 1,024-item outbound mailbox, counting the in-flight request, plus at most 1,024 pending callbacks. A single worker uses nonblocking writes and waits for writability or explicit cancellation. Rejected whole requests return false, invoke `onSendError`, and complete with an error. Replacement cancels stale queued bytes and fails outstanding callbacks; uncertain input is never automatically replayed. Individual unanswered requests have no timer; callback admission is bounded until replies or transport release. |
| Host discovery is on demand rather than a periodic scan. | `HostDiscovery.discover` starts one bundled `tailscale discover` helper only when invoked, prevents overlapping calls, and schedules a five-second termination check. | No background discovery timer was found. The five-second timeout work item is canceled after process completion. Discovery now filters advertised illogical services rather than listing unrelated online peers. |

The targeted implementation is in [ServiceConnection.swift](../illogical/Model/ServiceConnection.swift) and [WorkspaceModel.swift](../illogical/Model/WorkspaceModel.swift). Replica cleanup does not kill the service's processes, detach unrelated terminals or discard valid visited tabs.

The independent [service resource report](resource-service.md) covers event-driven metadata/parking scheduling, ownership-change wakeups and avoiding persistence on read-only client disconnect. Its isolated eight-quiet-PTY sample changed from 18.324 to 0.065 ms service CPU across a 20-second interval, and a twelve-capture experiment changed from twelve workspace-file rewrites to zero. These are component experiments with their own conditions and tests; they should not be combined into a whole-device battery estimate.

## Native outbound follow-up

[ServiceConnectionOutboundTests.swift](../tests/ServiceConnectionOutboundTests.swift), included in [scripts/test-connection.sh](../scripts/test-connection.sh), uses real private Unix peers. In the stalled-peer run, 382 requests were admitted and 1,666 rejected explicitly from a 2,048-request burst. Sampled usage stayed within 8 MiB, 1,024 items and 1,024 callbacks. The exact admitted count depends on socket buffering; the limits do not. Transport replacement completed in less than one measured millisecond, every completion ran exactly once, and only a fresh request reached the replacement peer.

A peer that reads requests but never answers reaches the callback bound and rejects later callback-bearing requests. Reusing an outstanding request ID also fails instead of overwriting its completion. Closing the transport resolves and clears pending callbacks. A deliberately broken peer verifies error recovery and that uncertain input is not sent to the next connection. Simultaneous read/write failures now retire the generation immediately, preventing duplicate reconnect scheduling and backoff escalation.

The full connection suite passed small server-first greetings (6 ms in this run), all three helper/bootstrap modes, 32 MiB inbound ordering, framing, bounds and cancellation, plus the outbound fixture. The final added duplicate-ID check also passed the focused outbound executable. These are correctness and bounded-admission results, not measurements of final app RSS, startup time, throughput or battery use. A rejected paste is rejected as a whole request before its bytes enter the outgoing mailbox. A write error may follow partial transmission; that uncertain request is failed and never retried automatically.

## Cursor and presentation evidence

The native surface audit instrumented the actual cursor-timer callback in an isolated harness. Thirty-two hidden, noninteractive, unmounted surfaces produced **96 scheduled callbacks in 2.05 seconds** before the fix. This is a callback count, not 96 measured hardware wakeups.

The surface change limits cursor scheduling to an interactive, visible, focused first responder in the key window, with a visible blinking terminal cursor. It adds timer tolerance and tests visibility/focus notifications, resumption and terminal cursor modes. Renderer work and service timer/write improvements are measured separately; this document should not attribute their effects to connection backoff.

## Process counter utility

[resource_usage_probe.c](../tests/resource_usage_probe.c) reads `proc_pid_rusage` v6, falling back to v4, plus the current thread count. It records process CPU time, package-idle and interrupt wakeups, resident memory, physical footprint, lifetime maximum footprint, disk/logical writes, instructions, cycles and the v6 energy counter when available. Unsupported v6 energy is emitted as `null`, not zero. A zero counter from a supported API still should not be interpreted as proof that a workload consumes no energy.

```sh
mkdir -p .build/resource-efficiency
clang -O2 -Wall -Wextra -Werror tests/resource_usage_probe.c \
  -o .build/resource-efficiency/resource-usage
.build/resource-efficiency/resource-usage --pid PID
.build/resource-efficiency/resource-usage --pid PID --seconds 20
```

The first form produces one cumulative JSON sample. The second produces baseline/end samples and interval deltas. Intervals are limited to 60 seconds and PID reuse is rejected. CPU percentage is relative to one CPU core; CPU time excludes separate child processes, which need their own samples. Physical footprint is the current sample, not just a lifetime high-water mark.

**CPU units matter on Apple silicon:** this API's user/system counters use Mach time units. The utility applies `mach_timebase_info` before labeling them nanoseconds. On this Mac the conversion is 125/3; treating raw ticks as nanoseconds would understate CPU time about 41.7 times. Converted cumulative CPU agreed with `ps` for the observed QA process. Apple's [Recount documentation](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md) describes the accounting system and Mach-time counters behind these interfaces.

The v6 energy counter is a process accounting estimate, not measured whole-device battery drain. It excludes a complete attribution of display, shared GPU/server and system effects. Keep its raw counter alongside CPU/wakeup evidence; do not convert it into a battery-runtime promise.

## Initial old-build idle samples

The native UI check placed the existing QA app in the specified state and made no GUI changes during each 20-second sample. This was **the old QA binary**, PID 39868, with one selected idle shell; unrelated compilation continued. These samples are a baseline for process behavior, not a controlled whole-system energy experiment.

| State | Interval | Process CPU | One-core CPU | Interrupt wakeups | Package-idle wakeups | Ending physical footprint | Disk/logical writes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Visible, focused prompt | 20.0003 s | 2.335 ms | 0.0117% | 41 | 3 | 82.66 MB | 0 / 0 bytes |
| App hidden with Cmd-H | 20.0039 s | 2.216 ms | 0.0111% | 40 | 5 | 82.90 MB | 0 / 0 bytes |

Evidence: [visible sample](../.build/resource-efficiency/qa-old-visible-idle.json) and [hidden sample](../.build/resource-efficiency/qa-old-hidden-idle.json). The files are ignored local build artifacts. The visible sample's footprint fell by 3.08 MB; the hidden sample stayed constant. Low CPU is already apparent. The roughly two interrupt wakeups per second are consistent with the timer finding, but these counters alone do not identify each wakeup's source. A trace or isolated callback instrumentation is required for attribution.

## Fresh isolated Release samples

The new `dev.illogical.resourceqa` bundle uses `.build/resource-state/daemon.sock`, preserving the earlier QA workspace. Its native executable SHA-256 is `872ea50d2801230577b0fa001e08f689d49df3e60242187909f3403a71114228`; the bundled service hash is `acdcdd73617db5667caf4c97c4f805ce492923288d7c4833d7af68a088ac7457`. These identify the measured build, even if later feature work changes the sources. The native UI check raised the app and clicked its idle terminal prompt before the visible measurement. AC charging continued.

| State / process | Interval | Process CPU | One-core CPU | Interrupt / package-idle wakeups | Ending footprint | Writes |
| --- | --- | --- | --- | --- | --- | --- |
| Visible client, PID 82174 | 20.0047 s | 0.249 ms | 0.00124% | 6 / 0 | 69.22 MB | 0 bytes |
| Corresponding service, PID 82177 | 20.0017 s | 0 recorded delta | 0 recorded delta | 0 / 0 | 6.29 MB | 0 bytes |
| Hidden client, PID 82174 | 20.0051 s | 0.296 ms | 0.00148% | 7 / 0 | 73.93 MB | 0 bytes |
| Corresponding hidden-app service, PID 82177 | 20.0006 s | 0.037 ms | 0.00019% | 2 / 0 | 6.29 MB | 0 bytes |

Evidence: [new visible client](../.build/resource-efficiency/qa-new-visible-idle-client.json) and [new visible service](../.build/resource-efficiency/qa-new-visible-idle-service.json). Both footprints were stable. Zero means no increment in these counters during this interval, not proof that the process or device consumes no energy. The new client performed less measured idle work in this sample than the old build, but fresh workspace/history, process age and concurrent development activity differ. Repeated controlled intervals and a battery run are still needed before assigning a savings percentage.

The native UI check then hid the same app using Cmd-H, after confirming its shell was parked. [Hidden client](../.build/resource-efficiency/qa-new-hidden-idle-client.json) and [hidden service](../.build/resource-efficiency/qa-new-hidden-idle-service.json) footprints stayed constant throughout their intervals, with no disk or logical writes. The difference between visible and hidden sample starting footprints is not within-interval memory growth.

A 50-second counter interval overlapped the subsequent sustained DOOM Fire run at 134x35:

| Process | CPU time / interval | One-core CPU | Interrupt / package-idle wakeups | Physical footprint, start to end |
| --- | --- | --- | --- | --- |
| Native client | 45.038 / 50.004 seconds | 90.07% | 14,193 / 2 | 321.06 to 84.21 MB |
| Service | 62.762 / 50.004 seconds | 125.52% | 1,165,885 / 73 | 15.11 to 15.99 MB |

Evidence: [load client](../.build/resource-efficiency/qa-new-doom-client.json) and [load service](../.build/resource-efficiency/qa-new-doom-service.json). The client recorded no writes; the service recorded 4,096 disk bytes and 118,784 logical write bytes. These observations show substantial CPU work and sampled memory behavior, not GPU time or continuous presentation. Two memory endpoints do not characterize the peak or prove leak freedom. The initial 60-second producer result of 587.04 FPS retained its viewer and responded to CLI Ctrl+C in 48.32 ms, but no screenshot was captured during that run.

A subsequent native UI check ran a 15-second visible follow-up with the same build and captured a screenshot **during** execution: the full fire was visibly rendering with an approximately 601 FPS overlay. Final cumulative producer throughput was 597.0 FPS, viewer ownership remained continuous with no overflow, and CLI Ctrl+C returned in 48.36 ms. This confirms active rendering for the short follow-up. It does not retroactively supply continuous visual observation of the longer run, a matched Ghostty baseline, or physical display FPS. No builds/tests were run during either timed output run. The load counter interval above belongs to the 60-second run, not the follow-up. Do not describe either as a controlled battery-efficiency comparison.

## Available macOS tooling

- `xcrun xctrace list templates` succeeds and lists Power Profiler, System Trace, CPU Profiler, Time Profiler, Allocations, Leaks, Metal System Trace and Activity Monitor. Recording capability and permissions still need to be checked on the selected isolated target; template availability alone is not a completed energy trace.
- `powermetrics` is installed and advertises per-process CPU/wakeups/energy plus CPU/GPU/thermal/battery samplers. A nonprivileged attempt failed with `powermetrics must be invoked as the superuser`. No privileged retry or system-setting change was performed. Its own help describes subsystem power as estimated.
- `sample`, `vmmap`, `footprint` and `pmset` are installed. Prefer low-overhead counter intervals for comparison, then collect a bounded trace/profile only when a concrete regression needs attribution. `pmset -g batt` established AC charging for these samples.

## Repeatable acceptance and measurement plan

Use a fresh isolated Release bundle and service directory with the same font, grid, selected theme, terminal contents and foreground state for each comparison. Record the executable hash, OS/hardware, screen refresh/scale, power source, Low Power Mode and active terminal/host counts. Separate client, service and child-process counters. Stop builds and unrelated heavy work when comparing whole-system power or sustained throughput.

| Scenario | Measurements and correctness condition |
| --- | --- |
| One visible idle shell | After startup settles, collect three 20-60-second intervals. Record CPU/wakeups/footprint; check ordinary cursor behavior and immediate first-key input. |
| Hidden or fully occluded app | Repeat without terminal output. Rendering/cursor work should stop; service processes must remain usable when the app returns. |
| Many retained but quiet tabs | Repeat with 1, 16 and 64 tabs. Record memory scaling and wakeup growth; distinguish retained history from leaked views/timers. |
| Output in a hidden visited tab | Record native CPU and memory separately from rendering. This exposes the deliberately retained parser/subscription cost. Restore the tab and verify complete contents and viewport semantics. |
| Sustained visible output | Use the unchanged DOOM Fire executable at the established 134x35 grid. Record continuous attachment, final producer throughput, CPU/footprint and immediate Ctrl+C. Preserve byte ordering and do not count detached/reconnecting high-throughput samples. |
| Offline configured remote | Count actual connection attempts over a long interval. Verify capped backoff, recovery after a greeting, immediate explicit retry and cancellation after host/window removal. Do not involve a real user's unavailable host merely to benchmark failures. |
| Host/block removal | Use weak-reference assertions and memory stabilization across repeated creation/removal. Other valid panes keep their history, process identity and independent viewport. |

Battery comparison requires a separate repeatable run on battery with fixed brightness, network and background workload. Short AC samples cannot supply that result. A lower process wakeup count is an engineering improvement to test under those conditions, not a measured percentage battery saving.

## Focused regressions

Run [scripts/test-resource-efficiency.sh](../scripts/test-resource-efficiency.sh). It builds the counter utility and actual socket retry/workspace fixtures against production sources. The test preferences are isolated under `dev.illogical.resource-tests`; sockets are unique `/tmp/ilg-resource-*` paths. Before changes, the retry test failed at the repeated two-second delay and the model test failed because the removed host's engine remained alive. After changes, the focused tests verify exponential delay, cap/jitter policy, successful-greeting reset, explicit retry, close cancellation, host/block cleanup and preservation of another host's engine.

The existing [connection suite](../scripts/test-connection.sh) remains required because backoff must not break small server-first greetings, ordered/bounded delivery, stale-callback cancellation, or the local helper-to-socket handoff and exactly-once early-request fallback. Local results are recorded in `.build/resource-efficiency/focused-tests.txt` and `connection-tests.txt`.
