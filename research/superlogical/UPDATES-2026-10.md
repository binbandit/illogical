# October update

Evidence paths refer to a local, uncommitted capture folder; see the note at the top of [the visual spec](VISUAL_SPEC.md) for how to fetch the media again.


Collected 1 Oct 2026 from the owner's X account and Mitchell's Mastodon. Files live next to this note.

## 1. Newest window chrome (17 Sep and 30 Sep screenshots)

- `masto/contrast-1.png`, `masto/contrast-2.png` (17 Sep, light theme, 2048x1314): no pane title rows; split panes separated by a 1px hairline with no inset or rounding; four tabs.
- `new/rauchg-2104992830448087483.jpg` (30 Sep, dark theme): tab strip with process badges; selected tab is a full capsule with dark fill and hairline border; session button = laptop icon + bold `ping-vercel` + `This Mac`; no pane title row.
- Tabs: fixed-width items, separated by thin vertical dividers when unselected. Each has a rounded-square badge on the left, then the terminal's OSC title (`~ - fish`, `~: lg - lg`, `✳ Claude ...`). Long titles fade out at the trailing edge instead of using an ellipsis. Only `+` sits at the right end of the titlebar.

## 2. Process-aware app badges (tabs and pane title rows)

The badge follows the foreground program, not just an SF Symbol:
- shell: dark rounded square with `>_`
- nvim: teal/cyan square with a bold `N`
- Claude Code (`claude`, `cc`): orange square with the Claude sunburst; OSC title starts with `✳`
- `fx` (an agent harness the owner noted Alasdair runs inside Superlogical): dark square with italic `fx`
- multi-pane tab: stacked badge
A reply calls out "the custom icons for each application" as a highlight. The badge sits both in the tab and at the left of each pane's title row.

## 3. Pane title rows (26 Sep video)

`new/pathpicker/grid*.jpg`: with pane titles enabled, each pane has a thin top row: process badge/icon, then the OSC title (`~/apps/replay-web - fish`, `~/apps/replay-web: nvim apps/...License.ts - nvim`), and dim controls on the right (split right, split down, zoom/expand, close). Compact density, panes butt together.

## 4. Path picker experiment (out of scope)

The 26 Sep path-insertion picker is an experiment, not a committed feature. The owner decided not to build it. The video is still useful for the pane title rows, badges and chrome.

## 5. Multi-client size ownership (Mitchell, 30 Sep)

https://x.com/mitchellh/status/2105276075613815258: every terminal has an owner client that sets the authoritative size; other clients send advisory resizes that are recorded but do not resize; non-owners render at the owner's size and scroll to see it; a "take" action forces ownership; ownership passes to the latest advisory client when the owner detaches; optional local-only resize with client-side reflow on the primary screen.

## 6. Other context

- 41 built-in themes confirmed again (almonk reply, 26 Sep).
- iOS app exists internally (pearkes, 16 Sep).
- Superlogical site team: Mitchell Hashimoto, Jack Pearkes, Alasdair Monk, Hector Simpson (@dizzyup). Press kit has only logos and team photos.

## 7. Developer confirmations that the look is configurable (X replies, collected 1 Oct)

- Split style is a setting (almonk, 19 Sep, https://x.com/almonk/status/2101301158799093915). Q (@evkaky): "Before MacOS 27 arrived you had very nice island-like design for the splits. Now you replaced them with these very thin, barely noticeable lines..." A: "It's a setting - they're still there". So Compact (thin lines) is the current default since the macOS 27 builds, and Comfortable (islands) is the alternative.
- Density (almonk, 9 Sep, https://x.com/almonk/status/2097684624453333178): "It's a setting - we support both comfortable mode with padding between panes, and compact (what I'm showing here)".
- Vertical tabs as an option (almonk, 4 Aug, https://x.com/almonk/status/2084582437674193147): "absolutely. they will be" (later shipped, V08).
- Auto-copy on selection (almonk, 19 Sep, https://x.com/almonk/status/2101342381635235882): Q "Do you support auto clipboard copy option?" A "Yup!".
- Per-tab/workspace themes (almonk, 14 Aug, https://x.com/almonk/status/2088326520041300157): wanted, granularity undecided, "definitely on our list" (not shipped).
- Ghostty import is "just theme and theme related config right now" (19 Sep); 41 built-in themes (26 Sep).

## 8. Deck icon system (Hector Simpson, 12 Aug, https://x.com/dizzyup/status/2087543392859193368)

Video `new/2087543392859193368-v0.mp4` (3840x2160), frames `new/icons/f-*.png`, contact sheets `new/icons/grid1.jpg`, `grid2.jpg`.
"'Super Icon Studio' is how I've been designing the icons for our 'Deck' icon groups - it covers design finish across light/dark modes, layout compositions, animations, an icon catalogue".
- Every process icon = rounded-square **card colour** + **glyph colour** + an SVG glyph, plus a **finish**: radial gradient (strength 100%, adjustable offset/size) and a white highlight (opacity 100%), with light and dark mode variants.
- Named catalogue entries visible: Codex (card #F8F8F8, glyph #000000, OpenAI mark), Browser (card #2563EB, glyph #FFFFFF, compass), Git Changes (green card, plus-minus glyph), Shell (black card, white `>_`), Superlogical (card #CAF0FE, glyph #004D65, S-curve). About 25 others are redacted (coloured cards: blue, red, orange, purple, pink, indigo, teal, yellow-green, grey, black).
- Composer = the stacked multi-process badge used in tabs: layout Horizontal (or Vertical), Automatic gap on, Scale on ~15% (25% in vertical), Rotate on ~5 deg (2.5 in vertical), Y offset 0%, Reserve empty slots off, Glyph offset on ~30% (40% vertical). The front icon is the focused/primary process; the others peek out behind it to the right, each smaller and rotated, glyphs offset so a slice stays visible. Preview shows it at tab size ("Preview Tab" pill) and small.
