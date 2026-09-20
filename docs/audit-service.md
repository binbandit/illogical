# Service, CLI, and persistence parity audit

Audited 20 September 2026 against [FEATURES.md](../research/superlogical/FEATURES.md), [source notes](../research/superlogical/TRANSCRIPT_NOTES.md), and the original V14 reference frames at [4:01](https://x.com/mitchellh/status/2099622049325232505), [6:15](https://x.com/mitchellh/status/2099622049325232505), and [7:17](https://x.com/mitchellh/status/2099622049325232505). This audit covers the Go service and CLI. It does not certify the native UI, a real remote deployment, or undocumented Superlogical behavior.

**The original audit found incomplete service/CLI parity. See the implementation follow-up at the end for subsequently repaired gaps.** Persistence across client disconnection, coherent snapshot attachment, live layout changes, capture, and block-exit waiting work. Missing commands and incomplete resource/event semantics prevent full parity.

No runtime implementation was changed for this audit. All test shells and daemons used temporary private directories and sockets. They were stopped and removed afterward. Existing application sessions and the default daemon were not touched.

`verified` means the stated behavior has executable evidence within this audit's scope. `partial` means a working subset has a concrete gap. `missing` means no corresponding operation exists. `unverified` means source or a label alone is insufficient. Exact compatibility with Rex's unpublished protocol is not claimed.

The inventory currently gives T-series IDs but no C-series IDs. C01-C47 below are audit-local identifiers covering every listed command, every advertised block method/event, and the remaining demonstrated metadata/lifecycle behavior.

## Critical corrections to parity claims

1. Five demonstrated CLI command families are absent: `attach`, `focus`, `client`, `server`, and `login-server`. A raw `block.attach` RPC and the `serve` process are useful building blocks, but do not provide these command semantics.
2. `wait` supports only a block. V14's visible help also promises waiting for a window or session. Both variants currently fail.
3. `block.inspect` repeats all nine method and ten event names, but lacks the demonstrated block/session IDs, label, creator, flavor, host, placement, and window metadata. Process inspection lacks separate child/foreground executable and user records. `size` returns only rows and columns.
4. `clipboard_written` is sent only to attached terminal clients. The CLI's `events` command enables `watch` without attaching, so it cannot receive this advertised event. Other events use the workspace watcher stream. A matching label list therefore does not establish a complete event interface.
5. `list_dir` does not resolve an explicit relative path as the terminal child would. A real child directory was present under the terminal's cwd; `list_dir("child")` tried the daemon's unrelated cwd and failed.
6. `run` with only `ILLOGICAL_BLOCK` set selects the first session, even when that block belongs to the second session. Explicit `--session` works. The service is not maintaining the demonstrated CLI focus context.
7. `set_theme` changes the authoritative emulator but sends no theme update or resynchronization to already attached clients. Omitted RGB fields decode as black instead of restoring built-in defaults as the source frame describes.
8. The CLI has limited `send-key` support and no key press/release or mouse automation interface. Native keyboard handling is a separate capability and does not close this CLI gap.

## Persistence and attachment

| ID | Target behavior | Status | Code and executable evidence | Gap or limit |
|---|---|---|---|---|
| T03 | GUI detachment leaves processes running and a client can reconnect to current terminal state. | verified | [server tests](../service/internal/mux/server_test.go), `TestProcessesSurviveClientDisconnectAndLayouts`: disconnect, continued output, same PID after reconnect and move. Audit E2 closed every client and reconnected with the same child PID. [Server.serve](../service/internal/mux/server.go) removes subscriptions and ownership without closing blocks. | This verifies the service half of GUI quit/reopen. Explicit block deletion terminates it. E2 service restart changed PID 24567 to 24598 and replaced the original command with `/bin/sh -l`, while retaining the renamed session. No daemon-crash/reboot process or scrollback survival. |
| T06 | Active terminal state becomes available before asynchronous older history, with coherent live continuation. | verified | [Server.attach](../service/internal/mux/server.go): snapshot through Ghostty READY, stream identity, history records afterward on a goroutine. `TestIncrementalSnapshotAndLiveOutput` reconstructs 4,000 history lines, incomplete CSI continuation and later live output. `TestParkedTerminalCanReattachDuringPartialEscapeSequence` covers restored parser state. | The full snapshot is encoded under the block/workspace locks before READY is sent. This audit establishes correctness and asynchronous delivery, not a fixed attach-latency bound or that history encoding is excluded from initial latency. |
| T07 | Inactive emulators park cheaply and PTY readers avoid idle dedicated OS threads. | partial | [Block.park/wake/snapshot](../service/internal/mux/block.go): gzip snapshot, atomic private file, close emulator, restore on output. `TestParkingKeepsProcessAndWakesOnOutput` checks emulator release, PID survival, attach without waking, then output wake. [pollablePTY](../service/internal/mux/pty.go) and `TestPTYRemainsPollableAfterMetadataAndResize` verify Go shared-poller registration survives metadata/resize. | Automatic threshold is hard-coded to 60 seconds and checked every 10 seconds; tests force parking rather than waiting for the automatic threshold. Two I/O goroutines remain per block; there is no dedicated-reader-to-poller transition because all PTYs already use the shared poller. No many-terminal RSS/thread benchmark, configurable threshold, or client-buffer-release certification here. |

## CLI commands visible in V14

Code references below use [CLI.run/waitForBlock](../service/cmd/illogical/main.go), [Server.handle](../service/internal/mux/server.go), and the executable probes described at the end. `verified` applies to the described operation, not every Rex flag or output schema.

| ID | Feature | Status | Code and executable evidence | Gap or limit |
|---|---|---|---|---|
| C01 | `new`: create session and initial terminal. | verified | CLI maps to `session.new`; E3 created First and Second with distinct session/window/block IDs and actual shell children. | Name generation is a small local list; exact Superlogical naming policy is unknown. |
| C02 | `attach`: attach to a session from the CLI. | missing | E2: `illogical attach --block ID` exits 1, `unknown command attach`; CLI command switch has no attach case. | RPC `block.attach` serves native snapshot consumers. `api block.attach` exits after its reply and is not an interactive terminal/session attachment. |
| C03 | `ls` / `list`: list sessions. | verified | Both aliases map to `state`; E3 `list` exits 0; state contains sessions, windows, recursive layouts, blocks and a client count. | JSON presentation differs from the demo's resource-oriented output. |
| C04 | `run`: launch a new command block in the intended workspace. | partial | CLI maps to `window.new`; E2 launched a child in an explicitly selected session and waited for exit 7. | E3 with `ILLOGICAL_BLOCK` in Second, no `--session`, created the tab in First. It always falls back to `state.sessions[0]`; no focused-session lookup. |
| C05 | `split`: split the focused/current block and launch a child. | partial | CLI maps to `block.split`, defaults `--block` from `ILLOGICAL_BLOCK`; real-PTY service tests and E2 create recursive horizontal/vertical splits. | Outside a terminal, there is no server/client focus model to select the focused block implicitly. Exact directional flags from Rex are not reproduced. |
| C06 | `send`: write text to a terminal. | verified | CLI converts remaining words to bytes for `block.write`; E2 writes `go\n` to the real PTY and observes the process's subsequent output. Input is serialized by `Block.writeLoop`. | Text arguments are joined with spaces; arbitrary binary payloads require the wire API. |
| C07 | `send-key`: terminal key automation. | partial | Enter, Escape, Tab, Backspace and Ctrl-A through Ctrl-Z map to control bytes. `TestControlCInterruptsForegroundProcess` and saturated-output tests prove real ETX interruption. | E3 `up` and `shift-enter` fail. No press/release, protocol-aware extended keys, or mouse automation in the CLI/API. |
| C08 | `capture`: text, HTML and VT terminal capture. | verified | CLI `capture` prints `Message.Text`; E2 captured `readyRED` as text, HTML with palette color markup, and VT with SGR color bytes. `Block.capture` uses Ghostty formatters. | Capture wakes a parked emulator. Invalid format names silently fall back to text. Current formatter can include scrollback, so an exact current-screen-only Rex contract is not established. |
| C09 | `kill`: destroy session or block. | verified | CLI chooses `session.kill` with `--session`, otherwise `block.kill`; E3 session kill succeeds. Service removes layouts, closes PTYs and sends SIGHUP to the child process group. | This is explicit destruction, not persistent GUI detachment. |
| C10 | `focus`: focus a block or window. | missing | E2 exits 1, `unknown command focus`; no corresponding service operation or focused-resource fields. | `block.claim` controls terminal sizing/output flow. It does not direct the GUI to focus a resource. |
| C11 | `zoom`: fill a window with one block. | verified | CLI maps to `window.zoom`; E2 verifies the selected window's `zoomed` ID becomes the existing block ID. | Native presentation is outside this service audit. |
| C12 | `move`: reposition an existing running block. | verified | E2 and `TestProcessesSurviveClientDisconnectAndLayouts` move a block to a vertical split, inspect the resulting tree and verify unchanged PID. | No undo or arbitrary Rex flag compatibility claim. |
| C13 | `swap`: exchange blocks without restarting children. | verified | `Server.handle` swaps layout references; E2 checks same child PID after swap. | Native focus behavior is outside this audit. |
| C14 | `resize`: grid and split sizing. | partial | CLI dispatches to `block.resize` or `layout.resize`; E2 resize to 84x24 succeeds; PTY test verifies kernel grid update. | First resize claims ownership, non-owners receive current dimensions; desired sizes are not recorded. CLI does not expose cell-pixel dimensions. See C29/C31. |
| C15 | `session`: create, rename, inspect and destroy resources. | partial | Create/rename/kill are implemented; E2 verifies Renamed persists across audit-daemon restart. | E3 `session inspect --session ID` returns `terminal block not found`. No individual session inspector or focused-window metadata. |
| C16 | `window`: create, rename, inspect and destroy resources. | partial | New/rename/kill/zoom handlers exist; E2 verifies Named tab and live layouts. | E3 `window inspect --window ID` returns `terminal block not found`. No individual window inspector or focused-block metadata. |
| C17 | `block`: inspect and call terminal operations. | partial | Methods/events/process can be inspected; call handlers for all nine advertised names exist, including aliases. E2 inspects these arrays and exercises aliases. | Demo syntax `block call ... process` is not implemented; CLI uses `block process`. `block write` has no payload argument mapping, and CLI cannot construct a theme request. Rich metadata is absent (C46). |
| C18 | `client`: inspect/manage attached clients, including short-lived CLI clients. | missing | E2 exits 1, `unknown command client`. `State.Clients` is only an integer. | No list of client IDs, types, identity, placement, or client resource operations. |
| C19 | `events`: watch server events. | partial | CLI enables `watch` and prints subsequent JSON messages. E2 observes eight event names through the same watcher operation; child-exit tests cover the ninth watcher event. | `clipboard_written` goes to attached streams only. `--block` does not filter `watch`; state messages are included too. No schema/ordering parity guarantee. |
| C20 | `wait`: wait for block/window/session completion and report exit. | partial | `waitForBlock` atomically watches and reads state. E2 real child exits 7 and CLI exits 7 silently; `main_test.go` covers 0/7/130, exit-before-reply, already exited and disconnect failure. | E3 `wait --window ID` and `wait --session ID` both fail requiring a block. An already removed non-keep-open block has no stored completion record. |
| C21 | `api`: inspect and invoke the service API. | partial | `api` returns method names; `api METHOD` dispatches available CLI request fields. Aliases `block.format/list_dir/set_theme` exist in the server. | No arbitrary JSON request body, method parameter schema or descriptions. E3 `api block.set_theme --block ID` fails `theme is missing`; no CLI option can supply Theme. The method list is maintained separately from handlers. |
| C22 | `server`: server management commands. | partial | `serve` runs the daemon; ordinary commands auto-start a detached daemon on connection failure. E2 starts/stops its own daemon successfully. | Exact `server` command exits 1. No demonstrated server resource/management family, status/stop/restart subcommands. |
| C23 | `login-server`: multi-account login server. | missing | E2 exits 1, `unknown command login-server`; no PAM/login broker or per-account actor switching implementation. | An SSH-authenticated per-user service/QUIC channel is a different, narrower capability. |
| C24 | `whoami`: authenticated identity and server actor/route. | partial | E2 prints local `USER`, local numeric UID and selected socket. | It does not query the service and can run without a server. No authenticated principal, server account, route or distinct actor identity as shown in V12. |

## The nine advertised terminal methods

| ID | Method | Status | Code and executable evidence | Gap or limit |
|---|---|---|---|---|
| C25 | `format` | verified | `block.format` aliases `block.capture`; E2 independently exercises text/HTML/VT and sees expected content and color encoding. [Block.capture](../service/internal/mux/block.go). | Screen-versus-history scope and invalid-format behavior noted in C08. |
| C26 | `list_dir` | partial | `block.list_dir` aliases `directory.list`; empty path uses `Block.currentDirectory`, and E2 returns the child cwd plus its child directory. | Explicit relative `child` resolves via `filepath.Abs` in daemon cwd. E2 fails despite directory existing. It is not path resolution as the terminal child would perform it. |
| C27 | `process` | partial | E2 returns real PID, foreground process-group ID, user, cwd, home, launch command and last exit code 7. `TestOSCWorkingDirectoryAndForegroundMetadata` validates cwd and nonzero foreground ID. | [ProcessInfo](../service/internal/mux/protocol.go) is a flat launch-command record. Missing separate child/foreground UID, executable name and path, foreground executable lookup and structured last-exit record visible at V14 6:15. A process-group ID is not comprehensive process enumeration. |
| C28 | `reset` | partial | Handler injects CAN + RIS into the authoritative emulator and sends identical bytes to replicas. E2 verifies screen clears while PID is unchanged. | V14's inspector describes waiting up to 250 ms for a safe parser boundary and reconnecting clients on timeout. Our handler resets immediately with no such synchronization/fallback. Preservation of all configured defaults during reset was not verified. |
| C29 | `resize` | partial | Real terminal/kernel grid resizing and ownership release handlers exist; E2 verifies 84x24 and `size_changed`; PTY/poller regression passes. | No stored per-client desired sizes or re-arbitration. A non-owner request is ignored and returns existing size. Releasing ownership does not apply another client's earlier request. |
| C30 | `set_theme` | partial | `block.set_theme` aliases `block.theme`; handler calls terminal color setters, stores Theme for wake, and returns success in E2. | No update reaches an already attached replica (E2 observed zero messages). Missing optional-color semantics: omitted RGB fields become zero/black; an omitted palette retains its previous value instead of resetting built-in defaults. CLI cannot provide Theme. |
| C31 | `size` | partial | E2 returns `cols`/`rows` before and after resize. | Owner, cell dimensions and desired sizes visible in V14's method description are omitted. Owner exists separately only in whole-workspace BlockInfo. |
| C32 | `title` | verified | OSC 2 changes authoritative title; E2 `block.title` returns `Audit title`; effect also updates BlockInfo and sends title event. | Application-specific title policy is not inferred. |
| C33 | `write` | verified | Raw bytes enter a bounded input queue and single writer. E2 triggers real process output; query/paste/backpressure/Ctrl+C tests pass. | Accepted means enqueued, not proof the child consumed bytes. Limit is 1 MiB/request and 64 queued requests. Mouse/key encoding must be supplied by a caller. |

## The ten advertised events

`Block.installEffects` implements parser-generated events; `Server.handle` implements resize and client-generated event forwarding. E2 used two independent connections: a workspace watcher and an attached terminal stream. This distinction exposed the clipboard gap.

| ID | Event | Status | Code and executable evidence | Gap or limit |
|---|---|---|---|---|
| C34 | `bell` | verified | E2 child emitted BEL; watcher received `bell`. | UI sound/badge behavior outside scope. |
| C35 | `child_exited` | verified | `cmd.Wait` broadcasts status; real exit 7 and ETX exit 130 exercised; CLI race tests cover interleaved arrival. | Non-keep-open blocks are removed soon afterward; no durable event replay. |
| C36 | `clipboard_written` | partial | E2 OSC 52 with `clip-payload` produces event on attached connection. | Absent on watcher/CLI `events`; terminal parser reports success without knowing whether native clipboard was applied. Only `text/plain` is forwarded. |
| C37 | `desktop_notification` | verified | E2 OSC 9 produces watcher event; title/body serialized into Text separated by newline. | OS notification permission/display and richer notification protocol parity outside scope. |
| C38 | `progress_report` | verified | E2 OSC 9;4;1;42 produces watcher event through Ghostty progress effect. | Payload is `state:progress` text, not a documented Rex schema. |
| C39 | `pwd_changed` | verified | E2 OSC 7 emits watcher event; file URL is decoded to filesystem path. Existing cwd/foreground regression passes. | A process changing cwd without emitting OSC 7 is discoverable through process/list_dir inspection but does not itself generate this event. |
| C40 | `selection_copied` | verified | E2 `block.event` with this allowed label reaches watcher; handler forwards block and copied text. | Verifies service forwarding. Native selection gesture producer is outside scope. |
| C41 | `size_changed` | verified | E2 successful 84x24 resize emits event; handler also sends replica resize message. | Rejected non-owner requests and ownership release do not produce this event. |
| C42 | `title_changed` | verified | E2 OSC 2 emits watcher event with `Audit title`; title query agrees. | No replay after a watcher disconnects. |
| C43 | `url_clicked` | verified | E2 allowed `block.event` with URL label/data reaches watcher. | Verifies forwarding, not native link detection or browser opening. |

## Other demonstrated CLI/resource semantics

| ID | Feature | Status | Code and executable evidence | Gap or limit |
|---|---|---|---|---|
| C44 | `--keep-open` retains an exited block; ordinary exited blocks disappear. | verified | E2 child exit 7 remains inspectable with exitCode 7; a second child without keep-open is removed after exit 0. [newBlock](../service/internal/mux/block.go), maintenance finished queue. | This concerns child exit, not service restart. |
| C45 | Key press/release and mouse operations as programmable terminal input. | missing | Request schema has raw Data but no key/mouse actions; CLI supports only its short control-byte list. V14 7:10 describes richer input automation. | Supplying hand-crafted escape bytes is possible but is not the advertised input automation interface. |
| C46 | Block metadata identifies label, session, creator/flavor, host, placement and window. | partial | Whole-workspace state contains block ID and nested placement; `block.inspect` contains process/methods/events. E2 recorded exact fields: `events,id,methods,process,type` where `id` is the request correlation ID. | No resource IDs/label/host/creator/flavor/placement/window in inspection. No user-defined block label field at all. The nine/ten name counts overstate metadata parity. |
| C47 | Shared control model reflects CLI session/window/layout changes without restarting processes. | verified | GUI and CLI use the same service protocol. E2 rename/move/swap/zoom preserves PID; watchers receive updated State from maintenance. Existing layout/disconnect test passes. | Shared focus/client metadata is missing; native update presentation is separately audited. State changes coalesce on a 100 ms maintenance tick. |

## Executed validation and reproducible probes

**E1: existing race suite, rerun uncached during this audit.**

```sh
cd /path/to/illogical/service
PKG_CONFIG_PATH="$PWD/../.build/ghostty/share/pkgconfig" go test -race -count=1 ./...
```

Result: exit 0; `illogical/cmd/illogical` 1.330 seconds; `illogical/internal/mux` 5.792 seconds. This includes the named persistence, incremental snapshot, parking, partial escape, PTY polling, terminal replies, actual Ctrl+C, output ordering/bounds, primary-client turnover, blocked-input and local QUIC authentication/reconnect tests. These passing tests do not cover the missing CLI features above.

**E2: executable + raw protocol acceptance probe.** A Python standard-library harness started `.build/bin/illogical serve` with a temporary `/tmp/illogical-audit-*` directory, `ILLOGICAL_HOME` set to it, `ILLOGICAL_SOCKET` set to its `s.sock`, `SHELL=/bin/sh`, and `ILLOGICAL_BLOCK` unset. The daemon cwd was `/path/to/illogical`. Each wire request was newline-delimited JSON with a unique `id`; Data was base64. The harness stopped its daemon, restarted the same temporary workspace once to verify the failure boundary, then stopped it and removed the directory. It did not use `dial` against the default endpoint.

The fixture created `fixture/child`, then sent `session.new` with cwd `fixture`, `keepOpen:true`, and this exact child command:

```sh
/bin/sh -c "stty -echo; printf ready; read line; printf '\033[31mRED\033[0m\n\007\033]2;Audit title\007\033]7;file://localhost/tmp\007\033]9;4;1;42\007\033]9;Audit notification\007\033]52;c;Y2xpcC1wYXlsb2Fk\007'; sleep 30"
```

After `watch` on one connection and `block.attach` on another, it sent `block.write` with bytes `go\n`. Requests exercised, with their non-ID fields:

```json
{"method":"block.inspect","block":"BLOCK_ID"}
{"method":"block.list_dir","block":"BLOCK_ID","cwd":"child"}
{"method":"block.list_dir","block":"BLOCK_ID"}
{"method":"block.process","block":"BLOCK_ID"}
{"method":"block.size","block":"BLOCK_ID"}
{"method":"block.format","block":"BLOCK_ID","format":"text"}
{"method":"block.format","block":"BLOCK_ID","format":"html"}
{"method":"block.format","block":"BLOCK_ID","format":"vt"}
{"method":"block.title","block":"BLOCK_ID"}
{"method":"block.event","block":"BLOCK_ID","label":"selection_copied","data":"Y29waWVk"}
{"method":"block.event","block":"BLOCK_ID","label":"url_clicked","data":"aHR0cHM6Ly9leGFtcGxlLmludmFsaWQv"}
{"method":"block.resize","block":"BLOCK_ID","cols":84,"rows":24,"cellWidth":8,"cellHeight":16}
{"method":"block.set_theme","block":"BLOCK_ID","theme":{"background":1122867,"foreground":11259375,"cursor":11259375,"palette":[]}}
{"method":"block.reset","block":"BLOCK_ID"}
{"method":"block.split","block":"BLOCK_ID","axis":"horizontal","command":["/bin/sh","-c","sleep 30"],"keepOpen":true}
{"method":"block.move","block":"BLOCK_ID","target":"OTHER_BLOCK_ID","axis":"vertical"}
{"method":"block.swap","block":"BLOCK_ID","target":"OTHER_BLOCK_ID"}
{"method":"window.zoom","window":"WINDOW_ID","block":"BLOCK_ID"}
{"method":"session.rename","session":"SESSION_ID","label":"Renamed"}
{"method":"window.rename","window":"WINDOW_ID","label":"Named tab"}
```

Observed text capture `readyRED`; HTML contains inline palette-1 markup; VT contains `ESC[38;5;1mRED`. Watcher received bell, title, pwd, progress, notification, selection, URL and size events. Only the attached connection received clipboard. Theme request returned success but no attached-stream update. Reset cleared capture and retained PID. Move/swap also retained PID. All-client disconnect retained PID. Restart retained layout/name, changed PID and launched a fresh login shell.

These actual CLI argument sequences were also executed against that private endpoint, substituting IDs returned by creation:

```sh
illogical attach --block BLOCK_ID
illogical focus --block BLOCK_ID
illogical client --block BLOCK_ID
illogical server --block BLOCK_ID
illogical login-server --block BLOCK_ID
illogical run --session SESSION_ID --keep-open -- /bin/sh -c 'sleep .2; exit 7'
illogical wait --block EXITING_BLOCK_ID
illogical whoami
```

The first five returned unknown-command errors. The wait process exited 7 with empty stdout/stderr. A separate wire `window.new` child `/bin/sh -c 'sleep .1; exit 0'` without keep-open disappeared from state after 300 ms.

**E3: CLI context and resource semantics probe.** A second temporary service used `/tmp/illogical-cli-audit-*`, the same isolated environment pattern and `/bin/sh`. The following exact argument vectors were invoked by `subprocess.run`, again substituting returned resource IDs:

```sh
illogical new First --keep-open -- /bin/sh -c 'sleep 30'
illogical new Second --keep-open -- /bin/sh -c 'sleep 30'
ILLOGICAL_BLOCK=SECOND_BLOCK_ID illogical run --keep-open -- /bin/sh -c 'sleep 30'
illogical wait --window FIRST_WINDOW_ID
illogical wait --session FIRST_SESSION_ID
illogical session inspect --session FIRST_SESSION_ID
illogical window inspect --window FIRST_WINDOW_ID
illogical send-key up --block FIRST_BLOCK_ID
illogical send-key shift-enter --block FIRST_BLOCK_ID
illogical api block.set_theme --block FIRST_BLOCK_ID
illogical list
illogical kill --session SECOND_SESSION_ID
```

`run` returned First's session ID. The two waits exited 1 requiring a block; both inspectors exited 1 with `terminal block not found`; both keys exited 1 as unsupported; set_theme exited 1 with `theme is missing`. List and kill exited 0. The disposable service was then terminated and its directory removed.

Binary used by E2/E3: `/path/to/illogical/.build/bin/illogical`, SHA-256 `4d51f35af54635a347e41931cd741cd47cd3d5bf8a929c167bd1788d854c58bf`, recorded at 2026-09-20T09:46:29Z. E1 compiles current sources independently. No test failures were hidden or converted into passes: missing features and semantic mismatches are recorded as gaps rather than being asserted by the existing test suite.

## Implementation follow-up: 20 September 2026, service parity package

The preceding tables preserve the original audit and its failures. The following changes supersede the named gaps; they do not retroactively change what the original probes observed. Work used private test sockets and real shell subprocesses. The default daemon and existing sessions were not changed.

| Audit items | Current implementation and evidence | Remaining qualification |
|---|---|---|
| T07 | Automatic parking now uses the earliest actual idle deadline, with no periodic wake when empty/fully parked. `TestAutomaticParkingUsesLastOutputDeadline` exercises postponement, automatic park, wake and same PID. [Resource measurements](resource-service.md) quantify idle CPU/wakeup and read-only write reductions. | Threshold remains 60 seconds; process allocator footprint does not immediately shrink after parking. The measurement binary predates the subsequent optional Tailscale dependency. |
| C01, C10 | CLI `attach`/`focus` selects a native client's session/window/block. Service sends one `focus` message, preferring the current owner, then suitable native/attached watchers; `--client` selects explicitly. `TestResourceInspectionFocusAndClientDetach` checks all resource IDs and client routing. | Native selection/activation is separately tested by the native agent. This is not a legacy terminal-text frontend. When no viewer exists, focus is recorded but no GUI process is launched. |
| C04, C26 | `window.new` inherits session and cwd from the invoking block; CLI no longer forcibly chooses the first session. Relative `list_dir` paths resolve against the terminal process cwd. `TestRelativeDirectoryAndImplicitSessionUseTerminalContext` and the CLI E2E test reproduce both formerly failing cases. | Paths remain server-side paths; invalid explicit resource IDs fail. |
| C07, C45 | `block.key`/`block.mouse`, CLI `send-key`/`send-mouse`, and JSON input actions use Ghostty's encoder with authoritative terminal modes. Press/release/repeat, modifiers, named keys, text, zero-based cells and pixel-coordinate mouse API are supported. `TestProtocolAwareKeyAndMouseReachRealProcess` checks application-cursor Up, Kitty key-release, and SGR mouse bytes read by a real raw-mode PTY child. | Releases produce no bytes when the running program has not enabled a protocol that reports releases. Mouse reporting likewise follows child-enabled modes. No claim of Rex's exact unpublished schema. |
| C14, C29, C31 | `block.size` now includes current owner, grid, cell dimensions and each client's desired size. Non-owner requests are retained; release/detach/disconnect applies an eligible remaining request. `TestDesiredResizeTransfersWhenOwnerReleases` checks metadata, release, disconnect and actual `stty size`. | Deterministic client-ID order arbitrates remaining requests; this does not establish Rex's exact arbitration policy. |
| C15, C16 | Individual session/window inspectors return cloned resource trees, focused resource IDs and associated clients. Focus is repaired when blocks/windows disappear or move. Real CLI subprocess acceptance covers both inspectors. | Resource models are illogical's protocol, not a wire-compatible implementation of Rex. |
| C17, C21 | `block call ID METHOD`, `block write`, `--data`, `--theme JSON`, and `--json REQUEST_JSON` expose method payloads. Method listing includes the added operations. `TestCLIResourceAndAutomationEndToEnd` executes the public CLI argument path. | No generated parameter/description schema or promise of exact Rex flag compatibility. |
| C18 | `client list/inspect/rename/detach` and `client.update` expose client ID, kind, label, transport, connection time, subscriptions and focused placement. Ordinary CLI clients register kind `cli`. Detach closes the connection and leaves the child running, checked with unchanged PID. | These are service client resources, not a multi-account login/authorization system. Kind and label are descriptive client-provided metadata. |
| C19, C36 | Clipboard writes reach the union of watchers and attached clients once. `TestClipboardWrittenReachesWatchersAndAttachedExactlyOnce` verifies a real OSC52 producer and a client that is both watching and attached. CLI events supports block/window/session filtering. | Filtering is client-side; it is not a server-side access-control boundary or durable event replay. |
| C20 | Window/session waits atomically watch and snapshot the children currently placed in that resource, then preserve exit statuses. Real CLI subprocesses verify window exit7 and session exit0, alongside existing block0/7/130/interleaving/disconnect tests. | New children do not extend an already-running wait. Removal before a child exit is observed returns an error. Exact Rex behavior for these edge cases is not established. |
| C22, C24 | CLI `server start/status/inspect/stop`, `serve`, and service-backed `whoami` query the connected server's PID/UID/host/socket/version/start time. Stop acknowledges before shutdown; local status/inspect/stop never auto-start a missing service. CLI E2E checks identity, clean stop, and status failing afterward. | No `server restart` or multi-account `login-server` in this package. Remote authenticated principal details belong to the separately audited transport package. |
| C27 | Process inspection adds lazy `child` and `foreground` records with actual PID, UID/user, name and executable path, using macOS libproc or Linux procfs. Legacy fields remain compatible. No idle/process polling or per-output process lookup was added. | Foreground is the PTY foreground process-group leader; if it has exited/unavailable, that record is absent. This is not enumeration of every process in a pipeline. |
| C28 | Reset uses Ghostty's `VTGround`/`VTWriteUntilGround` to wait up to250ms for the shortest parser boundary. It inserts RIS before the remaining output. On timeout it cancels unfinished parsing, resets and coherently snapshots attached replicas. Tests cover actual split CSI/UTF8, stalled-sequence timeout, unchanged PID, preserved theme defaults and a grounded reconstructed replica. | Timeout uses coherent stream reattachment on the existing authenticated connection rather than disconnecting the network transport. |
| C30 | Optional RGB fields distinguish omitted defaults from explicit black. Empty palette restores built-in256 colors; invalid sizes/RGB values fail. Updates and later attachments carry `theme` messages. `TestThemeDefaultResetAndAttachedPropagation` checks defaults, palette and replica messages. Native Bridge/Engine coverage separately verifies rendering and OSC override preservation. | Theme defaults are not a claim of persistent full native settings across daemon restart. |
| C46 | Block inspection returns resource ID, label, creator client ID, host, terminal flavor and session/window placement. `block rename` changes its label; saved labels survive layout restore. The resource-inspection regression verifies populated IDs and unchanged child identity. | Creator is the originating connection ID, not a PAM identity or an authenticated principal from a multi-account broker. |

Capture now rejects unsupported format names instead of silently returning text. Existing text/HTML/VT capture and process persistence across client detach remain covered. Daemon death/reboot still recreates shells, not the original processes or their complete scrollback. No service implementation can claim process survival across reboot from these tests.

New tests are in [mux/parity_test.go](../service/internal/mux/parity_test.go), [mux/maintenance_test.go](../service/internal/mux/maintenance_test.go), and [CLI/parity_test.go](../service/cmd/illogical/parity_test.go). The CLI fixture invokes the actual `main` entry point in child test processes over a private Unix socket, exercising argument parsing, JSON request/reply handling and exit status. All children and private services are cleaned up.

```sh
cd /path/to/illogical/service
PKG_CONFIG_PATH="$PWD/../.build/ghostty/share/pkgconfig" go test -race ./...
```

The service/CLI package passed the full race suite after reset coverage: CLI 1.863 seconds and mux 7.267 seconds. Subsequent replay/viewport checks are recorded below. Optional SSH/Tailscale/NixOS deployment work is separately owned and validated; the resource-only measurements must not be presented as measurements of that expanded dependency closure.


### Bounded reconnect replay and opt-in viewport sharing

R10 now has an executable service contract. Each block owns an epoch (`replayID`) and monotonically increasing mutation sequence. Output, resize, and theme records carry `previousSequence` and final `sequence`. Adjacent output batching preserves the first predecessor and last sequence; a gap or different epoch prevents batching. A complete snapshot supplies the baseline. Its asynchronous history and initial theme configuration repeat that baseline without advancing it.

A client with a complete initial history can attach with its epoch/last-applied sequence. `resume` binds a new transport stream to the existing replica, followed by retained mutations in order. The service retains at most 8 MiB of charged records and 4,096 records per block, sharing existing immutable PTY byte slices rather than copying them again. This is a byte/record bound, not a fixed outage-duration promise: a high-output producer exhausts it sooner. Parking frees the replay records. Expired/ahead cursors and different epochs produce explicit `resync` with a reason, followed by a coherent snapshot. A forced parser-reset recovery changes the epoch. Unfinished initial history must request a snapshot rather than mutation replay. Notifications and clipboard events are not a durable event log.

`TestBriefDisconnectReplaysOrderedMutationsAndOverflowResyncs` uses a real PTY producer. It disconnects after a complete snapshot, writes output, resizes, changes theme and writes again, then reconstructs the exact authoritative text through replay and verifies live continuation. A second disconnect produces over 9 MiB; the test verifies bounded retention, an explicit resync/snapshot and the unchanged child PID. `TestOutputBatchPreservesReplayContinuity` verifies coalescing preserves the sequence interval and cannot hide a gap. This proves local protocol behavior; real remote outage duration and network acceptance remain separate validation.

T08 is opt-in per attached connection via `block.viewport`: optional `synchronized` toggles sharing; optional `viewport` is a nonnegative line distance from the bottom. Only other attached, opted-in clients receive `viewport` messages. Default clients remain independent; a new connection starts opted out. Out-of-range offsets fail against authoritative available history. The server never changes PTY dimensions, authoritative viewport, or selection. It uses cached history bounds while parked, avoiding emulator wake-up.

`TestViewportSharingRequiresOptInAndNeverWakesParkedTerminal` exercises three actual connections, default isolation, both directions after opt-in, opt-out, out-of-range rejection, disconnect/reconnect, unchanged terminal dimensions and a still-parked emulator. It also verifies parking drops the replay cache. Native scrolling gestures and visual placement are validated separately. The focused replay/viewport race run passed in 2.080 seconds.


Final integrated service race run after the focus-claim correction passed: `illogical/cmd/illogical` 1.838 seconds and `illogical/internal/mux` 7.870 seconds. The new two-pane regression also exposed empty block IDs matching split containers; empty IDs now cannot identify a window or produce false client placement. Native `block.claim` updates focused-window/block metadata without emitting an activation message.

Remaining limits in this lane: native `attach` does not launch a GUI or provide a legacy text-terminal frontend; window/session waits use the documented initial child set; process inspection identifies the foreground group leader rather than every pipeline member; events are not durably replayed; capture scope and protocol/flag equivalence with unpublished Rex internals remain unverified. The optional PAM helper opens sessions for the same Unix account and is not a multi-account login broker. Actual remote deployment acceptance and final expanded-binary resource/throughput measurements are separate work, not implied by the local passing suite.

### Static image and compatibility follow-up

Static Kitty RGB/RGBA/PNG images now have bounded canonical service storage and sequenced image/placement updates. Real PTY tests verify reconnect snapshots, mutation replay, offscreen placement coordinates, resize, primary/alternate screen registries, deletion and an 8 MiB image delivered intact over JSON/Unix transport. A mid-APC reconnect at 2 MiB also succeeds. The full mux race suite passed in 12.386 seconds with this implementation. At that run the separate CLI package exposed an in-flight remote-probe test failure, reported to its owner; this result is not represented as a full-repository pass.

The remote owner subsequently fixed the probe's `io.Copy` fast-path bypass and reran the complete CLI race suite successfully in 2.965 seconds (`.build/remote-cli-final-tests.txt`).

The [graphics service contract](graphics-service.md) records resource budgets, the narrow pinned Ghostty resource patch and remaining limits. Image-bearing emulators conservatively stay resident after APC traffic until explicit reset because snapshot v1 omits image state. This is not full Kitty parity: native animation and Unicode virtual placement rendering remain unsupported. Direct image transfer is supported; file/shared-memory transfer is disabled.

Subsequent native acceptance exposed incorrect live cursor/grid effects when the replica ignored image commands. Image content/placement changes now establish selective correction snapshots and invalidate earlier replay cursors; geometry-only scrolling/resizing and ordinary text do not. A real PTY regression verifies text and cursor equivalence after both a new image and a later placement using its ID, plus explicit replay fallback across the correction boundary. The cost of encoding and streaming history for these image changes is documented, rather than represented as efficient video/animation support.

Hello messages now add optional `features`: `viewport`, `replay`, `graphics`, `theme-events`, `client-focus`. The protocol and snapshot engine version remain compatible. New native clients can use this list to suppress optional requests against an older running service without terminating existing user processes.

Final service/CLI validation after all three pinned graphics policies and the live image-grid correction passed: `CGO_CFLAGS="-O2 -g -mmacosx-version-min=15.0" CGO_CXXFLAGS="-O2 -g -mmacosx-version-min=15.0" CGO_LDFLAGS="-mmacosx-version-min=15.0" PKG_CONFIG_PATH="$PWD/.build/ghostty/share/pkgconfig" go -C service test -race -ldflags=-buildid=illogical-static-graphics-final ./... -count=1`, CLI 2.961 seconds and mux 12.496 seconds. Bootstrap explicitly builds the terminal library for `aarch64-macos.15.0`.
