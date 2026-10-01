# illogical

A native macOS terminal multiplexer modelled on the public Superlogical previews. The app uses SwiftUI and AppKit for its interface, Metal and Core Text for rendering, the pinned Ghostty terminal library for terminal state and input encoding, and a Go service that owns the terminal processes.

## Download

The [releases page](https://github.com/binbandit/illogical/releases) carries the builds the release workflow produces:

- `illogical-VERSION-macos-arm64.dmg` for Apple Silicon Macs on macOS 15 or later. Open it and drag illogical to Applications. The CLI travels inside the bundle; link it with `ln -s /Applications/illogical.app/Contents/Resources/bin/illogical ~/.local/bin/illogical`.
- `illogical-service-VERSION-linux-x86_64.tar.gz` and its `aarch64` counterpart for remote Linux hosts, glibc 2.34 or newer. These carry the service and CLI only: `sudo install -m755 bin/illogical /usr/local/bin/illogical`.

Check a download against the release's `SHA256SUMS`. A release built without a Developer ID certificate is ad-hoc signed and not notarized, so macOS refuses it until the download quarantine is cleared with `xattr -dr com.apple.quarantine /Applications/illogical.app`. See [releases](docs/releases.md) for the workflow, the optional signing secrets, and how to produce the same archives locally.

## Build

Apple Silicon, macOS 15 or later, Xcode with the Metal toolchain, Go 1.27.1 or later, and `pkg-config` are required. The initial bootstrap downloads the pinned Ghostty source and Zig compiler, then builds the terminal library.

```sh
./scripts/bootstrap.sh
CONFIGURATION=Release ./scripts/build.sh
```

The app is produced at `.build/xcode/Build/Products/Release/illogical.app`. Its CLI is bundled at `Contents/Resources/bin/illogical`. Release builds should be used for performance comparisons.

The same bootstrap runs on x86_64 and aarch64 Linux, where it builds the terminal library for the service and CLI alone; `./scripts/package-linux.sh` writes the distributable archive for a remote host.

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

The client supports horizontal and vertical tabs, nested splits, pane zoom and resizing, session and command pickers, a host-side directory picker, a floating search in each pane, tab previews and a session overview, paired light/dark themes, and Ghostty theme import. Rendering includes Nerd Font fallback, colour emoji, exact block graphics, ligatures, selection, links, mouse reporting and static Kitty images.

Each window shows one session, and a session appears in at most one window: choosing a session that another window shows brings that window forward. Quitting and closing windows only detach; every window comes back on the next launch. Closing a pane, tab or session ends its processes and asks first when a program other than the shell is running. When a session's last terminal closes, its window moves on to the most recently used session that no other window shows, and closes only when there is none.

The session picker (Command-K) opens on the current session and keeps sessions in a fixed order, so Command-1 to 9 always choose the same one; Command-Delete closes the highlighted session. Rename a session by right-clicking it in the picker or the session name in the titlebar, or with Option-Shift-Command-I; rename the current tab with Shift-Command-I or by right-clicking it.

Every command is in the command palette (Shift-Command-P), which is also the first item in the View menu and the last in the terminal's right-click menu.

The shortcuts follow Ghostty's defaults, with Superlogical's where it differs. Menus, the command palette and this table share one command list (`illogical/WorkspaceCommands.swift`).

| Action | Shortcut |
| --- | --- |
| New window / session / tab | Command-N / Shift-Command-N / Command-T |
| Close pane / tab / window / all windows | Command-W / Option-Command-W / Shift-Command-W / Option-Shift-Command-W |
| Show next / previous tab | Shift-Command-] / Shift-Command-[ or Control-Tab / Control-Shift-Tab |
| Select tab / last tab | Command-1 through Command-8 / Command-9 |
| Move tab left / right | Option-Shift-Command-[ / Option-Shift-Command-] |
| Split right / down | Command-D / Shift-Command-D |
| Select next / previous pane | Command-] / Command-[ |
| Select pane in a direction | Option-Command-arrow key |
| Resize pane / equalize panes | Control-Command-arrow key / Control-Command-= |
| Zoom pane | Shift-Command-Return |
| Switch session / command palette | Command-K / Shift-Command-P (press again to close) |
| Find / next / previous | Command-F / Command-G / Shift-Command-G while a search is open |
| Go to directory | Shift-Command-G |
| Clear screen and scrollback | Option-Command-K |
| Bigger / smaller / actual size text | Command-= or Command-+ / Command-- / Command-0 |
| Scroll to top / bottom | Command-Home / Command-End |
| Show all tabs / session overview | Shift-Command-\\ / Shift-Command-O |
| Vertical tabs | Shift-Command-S |
| Rename tab / session | Shift-Command-I / Option-Shift-Command-I |
| Full screen | Command-Return or Control-Command-F |
| Settings | Command-, |

Drag down with three fingers to reveal tab previews, or continue farther to open the session overview. Small and sideways movements leave the workspace in place. Press Escape or click the close control to return; clicking the visible terminal also dismisses tab previews. Terminal input pauses while previews or the overview are open.

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

## Terminal

Terminals behave like Ghostty with its default macOS key bindings: Command-Left/Right/Backspace edit the line, Option-Left/Right move by word, Command-Up/Down jump between shell prompts, and unbound Command chords never reach the shell. At launch the app reads `keybind` entries and `macos-option-as-alt` from your Ghostty configuration, so bindings such as `shift+enter=text:\x1b\r` keep working. Pasting multi-line text into a program without bracketed paste asks first.

The default font is the bundled JetBrains Mono at 13 points. Settings can import Ghostty's font family, size, features, variations, thickening, cell height and cursor style, and its themes.

## Development

```sh
just test
```

`scripts/test.sh` runs everything: Go race tests for the service and CLI with real pseudo-terminals, the terminal bridge in C, keyboard and mouse input through real AppKit events, Metal rendering read back pixel by pixel, and the workspace model against a scripted service. See [rendering](docs/rendering.md), [graphics compatibility](docs/graphics-compatibility.md) and [the graphics service](docs/graphics-service.md) for renderer details, [remote deployment](docs/remote-deployment.md) for SSH, Tailscale, PAM and NixOS, and [releases](docs/releases.md) for packaging.

The client and service each parse terminal output, the service authoritatively and the client for its own view, so every window scrolls, selects and searches independently of the service.

[The research](research/superlogical/README.md) collects the Superlogical videos, developer replies and the measured visual spec this app follows. Theme values and gesture thresholds are inferred from recordings, not recovered from private source code.

Third-party components and their bundled license texts are listed in [the dependency notices](THIRD_PARTY_NOTICES.md).
