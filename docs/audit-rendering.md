# Rendering, appearance, search, and performance parity audit

Audit date: 20 September 2026. Scope: T01, T02, T05, A01–A10, and the rendering behavior behind N07–N09. The initial audit was read-only; its original findings and probes are preserved below. Subsequent authorized repairs are recorded in the remediation section and supersede the corresponding initial defects. This is not a claim that every feature shown by Superlogical has been reproduced. The consolidated status lives in [feature parity](feature-parity.md).

The comparison target is the evidence in [the feature inventory](../research/superlogical/FEATURES.md), [transcript notes](../research/superlogical/TRANSCRIPT_NOTES.md), and [visual references](../research/superlogical/VISUAL_REFERENCE.md). The inventory distinguishes observed video behavior from the developer's statements. Compressed preview videos cannot establish exact palettes, typography, internal algorithms, or complete terminal compatibility.

**Verified** means the stated, bounded behavior has supporting code and a direct check, or an unambiguous implementation path. **Partial** means the main behavior exists but has a reproduced defect, a known limitation, or an important unverified part. **Missing** means no implementation was found. **Unverified** means available evidence cannot establish the comparison. A verified item does not imply pixel-for-pixel parity.

## Feature results

| ID | Status | Evidence and remaining gap |
| --- | --- | --- |
| T01 | Partial | A real first terminal presentation is measured, and foreground launches are usable. Existing final samples range from 471.355 to 848.871 ms for a warm service, with a 493.660 ms median. Service-start samples are 659.409, 476.508, and 711.217 ms. These do not establish consistent half-bounce startup. Superlogical's V09 claim is qualitative; no matched measurement or reference hardware is published in the corpus. |
| T02 | Partial | The pinned Ghostty terminal library handles terminal state; the custom Metal/CoreText renderer passes the font, geometry, synchronized-output, dirty-row, and five-underline-style checks described below. Extended key mappings, focus events, and mouse protocols have maintained tests. Sustained real DOOM Fire runs and native interruption were recorded by the parent. Static image rendering and reconnect restoration now have maintained tests; full Ghostty renderer parity is still absent for animated/Unicode-placeholder images, unbounded/paragraph contextual layout, and some symbol rules. No exhaustive editor/TUI compatibility matrix has been run. |
| T05 | Partial | Two independent bridge terminals receiving identical output retained independent scroll position and selection. App windows each own a `WorkspaceModel`, which owns its terminal replicas; scrolling and selection send no service request. Native scroller, wheel input, selection gestures, copy, and Shift override of application mouse reporting exist. This audit did not operate two visible native clients or verify drag autoscroll, selection accessibility, or exact scroll feel. A preview deliberately shares its own window's engine and viewport. |
| A01 | Verified, bounded | Light and dark themes change terminal default colors, ANSI colors, cursor color, SwiftUI foreground/tint, and surrounding chrome. The dirty-row test verifies changed theme/default and OSC palette colors reach frame cells. There are 15 light and 26 dark entries. Imported light/dark pairs now follow macOS appearance, with actual `NSApplication.appearance` switching and manual override covered by the parent's isolated tests. Exact source colors are unverified. |
| A02 | Partial | There are exactly 41 unique built-in names. The implementation contains only **two distinct ANSI palettes**, shared across all dark or light entries; backgrounds and accents are reconstructed. Having 41 names does not reproduce Superlogical's 41 original theme definitions. Authoritative full palettes are unavailable in the researched sources. |
| A03 | Partial | All four labels exist and select distinct background implementations: Modern uses material, System uses the native window background, Themed uses theme chrome, and Blended combines material with theme chrome. Settings persist the choice. Exact materials, chrome treatment, and appearance across macOS versions have not been matched to V13. |
| A04 | Verified, bounded | Comfortable uses a 9-point outer inset, 8-point split gaps, and rounded panes. Compact removes the outer inset, uses 1-point split gaps and square panes, and supplies fine separator lines. The geometry changes rather than only changing text size. This verifies the structural distinction in V13; exact reference spacing and a complete native visual matrix remain unverified. |
| A05 | Partial | Search is a floating overlay and does not participate in terminal layout. A real READY snapshot plus 12 delayed history pages restored 5,001 rows, and an active search grew from one match to three, including the oldest row. Remediation now preserves the query across reconnects and publishes exact per-row selected-match spans for layout. The original overlay collision requires separate UI integration verification. Search remains synchronous; worst-case latency at the 64 MiB history limit has not been measured. |
| A06 | Verified, bounded | Match count, next/previous navigation, wrapping, close, and both highlight states pass the maintained search tests. Remediation covers 1,320 dense matches, clipped wrapped matches, immediate counter clearing, and query restoration. The pinned library can clear the selected match on grid resize; the query remains active and selecting again restores the current highlight. This is not exhaustive search conformance. |
| A07 | Verified, bounded | OKLab correction now chooses a reachable black/white endpoint and validates final 8-bit RGB values. All reproduced failures, 256 gray backgrounds with three theme targets, and 20,000 deterministic RGB pairs meet the internal 4.5 target; already readable colors remain unchanged. Exact Superlogical algorithm and threshold are unpublished, so visual parity remains unverified. |
| A08 | Partial | The importer reads common Ghostty config locations, includes, named/absolute themes, and a light/dark pair; a preview sheet can apply and persist the imported themes. Remediation imports all 256 palette entries, generated palettes, selection/cursor text colors, minimum contrast and opacity. Discovery merges the current and legacy XDG/macOS files and deferred includes. See the maintained import checks below; uncommon compound-value escaping, theme background images, remain gaps; automatic system appearance pairing is now implemented and separately tested by the parent. No fresh end-to-end import was performed because this audit does not change user configuration. |
| A09 | Missing | Copy currently writes directly to the pasteboard without setting visual feedback state. No copy-success overlay, animation, or renderer feedback was found. The newly found [developer video](https://x.com/almonk/status/2101298258706362515) states this feature; exact appearance and timing have not yet been fully visually inspected. |
| A10 | Missing | There is no copy-on-selection preference, and selection release does not copy. The [developer reply](https://x.com/almonk/status/2101342381635235882) confirms that option in Superlogical, in response to [the explicit question](https://x.com/hamedhsn/status/2101312512171921696). Defaults and edge-case semantics remain unknown. |
| N07 | Partial | The three-finger gesture and tab strip are wired; cards contain the actual split tree and live `TerminalSurface` instances. Each surface observes the shared client terminal and redraws on output. The parent subsequently verified visible overview previews and selection. Full gesture behavior, simultaneous changing terminal content, and preview load across many tabs remain unmeasured. |
| N08 | Partial | The expanded overview groups live cards by session and host, and clicking selects the destination. Preview surfaces do not accept terminal input or resize the PTY. The parent subsequently verified visible overview previews and clicking a destination. Exact visual parity, animation, and many simultaneously active terminals remain unverified. |
| N09 | Verified, bounded | `workspaceArea` gives the terminal workspace a fixed frame and changes only its vertical offset during peek. Preview layout is noninteractive and skips `engine.requestResize`; the renderer scales the existing frame to fit its card. This implements the advertised move-without-resize behavior. No new native resize-event trace was collected in this audit. |

## Maintained remediation checks

Run `scripts/test-search-contrast.sh` from the repository. The script uses isolated in-memory terminals and generates its own READY snapshot; it does not contact a daemon or modify a running session.

- Viewport match storage grows to the count returned by Ghostty and is read only after a successful query. Closing search releases the storage. The 1,320-match fixture now produces 1,320 ordinary highlights and one active highlight, including on a second cached draw.
- Search intervals are intersected with the viewport in full-screen coordinates. Tests cover an endpoint above the viewport, an endpoint below it, and a match spanning beyond both edges. The original visible `uvw` case now has three ordinary and three selected highlight cells.
- `TerminalEngine` immediately publishes zero counts and empty geometry on clear, reapplies a live query before notifying observers of a restored snapshot, and publishes inclusive row/column spans from selected cells. Tests cover listener remounts, no-match queries, independent engines, and clipped/wrapped geometry.
- Service theme updates accept partial/default RGB and an empty or 256-color palette, persist across reconnects, preserve application OSC overrides, and never echo a theme request. An explicit local theme supersedes them. Tests verify palette entry 200, omitted cursor following foreground, resets, invalid payload rejection, and OSC 4/10/11/12 preservation. The rendering replica supplies black/white when defaults are cleared because Ghostty's render cache otherwise retains stale colors if either foreground/background becomes unset.
- The four original contrast failures now produce `#171717` (4.539338), `#323232` (4.500179), `#767676` (4.542225), and `#7c7c7c` (4.523954), respectively. The sweep checks the actual quantized output, not an intermediate floating-point color.

The C search suite also passed AddressSanitizer. The synchronized-output/dirty-row suite passed after these changes. These checks establish the repaired behaviors; native floating-search placement and exact reference appearance require their own UI verification.

Additional maintained protocol and decoration checks:

- `scripts/test-terminal-protocols.sh` checks macOS F13–F20, international punctuation, keypad, insert/menu, and volume-key identities against the pinned Ghostty table, then compares legacy and Kitty encoding with the direct library encoder. The library does not expose Lang1/Lang2 key identities; macOS input-method composition still uses AppKit.
- The same suite covers DECSET 1004 focus reporting, left/right/middle/extra buttons, both wheel axes, modifiers, drag-only/all-motion tracking, cell-motion suppression, and pixel motion within a cell. Engine checks ensure focus transitions are deduplicated and that focus/mouse reports neither jump scrollback nor notify render observers. Suppressed events remain owned by the terminal program instead of falling through to text selection. Native callback wiring is verified separately by the parent.
- `scripts/test-render-state.sh` now verifies SGR single, double, curly, dotted, and dashed underlines; explicit RGB/palette underline colors and resets; truecolor, inverse, strike, overline, and invisible decorations. The renderer preserves underline metadata and scales its patterns in live previews.
- `scripts/test-rendering.sh` compiles the production Metal shader and tests offscreen pixels for curly, dotted, and dashed lines, including pattern continuity across adjacent cells. The updated image was inspected. This proves those render paths, not pixel-for-pixel agreement with an unpublished Superlogical implementation.

## Initial defect reproductions

### Dense search highlights are dropped

In `Bridge.c:241`, `GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES` receives a fixed buffer of 256 selections, and its return value is ignored. The pinned library returns `GHOSTTY_OUT_OF_SPACE`, sets the required length, and does **not** populate the buffer when capacity is insufficient. The bridge then reads up to 256 uninitialized selections.

An isolated 120-column by 12-row terminal containing 1,320 occurrences of `a` produced:

```text
dense matches=1320 selected=1 regularHighlightCells=0 selectedHighlightCells=1
```

The count is correct; almost all visible matches are unhighlighted. The ordinary highlight path must allocate/query sufficient capacity and handle errors before reading selections. This is a correctness and uninitialized-memory issue, not merely a 256-result display preference.

### Wrapped matches lose the visible portion when scrolled partially out of view

`mark_match` requires both ends to convert to viewport coordinates, so it discards a whole match if either endpoint is outside the viewport. A 23-character match wrapping across a 20-column terminal, scrolled so only `uvw` remains visible, produced:

```text
clipped match count=1 offset=1 ordinaryHighlightCells=0 selectedHighlightCells=0 visibleText=uvw
```

The visible intersection should remain highlighted.

### Clearing and reconnecting do not preserve accurate search state

`TerminalEngine.frame()` only invokes `onSearch` when `lastSearch` is nonempty. Searching for two matches and then clearing the query yielded `callbacks=[2]`, with no zero-count update. The model therefore retains the prior counter until another action resets it.

On a snapshot, `TerminalEngine.receive` replaces the terminal handle but never reapplies `lastSearch`. In a second probe, the query remained active in Swift and the incoming READY snapshot contained a matching marker, but the restored frame reported zero matches. Reissuing search manually is required to restore highlighting. These are separate problems from the successful delayed-history search check.

### Search positioning does not reliably avoid the active match

`TerminalPane` positions the bar at y=92 for selected start rows 0–2, and y=32 otherwise. It does not inspect the match's horizontal extent, pane title visibility, actual font cell height, or the bar rectangle. At the supported 24-point SF Mono size, the measured cell height is 32 points: with a pane title, row 2 occupies y=102–134 while the relocated 38-point search bar occupies y=92–130. A match under the trailing bar remains covered. At 9 points with pane titles hidden, row 3 occupies y=50–64 while the bar is at y=32–70. These are geometry calculations from the actual font metrics and current layout, not native screenshot observations.

### Contrast correction can leave unreadable text unchanged

`ContrastCorrection.correct` chooses the white direction whenever background luminance is at most 0.4. White cannot reach 4.5 against many such backgrounds. Its binary search then never finds a valid candidate and returns the original foreground. It also checks contrast before, rather than after, converting to 8-bit RGB.

Actual results from the production function:

| Foreground | Background | Result | Resulting contrast |
| --- | --- | --- | --- |
| `#888888` | `#808080` | unchanged `#888888` | 1.114:1 |
| `#444444` | `#999999` | unchanged `#444444` | 3.419:1 |
| `#eeeeee` | `#ffffff` | `#777777` | 4.478:1 |
| `#222222` | `#111111` | `#7c7c7c` | 4.524:1, passes |

A sweep of all 256 gray values with foreground equal to background returned 110 results below 4.49 and another 48 in [4.49, 4.5). This is not an assessment of Superlogical's algorithm; it is a reproducible failure of illogical's stated internal target. Graphics characters intentionally bypass text contrast correction, which preserves their image colors.

## Other rendering and appearance limitations

- Static Kitty RGB/RGBA/PNG images now use an authoritative service scene with Metal compositing, clipping and bounded texture caching. This side channel restores image placements on reconnect despite Ghostty snapshots omitting the image registry. Animated images, Unicode virtual placements, and relatives anchored to virtual placements remain unsupported. See [graphics compatibility](graphics-compatibility.md). The corpus does not independently prove every graphics protocol is a Superlogical feature.
- Remediation preserves all five underline styles and explicit colors, and conceals decorations with invisible text. SGR text blink now uses a demand-driven 600 ms timer; it stops without visible blinking text, on hide/occlusion, and on detach. This was requested as additional functionality; pinned Ghostty renderer parity for text blink was not independently established. Bold, italic, inverse, faint, invisible, strikeout, and overline have paths; representative SGR checks pass, but no exhaustive visual comparison has been performed.
- Grapheme clusters and adjacent code operators are shaped. Contextual Arabic/Indic runs now shape across cells and 64-cell atlas tiles using bounded word context; Arabic, Devanagari and Bengali actual-raster tests pass. Paragraph BiDi and context beyond 1,024 UTF-16 units are not claimed. Ghostty's complete Nerd Font constraint table, all legacy-computing sprites, and its Display-P3 color emoji atlas are not reproduced. The selected font, scale, and theme need a matched comparison before claiming identical rendering. See [rendering details](rendering.md).
- Ghostty theme import now preserves selection/cursor colors (including cell-relative colors), opacity and explicit-cell opacity, minimum contrast, and all 256 palette entries. It uses the pinned library’s named/hex/rgb/rgbi color parser and palette generator. XDG discovery and all four default config files are supported; includes load after defaults in breadth-first order. A complete Ghostty configuration grammar and background images remain absent; automatic light/dark pairing is implemented and separately tested by the parent. Invalid recognized theme values fail import instead of partially applying a theme; Ghostty itself accumulates diagnostics and continues. Exact Superlogical import coverage is unknown. A [fresh developer clarification](https://x.com/almonk/status/2101356033000050922) narrows the advertised target to theme and theme-related settings, so importing every unrelated Ghostty preference is not a parity requirement.
- Imported light/dark pairs now follow macOS appearance automatically; manual selection disables following. The parent verified actual `NSApplication.appearance` observation in an isolated application process, including manual override.
- Preview surfaces share live terminal state and preserve split geometry. The visibility gate checks hidden ancestry and whole-window occlusion, not intersection with a clipping/scroll rectangle. Rendering cost for partially or completely clipped surfaces within an otherwise visible window has not been profiled. A large live overview is not covered by the single-pane DOOM measurement.

## Fresh checks performed in this audit

All temporary probes and output are under `.build/audit-rendering/`; none call the service or change the user's terminal. They compile the actual production sources and pinned static library. These local artifacts are ignored by Git; the documented cases should become maintained regression tests when their fixes are implemented.

| Check | Result |
| --- | --- |
| `search-probe`, 301 retained rows with markers at oldest/middle/newest; next and wrap; clearing; two independent replicas | Passed. Three matches, selected indices 1,2,3,1; independent viewport offsets 0 and 289; copy length 5,711 versus 0. |
| `history-probe`, real 64 MiB-configured terminal snapshot and incremental restore | Passed. READY had 249 resident rows and one match; 12 delayed pages produced 5,001 rows and three matches; navigation reached offset zero. Catch-up CPU time was 2.254 ms for this small fixture, not a full-limit search benchmark. |
| `search-probe dense` | Failed ordinary highlighting for 1,320 visible matches, as above. |
| `search-probe clipped` | Failed highlighting of a partially visible wrapped match, as above. |
| `engine-probe` compiled with `TerminalEngine`, `Theme`, and `Protocol` | Confirmed 41 unique names, 15 light/26 dark, only two unique ANSI palettes; reproduced stale clearing count and query loss on reconnect. |
| `contrast-probe` compiled with production `ContrastCorrection.swift` | Reproduced the four cases and 256-gray sweep above. |
| Existing `terminal_rendering_test.swift`, changing only artifact paths to the isolated directory | Passed actual Metal half-block pixel checks, Nerd BMP/supplementary coverage and bundled fallback, combining marks, CJK, color emoji, font smoothing, variable weight, and operator ligatures. The produced PNG was inspected. This is a representative fixture, not a full rendering conformance suite. |
| Existing `TerminalPresentationTests.swift` | Passed burst coalescing, idle grace, final-frame retention, one pending drawable, three exclusive GPU buffers, retry after failed acquisition, and cancellation. |
| Existing `terminal_render_state_test.c` | Passed synchronized frames, consecutive holds, timeout, restored hold, resize/reset, palette invalidation, selection clearing, and dirty rows. |

The first history probe used a bare `il_terminal_new` and incorrectly expected 2,000 rows to survive the library's default smaller history allocation. It retained 417 rows and one marker; that assertion was a fixture error, not an application search failure. The replacement snapshot probe uses the same 64 MiB setting as the real service and verifies all 5,001 retained rows. This distinction prevents a false failure report about application scrollback retention.

## Existing performance evidence reviewed, not rerun

[Performance validation](performance.md) and the local final JSON records were checked. The existing service/GUI measurements are separate from the isolated audit tests above.

- The final direct-socket DOOM Fire sample lasted 60.23 seconds at 134×35, SF Mono 13 pt, and ended at 442.87 cumulative producer FPS, with the same viewer owner and no queue overflow. The helper relay sample ended at 401.24 and the fresh-service direct-handoff sample at 428.63. These are producer write rates, not display refresh rates.
- The approximately 500 FPS Ghostty figure is the user's earlier observation. A fresh run with identical grid, font, display scale, and conditions was blocked by application access policy; a matched advantage or parity claim is **unverified**.
- Startup timings came from real drawable presentation after a terminal snapshot, measured from process creation. The sample set contains the slower warm 848.871 ms result. Background/occluded starts, the former blank-until-input regression, and invalid early instrumentation records are excluded for stated reasons. No consistent sub-400 ms or half-bounce guarantee is supported.
- Current scheduling coalesces output at native display cadence, preserves all terminal bytes, obtains drawables away from the main thread, and retains a final dirty frame. The fresh scheduling tests verify those state transitions. Native warm/cold visibility checks and sustained output behavior were performed by the parent and are documented in the existing performance record.

The application has substantial functional coverage, but this audit cannot support “all the same features,” a 1:1 UI, full Ghostty rendering parity, or consistent half-bounce performance. The concrete defects and missing copy features above should be resolved before upgrading those claims.

## Additional theme and blink remediation checks

- `scripts/test-theme-import.sh` passes against isolated temporary configs: four-file precedence, includes after defaults, breadth-first recursion, optional/missing/duplicate includes and clearing, ignored recursive theme directives, X11/hex/rgb/rgbi colors, palette indices 16–255 (binary/octal/hex), generation preserving explicit entries, light/dark pair validation, absolute and home-relative theme paths, selection/cursor colors, opacity/contrast clamping, full wire palettes, and backward-compatible saved themes. No user config was changed.
- Imported configs start from pinned Ghostty defaults (background `282c34`, foreground white, its native 256 palette, contrast 1 and opacity 1); existing illogical themes retain their original 4.5 contrast behavior. Imported minimum contrast is honored when correction is enabled; a mathematically unattainable ratio returns the more contrasting black/white endpoint.
- `scripts/test-resource-render.sh` passes actual GPU pixel assertions: the clear color is premultiplied, explicit translucent backgrounds replace instead of stacking alpha, selection/inverse and foreground colors remain opaque. The second background pipeline is created only when translucent cell backgrounds need it; ordinary opaque rendering retains its single draw submission. Native window transparency is integrated and accepted separately by the parent.
- The same renderer harness verifies real blink timers are absent without blinking text, reused across frames, stopped on a hidden timer callback, stopped after removal of the last blinking cell, and invalidated on detach. `scripts/test-rendering.sh` covers actual on/off raster pixels plus pure state transitions. `scripts/test-render-state.sh` passes SGR blink enable/disable and explicit/inverse background metadata in the C bridge.
- Imported light/dark entries now form an automatic system-following pair, implemented and tested separately by the parent. Remaining import gaps include background-image/layout/blur settings and uncommon quoted/escaped names inside compound light/dark values. These do not justify a claim of complete Ghostty configuration import.

## Static image and synchronized typing remediation

- `scripts/test-graphics.sh` passes atomic image deltas, RGB/RGBA/gray data validation, source rectangle and scene limits, deletion release, real terminal snapshot restoration, full graphics baselines, resumed sequence replay, duplicate/stale-stream rejection and missing-sequence resync.
- `scripts/test-resource-render.sh` passes actual Metal pixel uploads for RGB/RGBA/gray, same-size generation replacement, cache reuse/delete/LRU limits, premultiplied image output, UV cropping above the viewport, independent scroll positioning, and unchanged anchors when snapshot history is prepended.
- `scripts/test-terminal-protocols.sh` now also checks that a physical key or paste from scrollback publishes one synchronized return to the live bottom. Further keys at the bottom are deduplicated; focus/mouse protocol reports do not scroll or publish viewport changes. The C bridge exposes a lightweight scrollbar query so this does not extract full text frames on every input event.
- Static graphics are bounded to 8 MiB decoded pixels per service screen, 1,024 exported placements, and a shared 64 MiB native texture cache. In-flight Metal commands retain textures until completion. Replica image parsing/storage stays disabled; service state owns pixels and protocol responses. Ordinary opaque text rendering retains its single instanced draw path. The service and native decoder use bounded APC/continuation sizes; a maintained dependency patch reduces Ghostty's otherwise much larger temporary image/inflate bound.

## Final graphics and contextual-shaping checks

- `scripts/test-text-runs.sh` passes Arabic joining, Devanagari/Bengali conjunct shaping, wide-cell/style/search/cursor boundaries and byte-for-byte equality between a complete 200-cell raster and source-over composited 64-cell atlas tiles. The 20,000-candidate ASCII/block fast path creates no shaping runs (about 0.12 ms in the isolated test).
- `scripts/test-graphics.sh` now retains search count, local viewport and exact selected text through a corrective snapshot with 2,000 history rows; no synchronized-viewport echo is emitted. An intentional user scroll during restoration cancels the previous viewport request. These corrections are necessary because disabled replica image parsing does not reproduce placement cursor movement/scrolling.
- The full production render path now has an offscreen four-pane regression with an image, contextual text, explicit backgrounds and 40 opaque/translucent light/dark transitions. Whole-module optimized execution passes. A native theme-import crash was traced to the lazy pipeline construction/error-cleanup path; pipeline resolution now precedes encoder creation and the factory contains its error handling. Native crash acceptance is pending and must not be inferred from the offscreen pass.
- The service explicitly rejects unsupported image animation, bounds canonical image IDs to 1,024 per screen, and preserves a separate canonical scene. Corrective placement snapshots cost additional encoding/transfer/restoration work; no image-heavy performance equivalence is claimed.
