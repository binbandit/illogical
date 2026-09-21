# Additional parity and correctness audit

Audited application revision: `09ad6936c21d37feeae0c5fe12342709f2805e7b`, 21 September 2026. This pass found ten additional actionable issues, confirmed the previously unverified selection-autoscroll gap, and reproduced one unusual Unicode limit. All remain unfixed at the audited revision. The font-clarity corrections in that revision are not repeated as new findings.

Three independent audits covered service/CLI behavior, native terminal input, and workspace state. A separate native UI check confirmed the zoom/focus failure. Service probes used a new private daemon with disposable children. Workspace probes compiled the production model and connection code against a disposable socket and private preference domain. Terminal probes compiled the production bridge, engine, surface and renderer with synthetic AppKit events. No daily-driver service, installed application, or user preferences were changed.

## Evidence boundaries

Superlogical's public videos establish the workflow families below. They do not reveal its behavior for every invalid ID, delayed response, or mouse event. Findings F01-F07 are verified illogical defects in those workflow families. F08-F10 are concrete differences from Ghostty, whose source can be inspected; their exact Superlogical equivalents remain unverified.

The [official site](https://www.superlogical.com/), rechecked on 21 September, describes durable sessions, native scrolling/selection, native macOS/iOS and web access, and live sharing. It still invites users to a future first release. Its broader composability and production-operation plans are not treated as already demonstrated features.

P1 denotes a high-impact correctness failure to fix first. P2 denotes a material workflow or resource defect. These are audit priorities, not security severity ratings.

## Prioritized findings

| ID | Priority | Finding | Direct evidence |
| --- | --- | --- | --- |
| F01 | P1 | Returning to a zoomed tab targets its hidden first pane | Native Find failure; production model sends Close Pane to the hidden block |
| F02 | P1 | Move/swap accepts a window ID where a terminal ID is required and corrupts placement | Real CLI returns success; source process remains alive outside all layouts |
| F03 | P2 | Directory picker can open the previous terminal's directory while loading | Production model emits a new-terminal request with stale cwd |
| F04 | P2 | Two windows overwrite each other's saved remote hosts | Reopened model loses a host added by the other window |
| F05 | P2 | Scoped event streams miss newly created, short-lived children | 15 events unfiltered; zero in both session and window streams |
| F06 | P2 | Deleting a parked terminal leaves its scrollback snapshot on disk | No blocks remain; compressed snapshot remains unchanged |
| F07 | P2 | A friendly session name can shadow another session's exact ID | Actual ID-addressed kill terminates the wrong disposable session |
| F08 | P2 | Alternate-screen wheel-to-arrow behavior is missing | DECSET 1007 wheel events produce zero input bytes |
| F09 | P2 | Horizontal wheel events and small discrete detents are dropped | Native callback emits no report; vertical control succeeds |
| F10 | P2 | Plain printed URLs cannot be Command-clicked | Plain URL lookup fails; identical OSC 8 link succeeds |

### F01: zoomed tabs lose the visible pane's focus

Split a tab into left and right panes, zoom the right pane, switch to another tab, then return. The model sets `focusedBlock` to the layout's first block even though the view displays `deck.zoomed`.

The socket probe recorded `visible=right; focused=left; Close Pane sent block.kill=left`. In the native QA app, Command-F after returning opened no visible search. Shift-Command-Return then displayed the left pane with the search field that had opened there invisibly. No destructive close was sent in the GUI; the separate fixture captured the incorrect kill request. Clicking the visible terminal restores focus, but keyboard/menu actions before that click can affect hidden work.

Cause: [WorkspaceModel.swift](../illogical/Model/WorkspaceModel.swift), lines 277-289, resets focus during session/tab selection; `closeBlock` at line 323 consumes that value. [ContentView.swift](../illogical/ContentView.swift), lines 64-66, displays the zoomed block independently. Fix selection to retain a valid visible block and make command targeting consistent with it.

Reference family: [V03 split decks](https://x.com/almonk/status/2084549282120511575) and [V14, 1:04-1:43](https://x.com/mitchellh/status/2099622049325232505). Exact competitor focus restoration is unpublished.

### F02: invalid move/swap targets corrupt the layout

Create two disposable sessions. Run `illogical move --block SOURCE_BLOCK --target DESTINATION_WINDOW`, deliberately supplying the destination window ID. It returns success but removes the source block from every layout. The service still lists its live PID, and deleting the source session does not clean up that orphan. The corresponding `swap` inserts the destination window ID into a terminal leaf, where no such terminal exists.

Cause: [server.go](../service/internal/mux/server.go), lines 781-807. `findWindow` accepts a window or block ID, while layout insertion/replacement requires an actual block ID. Neither target validation nor insertion success protects the mutation. Validate both resources and placement before changing either layout; an invalid request must leave state and processes unchanged.

Reference family: [V14](https://x.com/mitchellh/status/2099622049325232505), 1:28 block movement and 2:28 distinct resource identifiers. No competitor invalid-input policy is inferred.

### F03: directory creation uses a stale path during loading

Open the directory picker in terminal A at `/fixture/alpha`, close it, switch to terminal B at `/fixture/beta`, and reopen. Before B's listing responds, the previous path and the enabled default action remain. Pressing Enter emits `window.new` against B with `cwd=/fixture/alpha`.

The fixture deliberately withheld the second response, making the failure deterministic. A remote connection or slow filesystem widens this interval. Mixing an old host's path into a new host is also possible from the state design, but was not exercised against a real remote host.

Cause: [WorkspaceModel.swift](../illogical/Model/WorkspaceModel.swift), lines 391-397, retains the old path during a request; [PaletteOverlay.swift](../illogical/PaletteOverlay.swift), lines 31-34, keeps the action available. Bind displayed results and creation to the same captured context and prevent activation of stale results while loading or after failure.

Reference: [V12, 4:53 onward](https://x.com/mitchellh/status/2097424868203758046), host-side directory navigation and terminal creation.

### F04: saved remote hosts are lost across windows

Open windows A and B. Add Build server in A, then Production server in B. A retains its local Build list; B retains its local Production list. A new model loads only Production: the Build route has disappeared from saved configuration. A stale window can similarly reintroduce a host removed in another window. This does not delete the remote process.

The probe used production `addHost` methods and a private preference domain. Its executable had no bundled remote helper, so no SSH connection ran.

Cause: each window owns a model, reads preferences once, then [WorkspaceModel.swift](../illogical/Model/WorkspaceModel.swift), line 426, overwrites the whole host list from its local copy. A shared, observable host store must reconcile mutations across windows. Appearance preference synchronization needs an explicit shared-versus-per-window policy too, but is not counted as a separate reproduced configuration-loss bug.

Reference family: [V12 remote navigation](https://x.com/mitchellh/status/2097424868203758046) and the [per-window host-context reply](https://x.com/mitchellh/status/2097525970593021973). Their private persistence design is unknown.

### F05: scoped automation loses events while continuously connected

Start unfiltered, session-filtered and window-filtered `illogical events` watchers for an existing terminal. Create five splits running `/bin/sh -c 'printf "\007"; sleep 0.02; exit 19'`. Each child emits a bell, exit and close event. The unfiltered watcher receives all 15; both scoped watchers receive zero. The result repeated in two runs.

Cause: [wait.go](../service/cmd/illogical/wait.go), lines 34-49, uses cached workspace membership to filter events. [server.go](../service/internal/mux/server.go), lines 365-377, coalesces state updates over 100 ms. A child can disappear before any state update includes it. This is separate from the documented lack of durable event replay: the watchers never disconnected. Include trustworthy routing context with events or filter against live membership when emitted.

Reference family: [V14](https://x.com/mitchellh/status/2099622049325232505), 4:25 event streams and 5:19 child exit. Exact competitor filter syntax is not established.

### F06: deleted terminals retain parked snapshots

Print a marker into a private terminal, park it, then kill its session. The state has zero blocks, but `snapshots/BLOCK.gz` remains at the same 662 bytes. Repeated terminal lifetimes can accumulate old scrollback files without a cleanup bound. Forced parking shortened the probe; automatic parking uses the same file path.

Cause: [server.go](../service/internal/mux/server.go), lines 528-531, removes the block without deleting the snapshot. [block.go](../service/internal/mux/block.go), lines 466 and 481-498, writes and closes without unlinking it. Permanent deletion needs cleanup distinct from service shutdown, where restoration state may be intentional. This is a disk-lifetime defect; the audit did not measure a specific large disk leak or claim a competitor deletion policy.

Reference family: [V11, 3:55-5:03](https://x.com/mitchellh/status/2095232081853039041), inexpensive parked terminals.

### F07: names take precedence over someone else's exact session ID

Create sessions A then B. Rename A to B's ID. Inspecting B by that ID returns A; `illogical kill --session B_ID` actually kills A and leaves B running. The destructive operation was tested only on disposable sessions.

Cause: [server.go](../service/internal/mux/server.go), lines 497-501, combines ID/name matching in array order. Resolve exact IDs across the full collection before falling back to names. This is distinct from the ambiguity of duplicate friendly names, and can affect native actions that send IDs as well as CLI commands.

Reference family: [V14](https://x.com/mitchellh/status/2099622049325232505), 2:28 inspection and 6:35 deletion. No exact competitor name-collision policy is asserted.

### F08: alternate-screen wheel input does not reach applications

Enter the alternate screen with `ESC[?1049h`, enable alternate scrolling with `ESC[?1007h`, and leave mouse reporting disabled. A vertical wheel event sends zero bytes. Enabling application cursor mode with `ESC[?1h` also sends zero bytes. The alternate screen has no normal scrollback to move instead.

Cause: [TerminalSurface.swift](../illogical/Terminal/TerminalSurface.swift), lines 437-444, only chooses mouse reporting or local scrollback. Add the alternate-screen conversion, respecting the current cursor mode and wheel direction. [Pinned Ghostty](https://github.com/ghostty-org/ghostty/blob/27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c/src/Surface.zig#L3593-L3624) implements this branch. Exact Superlogical behavior is unverified.

### F09: horizontal and small discrete wheel events disappear

With SGR mouse reporting enabled, an event with x=1 and y=0 sends no input; a vertical event on the same surface produces a valid SGR report. A non-precise vertical delta of approximately 0.1 also produces nothing until enough events accumulate. These production-callback tests expose gaps that lower-level wheel encoder tests bypass.

Cause: [TerminalSurface.swift](../illogical/Terminal/TerminalSurface.swift), lines 439-440, reads only y and truncates its accumulator without discrete-wheel normalization. [Ghostty's macOS handling](https://github.com/ghostty-org/ghostty/blob/27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c/src/Surface.zig#L3503-L3653) normalizes slow discrete detents and dispatches both axes. Physical mouse acceptance and exact Superlogical behavior remain unverified.

### F10: plain URLs are not actionable

Print `https://example.com` as ordinary text. The production lookup used by Command-click returns nil. The same visible URL wrapped in OSC 8 metadata resolves correctly. Ordinary server startup messages and log links therefore cannot be opened unless the emitting program supplies hyperlink metadata.

Cause: [Bridge.c](../illogical/Terminal/Bridge.c), lines 518-523, only queries hyperlink metadata; there is no text-matching fallback. Ghostty supports [plain URL matching by default](https://ghostty.org/docs/config/reference#link-url), separately from OSC 8. Superlogical's public `url_clicked` event alone does not establish its plain-text matching rules. No browser URL was opened during this probe.

## Previously uncertain behavior now reproduced

**Selection autoscroll is missing (P2).** With 101 retained rows, a 30-row viewport at history offset 20, dragging below the pane and holding for 400 ms leaves the viewport at 20. The copied selection ends in the visible rows. The prior audit called this unverified; it is now a demonstrated gap. [TerminalSurface.swift](../illogical/Terminal/TerminalSurface.swift), lines 425-428, forwards drag events, while [Bridge.c](../illogical/Terminal/Bridge.c), lines 424-444, never dispatches autoscroll ticks. A gesture-scoped timer should start only when needed and stop on release, re-entry, hiding or teardown. [Ghostty's timer](https://github.com/ghostty-org/ghostty/blob/27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c/src/Surface.zig#L1186-L1229) provides a reference. The public native-selection promise does not specify Superlogical's exact timer behavior.

**Unusual Unicode limit (P3).** A base `a` plus 62 combining acute accents yields a 125-byte rendered grapheme. With 64 accents, the underlying 129-byte grapheme remains copyable but produces zero rendered-frame bytes. [Bridge.c](../illogical/Terminal/Bridge.c), lines 366-367, ignores an out-of-space result for its fixed 127-byte payload. This is separate from ordinary text fuzziness. Handle oversized clusters deliberately, preserving visible base content at minimum. Neither competitor's raster output for this cluster was tested.

## Comparison work still outstanding

These are retained limitations, not additional discoveries counted above:

- Exact visual fidelity remains unproven. Forty-one theme names still use only two shared ANSI palettes; process icons, materials and source metrics remain approximations.
- Physical three-finger peek, pane movement by drag, and the full two-host/multiwindow workflow still need native acceptance. One attempted pane drag in this pass left the layout unchanged, which does not isolate an application defect. Computer Use subsequently rejected new-tab actions because the app interaction state changed; no tab-overflow result is claimed.
- Web/iOS clients and the complete invitation/per-session-sharing workflow are absent. The site's wider production platform is a plan, not a present parity checklist.
- A matched Ghostty performance baseline and real external-display acceptance remain outstanding. This audit makes no new FPS, startup or battery claim.

## Reproduction records

Local, ignored `.build/audit-followup` artifacts retain the detailed probes: `probe-service.py`, `service-probe-results.json`, all three event streams, `workspace-probe/Audit.swift` and `results.txt`, `TerminalOutlierProbe.swift`, and `terminal-outlier-results.txt`. They are temporary investigation aids, not a maintained test suite or required files in a fresh clone. The reproductions, measured outcomes and source locations above preserve the findings independently of those files.

The private service and its children were stopped after the service probes. The native QA check used the pre-existing isolated Final QA application and added one empty tab; its default user service was never involved. Concurrent release-automation edits are unrelated to this audit.

Fix F01/F02 first, then shared host state, stale directory context and scoped event delivery. Add regressions at the failing boundary: visible-pane command targeting, atomic invalid moves, two live models, delayed directory responses, continuously connected scoped watchers, native wheel callbacks and snapshot deletion. Passing lower-level encoders or happy-path CRUD tests does not cover these failures.
