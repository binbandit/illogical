# Performance validation

Use a Release build. The tested stack remains Swift/AppKit/Metal, the pinned Ghostty Zig terminal library, and a Go process service. Profiling identified expensive receive-loop scanning, synchronous per-packet delivery, per-frame accessibility work, and colour-dependent glyph allocation. Those paths were corrected before considering a language rewrite.

## Terminal throughput

The development benchmark is the existing `DOOM-fire` executable in `/path/to/DOOM-fire-zig`. Its source and build were not modified. It writes coloured upper-half-block cells as rapidly as it can and reports completed writes per second. That number measures producer throughput, not physical display refresh rate.

A comparison must use the same executable, rows and columns, font size, display scale, power conditions, and active rendering state. A high producer number while a client is detached or reconnecting is invalid. Check the live terminal throughout the run, verify the connection remains established, and confirm Control-C immediately returns to the shell at the end.

The first controlled illogical viewport is 134 columns by 35 rows. The user's earlier approximately 500 FPS Ghostty observation is a useful target, but a fresh matched Ghostty run was blocked by Computer Use's application access policy. It is not a validated baseline for this viewport.

### Diagnosed bottlenecks

Profiling the actual benchmark found a blocking Metal drawable acquisition on the main thread, which also processes the client's VT stream. The resulting receive backlog eventually exceeded the service's 32 MiB client queue and forced a reconnect. Apparent 500-plus FPS results during those reconnects were discarded.

Redraw requests now coalesce at the display's native refresh cadence. A serial worker acquires drawables, and the main thread submits the latest terminal state only when a drawable is available. Three explicitly owned GPU buffers replace a blocking semaphore. A final update remains pending until submitted; hidden and idle views pause.

The primary viewer also provides bounded flow control: its service output queue pauses PTY reads at 1 MiB and resumes below 512 KiB. Waiting holds no terminal or workspace lock. Secondary slow viewers cannot stall the primary. A bounded read allowance around input writes prevents Darwin's echo processing from delaying Control-C when output buffers are full.

An exact full-density VT capture arrived at approximately 41 MiB/s. Replaying it through the same pinned bridge sustained 176 MiB/s, or 157 MiB/s with frequent frame extraction. This supports keeping the existing parser and languages; the measured bottleneck was scheduling and flow control.

### Sustained output samples, 20 September 2026

The unchanged executable's SHA-256 was `1849057b575b8197de4179a3ab5cb5da95595c8e8551e3a0158e96398c6c88df`. The viewport was 134 by 35, using SF Mono at 13 pt. The first two runs below used the same service, final presentation scheduling, and output flow control. The third started a fresh service with the completed connection handoff. No builds or test suites ran during these measurements.

| Local connection | Duration | Final cumulative producer FPS | Continuous viewer connection | Control-C to shell metadata |
| --- | --- | --- | --- | --- |
| Bootstrap helper relay | 60.26 s | 401.24 | Yes, no overflow | 64.88 ms |
| Direct Unix socket after reopen | 60.23 s | 442.87 | Yes, no overflow | 58.84 ms |
| Cold startup with automatic direct-socket handoff | 60.26 s | 428.63 | Yes, no overflow | 56.42 ms |

The direct socket was approximately 10% faster in this pair of runs. These are individual samples, not a statistically established speedup or a comparison against Ghostty. The interruption timings use a CLI-injected Control-C followed by service metadata checks; native Control-C was verified separately in the visible window.

Cold startup now uses the helper only to start the service, then switches to the direct socket before exposing the server hello. Requests submitted before that switch stay on their original connection. Real-process tests verify one visible hello, exact request/callback delivery, retired-helper cancellation, and fallback when a direct socket cannot be opened. Native inspection also confirmed that no relay helper remains after cold startup.

## Startup

`LaunchMetrics` records the first presented terminal drawable, after receiving a terminal snapshot, in `~/Library/Caches/illogical/launch.jsonl`. Time starts at the operating system's process creation timestamp. This includes app initialization and presentation, but does not measure Dock animation duration or time before macOS creates the process.

Measure warm reconnects and launches that need to start a service separately. The local socket connects directly when the service already exists. Metal shaders are compiled at build time; font fallback discovery and font loading are lazy. Quit only the GUI between warm samples, because terminal processes belong to the service.

An early instrumentation bug produced an invalid `1.8446744073710296e+16` millisecond record; exclude it. Subsequent records use signed arithmetic and real presentation callbacks. Do not use a single warm sample to claim consistent half-bounce startup under every launch condition.

### Foreground launch samples, 20 September 2026

The final Release app was opened through Finder, which launches it in the foreground. Background Computer Use launches were excluded: an occluded window intentionally pauses presentation. The one-shot timing latch now claims completion only when a drawable actually presents, allowing a discarded setup frame to be followed by a valid measurement.

| Condition | First terminal presentation, milliseconds |
| --- | --- |
| Existing service, three launches | 848.871, 493.660, 471.355 |
| Service stopped before launch, two launches | 659.409, 476.508 |

The warm median was 493.660 ms. These are process-start-to-presentation measurements with the operating system's caches already warm, not a Dock-animation measurement or a guarantee of consistent half-bounce startup. The 848.871 ms warm sample remains in the result set. A prior blank-until-input regression was fixed with a wake from the Metal child's attachment and visibility callbacks; its delayed presentation record is not a valid launch sample.

After adding the cold-start socket handoff and initial keyboard-focus fix, another foreground service-start launch measured 711.217 ms. A real first Control-C stopped an existing `sleep` without a prior click; picker input and focus restoration after dismissing the picker were also verified.

## Installed Release sample, 21 September 2026

`just install` built and installed the signed Release bundle. A private QA copy used the identical native executable (`8378423c14470f9a1dc1f85589c7ebba5a7b00ed58297b001d250c807160ab04`) and service (`d750be50d0bfb05ddac710db19a85f31f05d7bd24cdefba40e14fc1a5860dd37`), with only its bundle identity and service directory changed for isolation. This build includes static images, contextual shaping, theme import, bounded replay and the corrected translucent renderer. The hashes identify this measured snapshot; the subsequent session-picker rename and incremental-signing changes were validated separately, without repeating the throughput benchmark.

On battery power, the unchanged DOOM executable at 134x35 with SF Mono 13 pt sustained **432.35 producer FPS over 60.18 seconds**. The same viewer remained attached throughout, no output queue overflow occurred, and CLI-injected Control-C returned shell metadata in 64.37 ms. Native inspection confirmed live fire rendering and the restored prompt. No builds or tests ran during this measurement. Local evidence: `.build/doom-final-result.json`.

A subsequent battery run of the frozen resource-only build sustained 344.11 FPS over 60.22 seconds, with continuous ownership, no overflow and 115.18 ms interruption. Its cumulative rate fell from 422.91 FPS at ten seconds. This was a single later sample with uncontrolled background activity and thermal history, not a randomized comparison. The frozen build's earlier AC-powered 587.04 FPS result therefore cannot establish a regression in the new feature build, nor can these battery samples establish a speedup. Local evidence: `.build/doom-frozen-battery-result.json`.

The first launch of the freshly signed QA copy, starting its private service, took **1,312.416 ms** from process creation to terminal presentation. App initialization began at 803.3 ms, content appeared at 1,030.761 ms and the snapshot arrived at 1,273.976 ms. Keep this slower sample alongside the earlier warm measurements. It is not a controlled cold-OS-cache test. Consistent half-bounce startup and zero overhead versus Ghostty remain unverified.

## Correctness under load

The test suite checks byte-exact ordered output, bounded queues, cancellation, snapshot/history barriers, and stalled-client isolation. A parked terminal must retain an unfinished escape sequence after waking, or reconnecting during fast output can fail. A regression exercises that exact case, and the actual DOOM executable was also used for repeated attachments after parking.

Flow-control checks include owner transfer, client detach/disconnect, and echo-enabled interruption with saturated output. The latter also passed 50 repeated paired-key stress iterations. Connection tests use an actual Unix socket so small interactive messages cannot regress to waiting for a full read buffer.

Terminal graphics use exact cell geometry. Rendering the same glyph in another colour reuses its coverage bitmap. Clean rows reuse cell data, and accessibility text is constructed when requested rather than on every display frame. Synchronized-output mode retains the complete prior frame and has a bounded timeout, including when the producer becomes quiet.
