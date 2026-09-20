# Native navigation parity audit

Audit date: 20 September 2026. Tested the isolated `dev.illogical.qa` app and
`.build/qa-state/daemon.sock`, never the user's default service. The initial table records the original QA build. Later implementation and native
acceptance sections supersede its missing-feature findings; it is retained as
a record of what was reproduced before the fixes.

Status describes the recorded behavior, not pixel-perfect equivalence. **Verified**
means the stated core acceptance case worked; **partial** means a known subset;
**missing** means the defining feature is absent; **unverified** means further
acceptance is needed. Research IDs refer to [the inventory](../research/superlogical/FEATURES.md).

| ID | Status | Evidence and limits |
| --- | --- | --- |
| T04 | Verified local case | Quit the QA GUI with two sessions and three tabs in the selected session, confirmed all six shell PIDs survived, then reopened it. The titlebar restored `Parity verified` and the selected `~/Developer` tab with its prior contents. `WorkspaceModel.init`, `saveSelection`, and `receive` persist and restore host/session/deck. Selection preferences are global; per-window and remote restoration still need acceptance. |
| N01 | Verified core behavior | Used native Cmd-K, typed `Parity audit`, pressed Return and confirmed a new session in service state. Used the command palette's Rename Session action to rename it `Parity verified`. The sidebar and overview reflected the new name. Filtering `Parity` hid the unrelated local session in the sidebar. Source: `PaletteOverlay.items`, `WorkspaceModel.newSession/finishRename`, `WorkspaceSidebar`. |
| N02 | Verified core behavior | Native Cmd-K opened the session picker with keyboard focus. A blank initial QA session was automatically named `quiet-cedar`. The service generates names from a short list of two-word names. Its exact naming algorithm and duplicate-name behavior need not match an undisclosed reference algorithm. |
| N03 | Verified core behavior | Cmd-T added a second tab to `Parity verified`; the horizontal bar showed only that session's tabs. The local sidebar also retained `quiet-cedar` separately. `WorkspaceTitlebar` iterates only `activeSession.windows`. Later directory creation added a third tab to the same session. Tab reordering is not implemented; the reviewed reference does not establish its precise rules. |
| N04 | Partial | Control-Command-V switched to a sidebar showing both local sessions and their tabs. Filtering worked. `WorkspaceSidebar` groups host profiles then sessions. Cross-machine grouping exists in code but has no real remote-host acceptance result. |
| N05 | Partial | Cmd-D created a horizontal split; Shift-Cmd-D split its right pane vertically. The overview showed the complete three-pane layout. The isolated service test `TestProcessesSurviveClientDisconnectAndLayouts` passes PID preservation across a block move. Native drag targets and split-resize edge cases were not fully exercised; the drop-axis heuristic is a fixed y > 120 threshold. |
| N06 | Missing | `DeckIcon` always draws a generic terminal glyph and an extra stacked tile when there are multiple blocks. It never reads process metadata. `BlockInfo.icon` has a title-based heuristic for pane headers, but that does not satisfy process-aware deck/tab icons. |
| N07 | Partial | Shift-Command-Space exposed a strip of rendered tab previews, including the three-pane tab. `TerminalSurface.touchesMoved` implements continuous three-finger downward progress. A physical trackpad gesture and continuously changing preview content were not verified in this pass. |
| N08 | Partial | Shift-Command-O showed an overview with both sessions, each tab and nested split previews. Clicking the three-pane card selected that tab and dismissed the overview. Continued three-finger gesture thresholds/cancellation and remote groups remain unverified. |
| N09 | Verified keyboard case | `workspaceArea` offsets a fixed-size workspace, and preview surfaces are noninteractive. This is the intended no-reflow implementation. The native keyboard peek kept every block's grid and PID unchanged in before/during/after service snapshots. The active tab remained 134 by 35. A live foreground Python probe installed a SIGWINCH handler; keyboard peek, expanded overview, and dismissal produced zero resize signals during its 35-second lifetime, then native Ctrl+C stopped it. Physical three-finger input remains unverified. Trace: `.build/parity-audit/peek-sigwinch.txt`. Additional evidence: `.build/parity-audit/ui-before-peek.json`, `ui-during-peek.json`, and `ui-after-detach.json`. |
| N10 | Verified core behavior | Opened Shift-Command-P, filtered Rename Session, activated it, and completed the rename. Code also exposes creation, splits, zoom, orientation, density, themes, appearance, remote setup and directory actions. There is no public complete command/ranking specification, so this verifies the demonstrated categories rather than every possible command. |
| N11 | Partial | Shift-Command-G listed the current terminal's home directory. Filtering Developer, activating it, then Open terminal here created a tab with a `~/Developer` shell prompt. Requests use the selected connection. Remote-host acceptance remains outstanding, and the service audit reproduces incorrect relative `list_dir` resolution. |

The desktop locked during the first video/native check; inspection resumed after
access returned. No locked-state screenshot or failed action is counted as a pass.
The screenshots show the intended basic composition, but neither this audit nor
the existing compressed reference frames establish a 1:1 pixel match. Physical
three-finger gestures, accessibility completeness, animations under reduced
motion, and cross-host workflows still require dedicated acceptance.

## Native implementation follow-up, 20 September 2026

The isolated `dev.illogical.parityqa` Release bundle uses `.build/parity-state/daemon.sock`. It does not share the default daemon or preferences. Native Computer Use verified these additional flows:

- Split a fresh terminal into two panes. Print `apple apple pear` and `pear pear apple`; open Find in both panes. Both controls remain visible with independent `1/4` counters, correctly including echoed commands and their output. Clear the first query to zero and close the second control; the other control remains.
- Click the second terminal while the first search remains open, run `sleep 30`, and press Control-C. The prompt returns with `^C`; settings retain the new copy-on-selection and synchronized-scrolling options.
- Enable copy-on-selection, double-click `pear`, and observe the service's ordinary watcher receive one `selection_copied` event with text `pear`. The selected word is visible. The transient pulse was not isolated precisely enough to certify V17's timing.
- Detach only the QA app's client, then write `printf 'replay-resume-token\n'` to its existing process during reconnection. The native terminal displays one command and one output line after reconnect. Both shell PIDs remain 11844 and 11909, and the connection gets a new owner ID. The native unit regression separately establishes that accepted replay preserves the same parser and scroll/search state; UI appearance alone cannot distinguish replay from a correct snapshot.
- Send a service `focus` request to the other pane and observe that native terminal become first responder.
- With synchronized scrolling enabled, attach a second disposable client, opt in and send a bottom-relative offset of 30 after `seq 1 100`. The native pane displays lines 39–73 at the same 66x35 grid; the unrelated pane is unchanged. The native engine test verifies no echo loop and safe clamping when local history differs.

Local evidence: `.build/parity-native-state.json`, `.build/parity-native-after-reconnect.json`, `.build/parity-native-copy-event.json`, and `.build/parity-viewport-ready`. These ignored files are not required to run the maintained test scripts.

The native pass also found two integration defects: the default `NSScroller` remained disabled despite visible history, and a process lookup could run between a shell title change and the new foreground job. The scrollbar now explicitly follows available history. Process lookups coalesce for 120 ms after metadata changes without a periodic timer, and fall back to title hints when macOS withholds foreground identity. The `top` probe demonstrated the restricted identity case. The additional integration checks below verify both follow-up fixes in a combined Release build.

### Additional native integration checks

A separate `dev.illogical.integrationqa` Release app and `.build/integration-state` service were used for these checks. The original user service and previous QA sessions remained running. A 134×35 terminal rendered the static four-quadrant Kitty fixture and restored its image after GUI quit/reopen. That first check exposed incorrect live cursor progression after image placement; graphics acceptance remained blocked until the service/client correction was validated separately.

The native scrollbar now exposes an enabled control with scrollback: setting it from 1 to 0.5 changed the visible lines from 69–100 to 29–63. Starting `top -s 2` changed the pane icon from a terminal to a chart; native Control-C stopped it. At approximately 140 points wide, the pane search uses two rows, displays `1/2` and `2/2`, and moves below the selected wrapped match when navigating. A search overlay may cover unselected matches; it avoids the selected match.

The corrected Release build passes the live image-placement reproduction: the prompt appears below the image immediately, without requiring reconnect. Native Ghostty pair migration also passes with background opacity 0.55 and translucent explicit cell backgrounds, both applying the pair live and reopening saved preferences. The test used an isolated XDG configuration directory, leaving the user's Ghostty configuration untouched. An earlier crash is retained in the renderer investigation; the repaired path and Address Sanitizer checks are recorded in the rendering audit.
