# Building illogical from the evidence

The target is fidelity to the demonstrated behavior, appearance, and interaction model. New product ideas should not substitute for missing evidence. The [feature inventory](FEATURES.md) is the scope ledger; [visual references](VISUAL_REFERENCE.md) are the appearance baseline.

The repository now contains a working native client and persistent service. The plan below is the acceptance baseline, not a claim that every check has passed. See the [project README](../../README.md) for current capabilities and known limits.

## 1. Prove terminal persistence and the rendering bridge

Build one terminal end to end: a service owns its PTY and child; the native client attaches, displays it, accepts real input, detaches, and reattaches through a libghostty snapshot. Pin one Ghostty revision for both sides. Verify the public client-embedding path before designing the rest of the app around it.

Use the current app identifier and an isolated development service/socket. The service must not interfere with the user's existing terminal applications or shell setup. Update the starter's platform targets and entitlements deliberately for a native macOS application and its helper architecture.

Acceptance:

- Run an increasing counter, quit the app, wait, reopen, and observe the counter has continued, matching V09.
- Run a real shell, editor, and monitor. Unicode, cursor movement, alternate screen, terminal modes, and input remain correct after reattachment.
- Attach a second client with an independent viewport and selection; both receive coherent output.
- Restore the active screen before a deliberately delayed large scrollback finishes transferring. Input remains usable.
- Snapshot while a multibyte character or escape sequence is incomplete; restoring and continuing the byte stream produces the same state.
- Disconnect a slow client without corrupting or blocking the remaining client. No unbounded output accumulation.

Completion means a real persistent terminal, not a screenshot, simulated output, or one subprocess tied to a view's lifetime.

## 2. Introduce the session and block model

Add stable host/session/window/block/client identities, resource queries, and recursive split layout. Keep process ownership outside SwiftUI view lifecycle. Add session create/rename/delete, tab create/close, block split/move/resize/focus/zoom, and restoration of the last selected session.

Acceptance:

- Create two named sessions, each with several tabs, and switch using the titlebar picker and Cmd-K.
- Move a running editor from the right split to the lower split; its PID and state remain unchanged, matching V14.
- Two native windows can navigate sessions without accidentally spawning duplicate PTYs.
- Changing layouts and switching tabs preserve scrollback and live processes.
- Define and exercise resize ownership with clients of different dimensions.
- Define block close, child exit, `--keep-open`, session deletion, and client detachment as distinct operations.

## 3. Match the native workspace UI

Implement the latest evidenced titlebar, tab strip, split headers, session picker, and command palette. Match comfortable and compact density. Use real terminal content during visual review so layout decisions are not distorted by placeholder text.

Add horizontal tabs scoped to one session and vertical navigation spanning sessions and hosts. Add process/deck icons once the underlying metadata is reliable. Implement the remote-capable directory chooser as a service operation, even while only a local host exists.

Acceptance:

- Reproduce selected reference scenes at a controlled window size, then compare screenshots for spacing, typography, selected states, borders, materials, and clipping.
- Verify selection, scrolling, focus, keyboard navigation, and context changes through the actual native UI.
- Cmd-Shift-G lists directories belonging to the current block's host and opens the selected location.
- Opening a floating search field does not change PTY rows/columns or cause TUI reflow.
- The search field moves out of the way of the active match.
- Use UI accessibility support and reduced-motion behavior appropriate to a native application, while recording these as implementation quality choices where the source provides no detail.

## 4. Add peek and the session overview

Build the three-finger downward gesture as a continuous transition: normal terminal, tab peek, then session overview. The terminal grid remains the same size during the transition. Previews display live content and complete split layouts.

Acceptance:

- Verify no terminal resize is sent while revealing or dismissing the preview strip.
- Preview content advances while an active process runs.
- Selecting a preview focuses the corresponding existing session/tab.
- Cancelling or reversing the gesture leaves selection and terminal state coherent.
- Test several sessions and dense split layouts. Animation and preview rendering must not make the active terminal unresponsive.

Exact gesture thresholds and keyboard bindings are unknown. Keep those choices explicit and adjustable until further evidence appears.

## 5. Expose the same operations to the CLI

Implement resource inspection and the demonstrated command families before copying every visible help entry. Use one service contract for GUI and CLI. Provide typed responses and ordered events with documented scope. Preserve source command names where they help parity, while using the `illogical` executable name.

Acceptance:

- Reproduce V14's sequence: create session, launch monitor, split editor, move editor, run a short-lived child with keep-open, wait, inspect, rename, watch events, capture, and kill.
- Verify event subscription cleanup and distinguish connection events from terminal events.
- Return useful child/foreground process metadata without freezing the terminal on process exit.
- Capture text, HTML, and VT against deliberately styled terminal content.
- Exercise key press/release and mouse input with a real terminal program.
- Publish help/schema information from the same definitions as the implementation so the CLI cannot drift from the service.

The 2048 demonstration is an optional parity exercise for the API, not an application feature to prioritize.

## 6. Reproduce remote behavior

Add Linux service support, authenticated remote attachment, remote session management, host grouping, and remote directory access. Introduce QUIC/fallback transport and Tailscale discovery deliberately. Direct privileged login requires an explicit principal-to-Unix-user policy; SSH-backed operation can be implemented as a separate supported path.

Acceptance:

- Match V12 using a disposable development host: add host, create/rename remote session, open multiple splits, inspect identity, create from the local CLI, reopen the app, then remove the session.
- Confirm the shell has the correct user's environment, working directory, initialization, permissions, and limits.
- Remote directory listing and new terminal creation occur on the selected remote host.
- New Session from the picker targets the host of the currently focused session.
- Simulate network interruption and reconnection. The child remains alive; client state converges without duplicated input or output.
- Test authorization failures and inaccessible hosts as actual UI states rather than silent fallbacks to the local machine.

## 7. Theme fidelity and memory parking

Themes, chrome materials, density, Ghostty theme import, and contrast correction can be developed alongside the later functional milestones once rendering is stable. Record palette values as estimates until authoritative values are available. Do not present a guessed palette as an exact recovered theme.

Add emulator and PTY-reader parking only after the ordinary snapshot path is reliable. Measure baseline resource use first, then validate both correctness and savings.

Acceptance:

- Theme changes update terminal colors and chrome coherently in light and dark appearance.
- Ghostty theme migration previews and applies the imported light/dark pair, with the demonstrated confirmation flow.
- Contrast correction improves the evidenced difficult foreground/background combinations without globally destroying the intended palette.
- Parking releases measurable resources while the child process continues running.
- Output, resize, and attachment racing with parking never lose state.
- Attaching to a parked terminal can render from persisted state.
- Test crash recovery separately from GUI quit. State any process-loss boundary accurately.

## Fidelity ledger

Track every requirement with: source ID and timestamp, evidence level, implementation location, acceptance result, visual comparison, and unresolved differences. A feature is not “matching” simply because its label exists in a menu.

The first milestone should settle the hardest architectural uncertainty: **a daemon-owned terminal restored into a real native client using the public Ghostty state APIs**. Once that works, the rest of the product can be built on the same persistence model demonstrated by Superlogical.
