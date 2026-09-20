# illogical

A native macOS terminal multiplexer built from the public Superlogical/Rex previews. The app uses SwiftUI and AppKit for its interface, Metal and Core Text for rendering, pinned Ghostty terminal state and input APIs, and a Go service that owns the terminal processes.

## Build

Apple Silicon, macOS 15 or later, Xcode with the Metal toolchain, Go 1.27.1 or later, and `pkg-config` are required. The initial bootstrap downloads the pinned Ghostty source and Zig compiler, then builds the terminal library.

```sh
./scripts/bootstrap.sh
CONFIGURATION=Release ./scripts/build.sh
```

The app is produced at `.build/xcode/Build/Products/Release/illogical.app`. Its CLI is bundled at `Contents/Resources/bin/illogical`. Release builds should be used for performance comparisons.

## Install

With the build prerequisites and [just](https://just.systems/) installed, run:

```sh
just install
```

This builds the pinned terminal library and Release app, verifies the app signature, installs `illogical.app` into `/Applications` when writable (otherwise `~/Applications`), and links the CLI at `~/.local/bin/illogical`. Open illogical from Applications. Add `~/.local/bin` to your shell's PATH if it is not already there.

Run the same command to update. Quit the installed GUI first; the installer leaves terminal services and their processes running. New service features become available after the existing service is stopped, which ends its terminal processes, so do that only after finishing those sessions. This is a local ad-hoc signed build, not a notarized distribution.

Optional `ILLOGICAL_APP_DIR` and `ILLOGICAL_BIN_DIR` environment variables select absolute installation directories. The installer refuses to overwrite unrelated applications or commands. `just build` and `just test` are also available.

## Workspaces

The service keeps sessions, tabs, recursive split layouts, shell processes, and terminal state alive when the app quits. Closing a terminal explicitly terminates that terminal. Restarting the service currently restores the saved layout with new shells; it does not preserve processes or their scrollback across a service restart.

The native client supports horizontal and vertical navigation, pane movement and resizing, zoom, session and command pickers, a remote directory picker, independent floating searches in each pane, live tab previews, session overview, paired light/dark themes, and Ghostty theme import. Rendering includes Nerd Font fallback, colour emoji, exact block graphics, selection, links, terminal mouse reporting, and bounded static Kitty images. Copy-on-selection and synchronized scrolling are optional. Public previews establish the reference, but this is an independent implementation and exact feature and visual parity remains under validation.

Useful shortcuts:

| Action | Shortcut |
| --- | --- |
| New session / tab / window | Command-N / Command-T / Shift-Command-N |
| Split right / down | Command-D / Shift-Command-D |
| Switch session / commands | Command-K / Shift-Command-P |
| Find / choose directory | Command-F / Shift-Command-G |
| Overview / tab previews | Shift-Command-O / Shift-Command-Space |
| Vertical navigation | Control-Command-V |
| Zoom / close pane | Shift-Command-Return / Shift-Command-W |

## Service and CLI

The default service directory is `~/.local/share/illogical`. The service directory and socket are private to the current user. `ILLOGICAL_HOME` and `ILLOGICAL_SOCKET` select an isolated development instance. The service starts automatically on the first connection.

```sh
illogical new project --cwd /path/to/project
illogical split --block BLOCK_ID --axis vertical
illogical send 'pwd' --block BLOCK_ID
illogical send-key enter --block BLOCK_ID
illogical capture --block BLOCK_ID
illogical events
illogical help
```

`ILLOGICAL_BLOCK` identifies the current terminal for commands run inside it. `wait` returns the child's exit status. Text, HTML and VT captures are available. Run `illogical api` to inspect the current service methods.

Remote hosts use an existing SSH identity and known-host entry. SSH bootstraps short-lived mutually authenticated QUIC credentials, with SSH transport as a fallback. The remote host must have the same `illogical` service installed. Optional embedded Tailscale registration and service discovery support explicit user/tag admission. Linux builds can use a same-user PAM login helper; the repository includes a pinned Nix package and NixOS module. Actual loopback OpenSSH fallback, Linux PAM, and Nix-built service checks pass. External-host and live-tailnet acceptance remain outstanding. See [remote setup and limits](docs/remote-deployment.md).

## Validation and fidelity

The [feature parity audit](docs/feature-parity.md) is the current acceptance ledger.
It records verified behavior, missing features, and reproduced defects against
the videos and developer replies. Full Superlogical feature parity is not achieved.

```sh
./scripts/test.sh
```

Input tests use real pseudo-terminals to check interruption, suspension, EOF and Ghostty key encoding. Service tests cover persistent processes, streamed snapshots and history, layout operations, parking, input backpressure, remote authentication, and reconnects. The rendering suite exercises the actual Metal shader and font rasterizer. See [rendering behaviour and limits](docs/rendering.md) for the verified cases. Appearance settings can import Ghostty's font family, size, OpenType features, variable axes and thickening settings.

The client currently uses the public `libghostty-vt` state API with our own renderer. This is not the complete Ghostty application renderer. Static Kitty image support has [explicit compatibility and memory limits](docs/graphics-compatibility.md); image animation, Unicode virtual placements, and the entire Ghostty configuration surface are not reproduced. The daemon and client both parse terminal output to support authoritative persistent state and independent client views, so zero overhead relative to a standalone terminal cannot be assumed.

See [performance validation](docs/performance.md) and [resource measurements](docs/resource-efficiency.md) for measured startup, DOOM Fire, idle wakeups, memory bounds, and redraw scheduling. A matched Ghostty baseline is still required before claiming performance parity.

See [the research](research/superlogical/README.md) for the source videos, narration notes, visual references, and acceptance plan. Theme values and some gesture thresholds were inferred from recordings, not recovered from private source code.

Third-party components and their bundled license texts are listed in [the dependency notices](THIRD_PARTY_NOTICES.md).
