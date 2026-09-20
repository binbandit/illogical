# Service resource efficiency

Measured 20 September 2026 on this Apple Silicon Mac using private services and real shell children. Existing user sessions and the default daemon were not touched. These measurements describe the Go service process; they do not establish battery life, total system power, or terminal frame rate.

## Changes and correctness

The service previously woke every 100 ms to check pending metadata, and every ten seconds to scan for terminals to park. Metadata now starts a single 100 ms coalescing timer only when something changes. Parking uses the earliest eligible terminal's actual idle deadline, with no scheduled wake when the workspace is empty or fully parked. Fresh output postpones parking when the deadline is checked; the output path does not reset a timer for every chunk. Failed parking attempts retain a bounded ten-second retry delay.

Client presence and viewer ownership publish state without rewriting durable workspace data. A durable flush builds the state once for persistence and broadcasting. Previously, every read-only CLI client disconnect rewrote the workspace. Primary-viewer flow control now wakes on ownership changes rather than polling every 100 ms. Queue bounds, input allowances, disconnect cancellation and output ordering are preserved.

The regression suite verifies a quiet, single OSC title update is both published and persisted; client connection/disconnection is published without saving; automatic parking consults fresh output, leaves the child PID unchanged, stops scheduling after all terminals park, and resumes after new output. Existing blocked-input, real Ctrl+C, exact output-stream and viewer-turnover tests also pass.

## Process measurements

Each sample followed a one-second settling period and lasted approximately 20 seconds. The same harness measured an empty service, eight quiet real PTYs, then those eight manually parked PTYs. Children ran `/bin/sh -c 'stty -echo; printf READY; read line'`. No GUI or remote connection participated.

| Scenario | CPU time before → after | Interrupt wakeups before → after | Package idle wakeups before → after | Physical footprint before → after |
|---|---:|---:|---:|---:|
| Empty service | 14.262 → 0 ms | 916 → 0 | 22 → 0 | 4,506,248 → 4,424,328 bytes |
| Eight quiet PTYs | 18.324 → 0.065 ms | 1,014 → 4 | 36 → 0 | 8,323,792 → 7,996,112 bytes |
| Eight parked PTYs | 16.130 → 0.119 ms | 1,017 → 5 | 32 → 0 | 12,534,528 → 12,043,008 bytes |

All six idle intervals recorded zero disk and logical writes. CPU usage for eight quiet PTYs fell from 0.0916% to 0.000325% of one core in these intervals. Physical footprint remained stable within each interval. Parking released emulator objects but did **not** immediately reduce process footprint: compression and Go allocator high-water memory remained retained. This change does not claim proportional OS-thread or resident-memory reductions.

A separate one-terminal experiment executed twelve real CLI captures, each followed by a 160 ms pause:

| Metric | Before | After |
|---|---:|---:|
| Workspace-file rewrites | 12 | 0 |
| Logical bytes written | 872,448 | 0 |
| Disk bytes written | 49,152 | 0 |
| Service CPU time | 13.783 ms | 4.645 ms |

The `proc_pid_rusage` v6 energy counter also decreased in these samples: empty 14,934,287 → 0 nJ; quiet PTYs 11,059,161 → 71,352 nJ; parked PTYs 14,442,674 → 23,702 nJ. These are kernel-attributed per-process counters on a machine connected to AC, with other development activity present. They are not controlled battery-discharge results or a measured whole-machine energy saving.

## Reproduction and evidence

The sampler is [tests/resource_usage_probe.c](../tests/resource_usage_probe.c). Its CPU counters are converted from Mach absolute ticks using `mach_timebase_info`, and it checks process identity across the measurement. Raw before/after captures and the disposable harness were saved locally as `/tmp/illogical-service-before-resources.json`, `/tmp/illogical-service-after-resources.json`, `/tmp/illogical-query-resources.json`, and `/tmp/illogical-resource-run.py`. The exact measured executables were `/tmp/illogical-service-before` and `/tmp/illogical-service-after`.

```sh
python3 /tmp/illogical-resource-run.py /tmp/illogical-service-before /tmp/illogical-service-before-resources.json
python3 /tmp/illogical-resource-run.py /tmp/illogical-service-after /tmp/illogical-service-after-resources.json
```

The harness starts and stops only its own private `/tmp/illogical-resource-*` daemon and children. It uses `.build/resource-efficiency/resource-usage --pid PID --seconds 20` for each sample. Temporary workspaces were removed afterward.

```sh
cd /path/to/illogical/service
PKG_CONFIG_PATH="$PWD/../.build/ghostty/share/pkgconfig" go test -race ./...
```

Result: exit 0; CLI 1.315 seconds, mux 6.218 seconds. The read-only-disconnect regression was observed failing before the fix and passing afterward. No fresh throughput/FPS comparison was performed in this service-only resource experiment.
