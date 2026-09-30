Evidence paths below refer to a local capture folder that is not committed (frames, crops and videos are large). Videos and images can be fetched again without logging in from `https://cdn.syndication.twimg.com/tweet-result?id=POST_ID&token=4`, whose `mediaDetails` list direct MP4 and image URLs. Key frames are kept locally in the ignored `frames/key/` folder.

# Superlogical visual spec for illogical

Measured from full-resolution frames of 17 X videos, Mitchell's 17 Sep Mastodon screenshots, almonk's 26 Sep video and the 30 Sep screenshot. Every value is in points (pt) unless marked px. Evidence paths are relative to `scratchpad/x/`. Key frames are in `key-frames/`, and annotated measurement crops are `key-frames/annotated-A/B/C-*.png`.

Confidence: H = measured directly on a 2x capture, repeatable across frames. M = measured once or on a rescaled capture. L = inferred.

## 0. Sources and capture scale

On this macOS (26/27) the traffic lights are 14 pt in diameter with 23 pt centre spacing. Every native 2x capture shows 28 px lights and 46 px spacing, so the usual 12/20 pt assumption does not apply. Scale = centre spacing in px / 23.

| ID | Date | Frame size | px/pt | Build notes |
|---|---|---|---|---|
| V01 | 20 Jul | 2258x1462 | ~2.0 | earliest prototype, dark |
| V03 | 4 Aug | 3240x2160 | 3.25 (upscaled) | process badges, hover tab |
| V04 | 12 Aug | 3840x2160 | 2.53 (upscaled) | session picker, peek, overview |
| V06 | 12 Aug | 3132x2160 | 3.0 (upscaled) | tab peek, session overview |
| V07 | 14 Aug | 2302x1614 | 2.0 | theme picker, light and dark |
| V08 | 27 Aug | 2264x1530 | 2.0 | vertical tabs, light |
| V09 | 28 Aug | 2340x2160 | 2.0 | Mitchell, vertical tabs, dark |
| V10 | 2 Sep | 1836x1326 | 2.0 | scrollback search |
| V12 | 8 Sep | 2438x1622 | 2.0 | Mitchell, session picker with hosts, directory picker, Comfortable |
| V13 | 8 Sep | 2658x1852 | 2.0 | palette, theme and style menus, Comfortable vs Compact |
| V14 | 14 Sep | 1768x1080 | ~1.5 | Mitchell CLI |
| masto | 17 Sep | 2048x1314 | 1.174 (+-2%) | light theme, 4 tabs, no pane titles (`masto/contrast-1.png`) |
| V16 | 19 Sep | 2430x1830 | 2.0 | full palette, Ghostty migration celebration |
| V17 | 19 Sep | 2320x1724 | 2.0 | dark, 3 panes Compact, copy feedback |
| V18 | 26 Sep | 2192x1610 | 2.0 | pane title rows on; newest chrome (`new/2103572918680645870-v0.mp4`) |
| R30 | 30 Sep | 1143x684 JPEG | 2.0 | fx and Claude badges; newest chrome (`new/rauchg-2104992830448087483.jpg`) |

Newest wins. The chrome tightened between 19 Sep and 26 Sep: titlebar 44 to 42 pt, selected capsule 30 to 28 pt, badge 23.5x19 to 21x17 pt, capsule leading padding 10 to 8 pt. Both sets are listed. Implement the 26/30 Sep set.

## 1. Typography

### 1.1 UI font

The chrome is **SF Pro** (the system font; SF Pro Text optical size at these sizes), identified by rendering candidate strings with `/System/Library/Fonts/SFNS.ttf` at opsz 17 plus Apple's tracking table and matching the ink width of the captured text to within 1 px at 2x. No other face matched. Use `NSFont.systemFont(ofSize:weight:)` / `.system(size:weight:)`; do not set a design (not rounded, not monospaced).

| Text | Size | Weight | Colour role | Evidence (measured ink width at 2x vs SF render) | Conf |
|---|---|---|---|---|---|
| Session name in titlebar ("electric-lagoon", "bold-dune") | 12 | semibold | secondary (fg ~68-72%) | V18 178 px vs 177.5; V17 121 px vs 119.8 (semibold) / 121.5 (bold) | H |
| Session subtitle ("This Mac", host) | 10 | regular | tertiary (fg ~45%) | V17 87 px vs 85-87; V18 86 px | H |
| Tab title | 13 | regular | selected: primary (fg ~97%); unselected: secondary (fg ~68%) | V18 "~/apps/replay-web - fish" 295 px vs 296 | H |
| Pane title row | 12 | medium (semibold in 8 Sep build) | focused: primary; unfocused: ~72% of focused | V18 282 px vs 283 (medium); V13 "shell" x-height 13 px | H |
| Command palette row | 13 | regular | primary; value/shortcut column secondary | V16 "Migrate theme from Ghostty config" 421 px vs 422 | H |
| Palette value / shortcut ("Berkeley Mono", "13 pt", "⌥⌘W") | 13 | regular | secondary | V16 1.9s | M |
| Palette scope chip ("Theme", "Interface Style") | 13 | semibold | white on accent-tinted chip | V13 i-0027 | M |
| Palette section header ("Go to"), picker host header ("This Mac") | 12 | semibold | tertiary | V12 5:15, 1:40 | M |
| Search query | 13 | regular | primary | V10 4.0s | M |
| Search count "1/2" | 13 | regular, monospaced digits | secondary | V10 4.0s | M |
| Vertical sidebar row | 13 | regular | selected primary, others secondary | V08 7s, 297 px | H |
| Vertical sidebar session header ("Website") | 11 | semibold | secondary | V08 7s cap 16 px | M |
| Overview session label ("Default") | 13 | semibold | secondary | V06 6.3s | M |
| Overview card title | 14 | regular | primary (hovered) / secondary | V06 6.3s | L |
| Celebration title "Themes migrated!" | 26 | bold | white | V16 5.4s, cap 37 px | M |
| Celebration buttons "Use themes" / "Done" | 13 | medium | white / primary | V16 5.4s | M |

Measured colours of chrome text (sampled glyph cores):

| Theme | Titlebar bg | Primary (selected tab) | Secondary (unselected tab, session name, +) | Tertiary (subtitle) |
|---|---|---|---|---|
| V17 dark neutral | #151515 | #F8F8F8 | #AFAFAF | #7B7B7B |
| V18 dark teal | #0B1212 | #CCD7D6 | #8A9A97 | #666F6E |
| masto light lavender | #FDFBFF | #2F2C33 | #5F5C63 | #939097 |

### 1.2 Terminal font

The terminal font is the user's Ghostty-style config, not a product constant. Two families appear:

| Who / sources | Family | Size | Cell (w x h) | Line height ratio | Evidence | Conf |
|---|---|---|---|---|---|---|
| Alasdair (V13, V16, V17, V18, masto, R30) | **Berkeley Mono** | 13 pt | 8 x 16 pt (16 x 32 px at 2x) | 1.23 | V16 palette literally shows "Change Terminal Font: Berkeley Mono" and "Change Terminal Font Size: 13 pt"; autocorrelation pitch 16/32 px in V13, V16, V17; masto 9.5/18.9 px at 1.174 | H |
| Mitchell (measured on V12; V09 and V14 show the same prompt and glyph shapes) | **JetBrains Mono** (Ghostty default) | 14 pt | 8.5 x 18.5 pt (17 x 37 px) | 1.32 | glyph shapes: `l` with right hook foot, single-storey `g`, JetBrains `@` and `r`; pitch 17/37 px in V12 | H (V12), M (others) |

Glyph notes (zoomed crops `crops/v17-digits-z.png`, `crops/v12-digits-z.png`): Berkeley Mono shows a dotted zero, a `1` with a flag and no foot, and URLs where `//` is drawn as a tight joined pair (ligature-like) after `:` (V13, V16, V17). JetBrains Mono also has a dotted zero but a taller, narrower oval, round `:` dots and the characteristic hooked `l`. No other programming ligatures are visible in any frame. Cell width is rounded up to whole device pixels (Berkeley Mono 13 pt advance 7.8 pt rounds to 16 px = 8 pt at 2x), which matches libghostty.

Recommendation for illogical's default: JetBrains Mono 13 pt (the Ghostty default Superlogical inherits), with Berkeley Mono selectable. When reproducing a specific screenshot, use Berkeley Mono 13 pt (Alasdair) or JetBrains Mono 14 pt (Mitchell).

Palette also shows these terminal settings exist: Terminal Font, Terminal Font Size, Terminal Padding Color (value "Extend"), Enable Terminal Font Smoothing, Cursor Blink Interval (500 ms), Selection Foreground (Theme), Selection Background (Theme), Set copy on select (On).

## 2. Colour model used below

Chrome colours are expressed as theme foreground (fg) or black/white at an alpha over the surface they sit on, because every sample across themes fits that model. Sampled hexes are listed as examples.

| Role | Dark themes | Light themes | Samples |
|---|---|---|---|
| Titlebar / chrome bg (Classic, Themed) | terminal bg darkened 1-2% (never lighter) | terminal bg, or 1% lighter | V17 titlebar #151515 vs focused pane #171717; V18 #0B1212 vs #0F1518; V13 #0C0F10 vs #101216; V12 #012027 vs #022733; masto #FDFBFF vs #FCFBFF |
| Primary text | fg ~97% | fg 100% | #F8F8F8 on #151515 |
| Secondary text/icons | fg ~68-72% | fg ~75% | #AFAFAF on #151515; #5F5C63 on #FDFBFF |
| Tertiary text | fg ~45% | fg ~50% | #7B7B7B; #939097 |
| Hairlines (titlebar separator, split divider) | fg ~7% | black ~7% | #252525 on #151515; #ECEAED on #F8F6F9 |
| Selected tab capsule fill | fg ~5% (up to 11% in R30) | white | #222222 on #151515; #131A1A on #0B1212; #303032 on #141215 (R30); #FFFEFF on #FDFBFF |
| Selected tab capsule stroke | fg ~12%, 1pt (top edge a touch brighter) | black ~9%, 1pt | #313131-#333333; #272E2E; #E5E3E8 |
| Hovered tab fill | fg ~7%, no stroke | black ~4% | V03 #133A4F on #02283D; R30 #272528 on #141215 |
| Accent | theme accent (not system accent) | same | Merino Dark #2657B3; Whitby Bay #7E5FB4; V12 teal #2AA489; V14 purple; light themes #0A7AFF |

illogical today: `chrome = bg.mix(white, 0.035)` for dark and `bg.mix(black, 0.025)` for light. That is the opposite direction to Superlogical: in dark themes the Superlogical titlebar is darker than the terminal, never lighter. `border = fg 12%/11%` is too strong for splits (use 7%).

## 3. Window chrome and titlebar (horizontal tabs)

Annotated: `key-frames/annotated-A-titlebar-26sep.png`. Frames: `key-frames/v18-26sep-0m00.5s-pane-title-row-newest-chrome.png`, `key-frames/rauchg-30sep-dark-fx-claude-badges.jpg`, `key-frames/v17-0m12s-dark-compact-3pane-no-pane-titles.png`, `key-frames/masto-17sep-light-4tabs-compact-acc-off.png`.

| Element | Superlogical (26/30 Sep) | Older (8-19 Sep) | illogical now | Evidence | Conf |
|---|---|---|---|---|---|
| Window corner radius | 16.5 (system, titlebar-only window, no NSToolbar) | same | system | corner fit 33 px in V17 and V18 | H |
| Window edge | system: 0.5 pt dark outline + 1 pt light inner highlight | same | system | V18 x=213-215 | H |
| Titlebar height (window top to separator) | **42** | 44 (V13, masto, V17) | 44 | V18 col x=1600: 161 to 245 px; R30 75 to 159 px; V17 168 to 256 | H |
| Titlebar bottom separator | 1 pt, fg ~7%, full width, Compact/no-island layouts only | same | none | V18 245-246 px #181F1F; V17 256 #252525 | H |
| Traffic lights | system 14 pt, 23 pt spacing; close centre x=24 (23.25 on 19 Sep); **vertically centred in the titlebar** (centre y=21 at 42 pt, 21.75 at 44 pt) | same | system default position (not centred in 44 pt bar) | V18 centres 261.5/307.5/353.5, y 203.5 px | H |
| Gap: zoom button right edge to session icon | **26** | 26 | 72 pt spacer + 10 + 6 padding: icon at x=88 (vs 103) | V18 367 to 419 px; V17 321 to 373 | H |
| Session icon | SF Symbol `laptopcomputer` (local), `globe` (remote), 15 x 9 pt glyph (about 13 pt symbol, regular), secondary colour | 8 Sep: stack icon `square.stack` only; 14 Sep: stack icon + name, no subtitle | `rectangle.stack` / `globe` 14 pt | V18 419-448 px | H |
| Icon to text gap | 10.5 | 10.5 | 7 | V18 448 to 469 px | H |
| Session name | 12 semibold, secondary colour, baseline 20 from window top | same | 11 semibold, primary | V18, V17 | H |
| Session subtitle | "This Mac" or host name, 10 regular, tertiary, baseline 31 from top (11 below name) | same | 9 regular, 45% | V18, V17 | H |
| Chevron after session name | **none** | none | `chevron.down` 8 pt | all 8-30 Sep frames | H |
| Session text to first tab | ~22 | 21 | 10 | V18 646 to 690 px | M |
| Tab width | **fixed 220** (all tabs, selected or not) | 220 (V17), 222 (masto, scale +-2%) | min 105, max 230, content-sized | V18 690-1129 px; V17 1026-1465; R30 542-983 | H |
| Tab spacing | 0 (adjacent) | 0 | 5 | masto pitch 262 px = 223 pt | H |
| Dividers between unselected tabs | 1 x 20 pt, centred vertically, fg ~15-20% (light #CFCCD3 on #FDFBFF); hidden next to the selected (and hovered) tab | same | none | masto x=682 and 943, y 158-180 px | H |
| Selected capsule | 220 x **28**, radius 14, 7 from top and bottom; fill/stroke per section 2 | 30 tall (V17), 31 (V03) | height 31, capsule, light: white 70%, dark: fg 9%; 0.5 pt stroke fg 12% | V18 176-231 px; R30 90-145 px | H |
| Tab leading padding (capsule edge to badge) | **8** | 10 (V17), 12 (masto) | 11 | V18 690 to 706 px; R30 542 to 559 | H |
| Badge | **21 x 17**, see section 4 | 23.5 x 19 (V17) | 23 x 18 | V18 706-748 x 187-221 px | H |
| Badge to title gap | 8 | 10 | 8 | V18 748 to 765 px | H |
| Title | 13 regular; selected primary, unselected secondary | same | 12 medium, primary for all | section 1 | H |
| Title overflow | no ellipsis; trailing linear fade ~16-18 pt wide; text box ends ~12 pt before the tab edge | same | `lineLimit(1)` ellipsis | V17 fade 1405-1441 px, capsule edge 1465 | H |
| Hover (unselected tab) | capsule fill fg ~7%, no stroke; close `xmark` ~8.5 pt glyph, secondary, at trailing edge ~12 pt from tab edge; title fade moves left | same | no fill; xmark 8 pt fades in, frame always reserved | V03 17s, V06 1.8s | M |
| Close button on selected tab | only on hover | same | on hover | V06 1.8s | M |
| `+` button | `plus` glyph 11 pt regular, secondary colour, centred 26 from window right edge, vertically centred | same | `plus` 24 x 28 frame + `...` menu button | V18 1887-1908 px; V17 2089-2110 | H |
| Other titlebar controls | none (no `...` menu, no settings button) | none | `...` workspace menu | all frames | H |

Tab strip overflow is not shown in any frame (max 4 tabs visible). With fixed 220 pt tabs, the strip must scroll or compress when tabs exceed the width; use horizontal scrolling that keeps the selected tab visible (illogical's current ScrollViewReader behaviour is fine).

## 4. Process badges (tabs, sidebar, overview cards)

Frames: `key-frames/rauchg-30sep-dark-fx-claude-badges.jpg`, `crops/v17-selected-tab-4x.png`, V03 17s (btop, Claude), V07 20s (btop), lead notes for nvim.

| Property | Value | illogical now | Conf |
|---|---|---|---|
| Size | 21 x 17 (26/30 Sep); 23.5 x 19 (19 Sep) | 23 x 18 | H |
| Shape | continuous rounded rect, radius ~4.5 | radius 4 | M |
| Edge | 0.5 pt dark ring (black ~60%) + 0.5 pt top inner highlight (white ~25%) | 0.5 pt white 18% stroke | M |
| Shell (`fish`, `zsh`, default) | dark neutral vertical gradient (#4B4B4B top to #262628 bottom in V17; #585D5E to #232728 in V18), glyph `>_` in green (#A5E4B1 core), glyph ~9 x 7 pt, drawn as a prompt chevron plus underscore | SF Symbol in #8CE8AD on white 25%-7% gradient | M |
| Claude Code (`claude`; OSC title starts with `✳`) | solid orange (#E06A3A to #E4704B), white Claude sunburst glyph | none | M |
| fx | black (#000000), white italic serif `fx` | none | M |
| nvim | teal/cyan square, bold `N` (per lead notes) | none | L |
| btop / top-style monitors | blue square with a pulse glyph (V03); dark red with white pulse (V07) | none | L |
| Multi-pane tab | stacked: front badge plus up to 2 slivers peeking out to the **right only**, each 5 pt wide, same height, vertically aligned, slightly darker, each with its own dark ring (V17: front 24.5 pt, +5, +5.5) | one grey rect offset (+3, -3) | H |

## 5. Pane layout, dividers, focus

Annotated: `key-frames/annotated-C-comfortable-layout.png`. Frames: `key-frames/v13-0m18s-comfortable-density-focus-stroke.png`, `key-frames/v13-0m26s-compact-density-interface-style.png`, `key-frames/v17-0m12s-dark-compact-3pane-no-pane-titles.png`, `key-frames/v12-3m05s-comfortable-single-pane-remote.png`.

| Element | Compact (current default in 17-30 Sep builds) | Comfortable | illogical now | Evidence | Conf |
|---|---|---|---|---|---|
| Outer inset | 0: panes flush to window edges and to the titlebar separator | **7** left/right/bottom; islands start 2 below the titlebar (46 from window top at 44 pt titlebar) | compact 0; comfortable 9 all sides | V13 i-0019: 248 to 262 px, 2408 to 2422, 1640 to 1654, 151 to 244 | H |
| Split gap | 1 pt hairline divider, fg ~7% (V17 #262626 on #161616; V13 #2F2F2F on #1C1C1C; masto #ECEAED) | **8** | compact 1 pt `border` (fg 12%); comfortable 8 | V17 1159-1161 px; V13 1327 to 1343 px | H |
| Pane corner radius | 0 (window corner clips the outer corners) | **10** | compact 0; comfortable 9 | corner fit 20-21.5 px in V12, V13 | H |
| Pane stroke | none | 1 pt, fg ~10%; **focused pane stroke = theme accent** | 0.5 pt, fg 13% focused / 6.5% unfocused | V13 i-0019 right pane #204166 on navy | H |
| Space between islands | window chrome colour (titlebar colour) | same | background material | V12, V13 | H |
| Unfocused pane | subtle darkening: 19 Sep ~3% black (#171717 to #161616); 8 Sep ~15% (#212121 to #1C1C1C); text dims with it | same plus neutral stroke | none | V17, V13 i-0027, masto | M |
| Terminal padding (pane edge to first cell) | ~8 left/right, 8-9 top (Ghostty-style balanced) | same inside the island | libghostty default | V17 text at 185 px vs edge 170; BL pane first row 16 px below divider | M |
| Vertical-tabs island | inset 8 top/right/bottom, starts at x=240 (sidebar) | - | sidebar 238 wide, no island inset | V08 7s | H |

### 5.1 Pane title row (optional setting; on in 8 Sep and 26 Sep builds, off in 17-19 and 30 Sep)

| Element | Value | illogical now | Evidence | Conf |
|---|---|---|---|---|
| Height | 32 (title centred 16 from pane top); then normal terminal padding | 30 | V18 title centre 279.5 px, 32.5 px below separator; V13 17.5 | H |
| Background / separator | none: same as terminal bg, no line below | theme colour bg | V18 col x=1000 | H |
| Leading icon | 26 Sep: `>_` prompt glyph 12 x 10 in title colour; 8 Sep: `dot.square` 10 pt; per process icon in V07 | process SF Symbol 10 pt at 50% | V18 242-265 px | H |
| Icon left inset | 12-13 from pane edge | 10 | V18 242 vs 216 px; V13 286 vs 262 | H |
| Icon to title gap | 6 (V18 265 to 277 px); 10 (V13) | 6 | | M |
| Title | 12 medium (26 Sep) / 12 semibold (8 Sep); focused primary, unfocused ~72% | 11 medium at 55% | section 1 | H |
| Controls | split right `rectangle.split.2x1`, split down `rectangle.split.1x2`, zoom `arrow.up.left.and.arrow.down.right`, close `xmark`; glyphs ~13 x 10; centres 24 apart; last centre 17.5 from pane right edge; fg ~30%; close drawn at ~12% when it would close the last pane | 9 pt glyphs in 19 x 20 frames at 55%, spacing 6 | V18 1759-1923 px | H |
| Control visibility | shown on the focused pane (and on hover); hidden on other panes | hover only | V13 i-0019, i-0027 | M |

## 6. Command palette (Cmd-Shift-P style; also hosts the theme, style and directory scopes)

Annotated: `key-frames/annotated-B-command-palette.png`. Frames: `key-frames/v16-0m01.3s-command-palette-full-list.png`, `key-frames/v16-0m01.9s-palette-fuzzy-filter-mi.png`, `key-frames/v13-0m02s-command-palette-t-filter.png`, `key-frames/v13-0m03s-theme-picker-scope-chip.png`, `key-frames/v07-0m20s-theme-picker-light-live-preview.png`, light: V08 0.15s.

| Element | Superlogical | illogical now | Evidence | Conf |
|---|---|---|---|---|
| Position | centred horizontally in the window; top edge 75-77 below the window top (about 32 below the titlebar) | top 76, centred | V13 303 px vs window top 151; V16 327 vs ~177; V12 190 vs 35 | H |
| Width (outer) | **331** | 360 | V13 1003-1663 px; V16 884-1545 | H |
| Height | content height, capped at **498** (list scrolls; overlay scroller appears) | min(items x 32 + 14, 380) | V13 and V16 both 997 px when capped | H |
| Corner radius | **18** | 13 | corner fit 36 px | H |
| Border | 0.5 outer black ~50% + 1 inner white ~10-12% (reads as a crisp light rim) | 0.5 fg 22% | V16 884 #17161C, 886-887 #374A4C | H |
| Fill | opaque-looking: terminal bg lightened ~6% in dark (#191B1C over #101216; #2F333F over #232831); near-white in light | `.regularMaterial` | V13, V16 | M |
| Shadow | soft, black ~25%, radius ~15, y ~3 (falloff visible ~15 pt) | black 28%, r 20, y 8 | V16 1324-1360 px | M |
| Backdrop | no scrim; the workspace stays at full brightness | none | V13, V16 | H |
| Search field | inset 8 (8.5 from outer edge) on top/left/right; height **30**; radius 9; fill fg ~8% (#2E2E30 on #191B1C; #424552 on #2F333F); no divider below | 20 pt field in a padded row with a Divider | V13 320-379 px, V16 344-404 | H |
| Field contents | `magnifyingglass` ~13 pt tertiary 10 from field left; text 13 regular starting ~27 from field left; clear button `xmark.circle.fill` ~15 pt tertiary at right when non-empty | similar, 12 pt spacing | V13, V16 | M |
| Placeholder | "Search commands..." (tertiary) | "Search commands..." | V16 1.3s | H |
| Scope chip (Theme, Interface Style) | inside field, 5 from field left/top; height 20; radius 5; horizontal padding 7.5; 13 semibold white; fill = accent at ~45% over the field (dark), fg ~10% (light, dark text); placeholder "Select Theme..." / "Select Interface Style..." 6.5 after chip | no chip; separate modes with different placeholders | V13 i-0027 1030-1227 x 330-369 px | H |
| Field to first row | 6 | 7 + divider | V16 404 to 416 px | H |
| Row pitch | **28** | 32 (29 + 3 spacing) | V13 409 to 464 px; V16 | H |
| Row highlight | 26 tall (1 pt vertical inset), radius **8**, inset 6 from panel edges | 29 tall, radius 6, inset 7 | V16 416-469 px; V13 392-443 | H |
| Selected row colour | **theme accent** (Merino Dark #2657B3, purple #7E5FB4, teal #2AA489, light #0A7AFF), text white, shortcut text white ~75% | `Color.accentColor` (system accent) | V13, V16, V12, V07 | H |
| Row text | 13 regular, 12 from highlight left (18 from panel edge) | 12 pt, 9 + 25 icon slot + 12 | V16 920 vs 896 px | H |
| Row icon (only some commands) | SF Symbol ~15 pt, tertiary, at the text position; title then starts 18 after the icon's left edge. Rows without an icon have no reserved slot | 25 pt icon slot on every row | V13 "Go to Director..." 1037 icon, 1074 text | H |
| Trailing column | shortcut (13 regular secondary, e.g. `⌥⌘W`, `⇧⌘G`) 9-10 from highlight right; or current value (secondary) + `chevron.right` ~9 pt tertiary for submenu commands; or `checkmark` (tertiary; white when selected) for toggles | detail 10 pt at 40% | V13, V16 | H |
| Fuzzy match | matched characters drawn in the accent colour on unselected rows ("Ter**mi**nal"); substring or subsequence match | plain `localizedCaseInsensitiveContains` | V16 1.9s | H |
| Sections | small header row with icon + label, 12 semibold tertiary, e.g. "Pane" with a grid icon | none | V13 i-0007 | M |
| Theme scope | theme names only (no swatches), current theme has trailing `checkmark`; moving the selection live-previews the theme across the whole window and terminal | 25 x 25 "Aa" swatch per row | V07 0:02-0:25, V13 i-0004 | H |

Commands seen (grouped as they appear; value in parentheses, shortcut after):

- Tabs/windows: New Tab ⌘T; Close Tab ⌥⌘W; Show Next Tab ⌃⇥; Show Previous Tab ⌃⇧⇥; Move Tab Left; Move Tab Right; Rename Tab (current title) ›; New Window ⌘N; Switch to Vertical Tabs ⇧⌘S; Switch to Horizontal Tabs (checkmark when active).
- Sessions/hosts: New Session ⇧⌘N; Close Session; Rename Session (name) ›; Change Session (name) ›; Previous Session; Switch Host (This Mac) ›; Add Remote Host... ›; Disconnect from Host... ›; Go to Directory... (…/Apps/rex-app) ⇧⌘G ›; Pair Device with QR Code...; Check for Updates....
- Pane section: Split Pane Left ⇧⌘←; Split Pane Right ⇧⌘→; Split Pane Down ⇧⌘↓; Split Pane Best Fit ⌘↩; Zoom Pane ⇧⌘↩; Focus Pane Left/Right/Up/Down ⌥⌘←/→/↑/↓; Focus Previous Pane ⌘[; Focus Next Pane ⌘]; Reset Terminal.
- Appearance: Change Theme (Whitby Bay / Merino Dark / Misty Cathedral) ›; System Appearance; Light Appearance; Dark Appearance; Change Interface Style (Classic / Themed) ›; Compact Density (checkmark); Comfortable Density; Change Terminal Font (Berkeley Mono) ›; Change Terminal Font Size (13 pt) ›; Change Terminal Padding Color (Extend) ›; Enable Terminal Font Smoothing; Change Cursor Blink Interval (500 ms) ›; Selection Foreground (Theme) ›; Selection Background (Theme) ›; Set copy on select (On) ›.
- Themes: Migrate theme from Ghostty config; Import Theme File...; Delete Custom Theme... ›; Reset all user themes; Preview theme import celebration.
- Aug builds only: Switch Session, New Shell Block, New Agent Block, Tidy Tab Title, Close Window, Show Status Bar, Refresh Sessions, Next Session.

Interface styles: Modern, System, Themed, Blended (8 Sep); the 19 Sep build shows the current style as "Classic", so the set changed. Built-in themes (41 = 26 dark + 15 light, names read from V07/V13 lists): dark Merino Dark, Abyssal Trench, Basalt Shore, Cathode Amber, Charcoal Atelier, Cinder Peak, Cobalt Foundry, Ember Hollow, Heliotrope Haze, Ink Meridian, Juniper Smoke, Midnight Tundra, Misty Forest, Moss Cathedral, Neon Arcade, Nocturne Rose, **Oxblood Library**, Petrol Lagoon, Phosphor Archive, Polar Aurora, Roasted Umber, Saffron Nightfall, Silver Point Dark, Sonoran Dusk, Static Noir, Velvet Dusk; light Merino Light, Alpine Milk, Buttercream Diner, Coastal Linen, Glacier Mint, Ivory Gallery, Lavender Postcard, Newsprint Fog, Orchard Breeze, Peach Veranda, Porcelain Morning, Silver Point Light, Sunlit Parchment, Terracotta Noon, Whitby Bay. illogical names one theme "Oxidized Library"; the real name is "Oxblood Library" (`crops/v07-t1-palette.png`).

## 7. Session picker (Cmd-K, click on the session button)

Frames: `key-frames/v12-1m40s-session-picker-host-groups.png` (8 Sep, newest seen), `key-frames/v04-0m27s-session-picker-aug12.png`.

| Element | Superlogical | illogical now | Evidence | Conf |
|---|---|---|---|---|
| Anchor | drops from the titlebar under the session button: top edge at the titlebar bottom (41-43 from window top); left edge placed so the row icons line up under the session button icon (panel left = session icon left - 14) | top 43, leading 86 | V12 panel 227 px, globe icon 256; V04 | H |
| Width | **195** | 280 | V12 227-616 px; V04 194 | H |
| Radius / border / shadow | as palette (radius ~14 at this size), same rim | 13 | V12 | M |
| Field | inset 6; height 26; sunken: darker than panel (bg ~ -4%) with 1 pt fg ~10% stroke, radius 8; placeholder "Filter or create..." | "Filter or create…" in a 20 pt field | V12 133-186 px | H |
| Host group header | icon (`laptopcomputer` "This Mac", `globe` remote host, truncated with ellipsis) + name, 12 semibold tertiary, pitch ~25 | none unless multiple hosts (detail text) | V12 | H |
| Session row | 13 regular primary; current session has a leading `checkmark`, others indent to the same text x; trailing shortcut ⌘1...⌘9 (secondary); pitch ~25; highlight 26, radius 7, theme accent, inset 6 | rows 29 + pencil button; detail "host · N tabs" | V12 | H |
| Footer | separator (1 pt fg ~10%, inset 6); "New Session ⇧⌘N" with `rectangle.stack.badge.plus`-style icon; separator; "Add Remote Host..." with globe icon | "New session…" / Create "query" row | V12, V04 | H |
| Create behaviour | typing a non-matching name offers creation (the field is "Filter or create...") | yes | V04 0:34 | M |

## 8. Vertical tabs sidebar

Frames: `key-frames/v08-0m07s-vertical-tabs-sidebar-light.png`, `key-frames/v09-2m24s-vertical-tabs-sidebar-dark.png`.

| Element | Superlogical | illogical now | Evidence | Conf |
|---|---|---|---|---|
| Structure | sidebar is part of the window chrome (no titlebar across the top); traffic lights sit in the sidebar; terminal area is an island inset 8 from top/right/bottom | titlebar row on top of a 238 sidebar | V08 7s | H |
| Width | 240 (window edge to island edge) | 238 | V08 124 to 603 px | H |
| Top row | traffic lights centred 25 from window top; `sidebar.left` toggle 15 pt secondary centred 35.5 right of the zoom centre; `plus` 11 pt at 24 from the sidebar edge | titlebar + `sidebar.left` | V08 | H |
| Session header | 11 semibold secondary, x 22.5 from window edge; ~34 pitch | 11 semibold 55% | V08 "Website", "Session b5ae0b1b" | H |
| Row | pitch 34; badge 22 x 18 at x 19; title 13 regular at x 49.5 (secondary; primary when selected); truncates with fade | DeckTab 31 tall capsule, 12 medium | V08 | H |
| Selected row | capsule inset 9.5 left/right (220 wide), 32.5 tall, fill white (light) / fg ~6% (dark), 0.5 pt stroke black ~10%, soft 1-2 pt drop shadow in light | capsule, white 70% | V08 143-584 x 475-540 px | H |
| Filter | capsule 165 x 30, radius 15, fill fg ~6%, x 8 from edge, centre 23 from window bottom; `line.3.horizontal.decrease.circle` icon + "Filter" 13 pt; matched text emphasised in results | capsule with icon + TextField, 12 pt | V08 | M |
| Footer buttons | new session (stack with plus) and add host (globe with badge) icons 16 pt, secondary, centres 53.5 and 23 from the sidebar edge | same two actions | V08 | M |

## 9. Tab peek and session overview

Frames: `key-frames/v06-0m01.8s-tab-peek-strip.png`, `key-frames/v06-0m06.3s-session-overview-grid.png`, sheets `crops/sheet-V06-peekopen.png`, `crops/sheet-V06-transition.png`. Build is 12 Aug (3.0 px/pt).

| Element | Superlogical | illogical now | Conf |
|---|---|---|---|
| Peek trigger | 3-finger swipe down; the terminal surface translates down without resizing (bottom goes off-window) | same model (offset) | H |
| Peek strip | each titlebar tab grows downward into a card: header (badge + title) on top, live preview under it; cards share the tab-strip width equally (190 each for 4 tabs at 944 window); card 190 x 130, radius ~12, hovered/selected card lighter fill + close `xmark` | separate overview row of 245-wide cards with padding 12 | M |
| Peek preview | live, includes splits, ~176 x 78, inset ~6 inside the card | live previews | M |
| Peek travel | terminal top moved from 46 to ~142 (about 96) at full peek | proportional offset | M |
| Overview (keep dragging) | titlebar content fades out (only traffic lights remain); cards animate from the strip into a centred grid; session label ("Default") 13 semibold secondary 21 above the grid; 2 columns, card 302 x 168, gaps 15 x 15, header 32 with badge + 14 pt title, preview inset 6; hovered card: lighter fill + 1 pt light stroke + close `xmark`; background = window chrome with a soft radial vignette | adaptive grid min 240 max 420, card fill fg 3.5%, radius 12, title 11 pt, "Sessions" header + close button | M |
| Timing | peek opens in ~200 ms (1.4 s to 1.6 s at 10 fps); overview transition ~350 ms with a gentle spring (cards scale and reflow, 5.1 s to 5.5 s); exit ~300 ms | spring | M |

## 10. Scrollback search

Frames: `key-frames/v10-0m01s-search-overlay-default-position.png`, `key-frames/v10-0m04s-search-overlay-dodged-match.png` (2 Sep, 2x).

| Element | Superlogical | illogical now | Evidence | Conf |
|---|---|---|---|---|
| Size | **300 x 38** | max 330 x 38 (61 compact) | V10 1048-1647 x 264-339 px | H |
| Position | top-right of the pane: 8 from the right edge, 6 below the pane top; moves down (below the match line) when it would cover the current match, then returns | top-right with dodge logic | V10 t1 vs t4 | H |
| Shape | radius 10, fill fg ~8% over the dimmed terminal (#202020), 1 pt stroke fg ~16% (#343434-#373737), no shadow visible | radius 10 regularMaterial + shadow 20% r12 | V10 | H |
| Contents | no magnifier; placeholder "Find"; query 13 pt primary at 12 from left; count "1/2" 13 pt secondary (monospaced digits) right-aligned 10 before a 1 x 18 divider (fg ~10%); `chevron.up`, `chevron.down` (~10 pt glyphs, tertiary), `xmark` (~9.5 pt); control centres 26 apart; last centre 18 from the right edge | magnifier + field + count + chevrons + xmark, 11 pt | V10 | H |
| Terminal while searching | only while the query is non-empty: the whole pane (bg and text) dims to ~50% (bg #171717 to #0D0D0D, text luminance 202 to 102), fading in within ~300 ms; clearing the query or closing restores it. An empty field (placeholder "Find") does not dim | no dim | V10 luminance track: 0.4-0.9 s field open, undimmed; 1.2 s dimmed; 2.4-2.7 s query cleared, undimmed; 9.6 s closed | H |
| Current match | yellow fill #DDD212 (fg-independent) with dark text, radius ~2 | engine highlight | V10 | H |
| Other matches | 1 pt rounded outline fg ~15%, text undimmed, no fill | engine highlight | V10 t1 (`crops/v10-othermatch-8x.png`) | M |

## 11. Copy feedback (V17, 19 Sep)

Frames: `key-frames/v17-0m03.3s-selection-before-copy.png`, `key-frames/v17-0m03.6s-copy-flash-glint.png`, strip `crops/v17-copy-strip.png`.

- Selection itself: rounded rect per selected run (radius ~2), fill = theme selection bg (#242424 on #171717 here), multi-line selections are one merged shape.
- On copy (Cmd-C or copy-on-select), t = 0: the selection shape gains a 1 pt white stroke (~70-90% at the leading edge) and grows ~1 pt outward (scale ~1.02).
- 17-100 ms: a soft white radial glint (width ~25-30% of the selection, peak near white through the text) sweeps left to right across the selection. Multi-line selections sweep diagonally from the top-left.
- 100-170 ms: stroke and glint fade out; selection returns to normal and stays selected.
- Total ~170 ms. No toast, no sound. illogical: selection is engine-drawn and copy has no visual feedback.

## 12. Ghostty theme migration celebration (V16, 19 Sep)

Frames: `key-frames/v16-0m03.9s-celebration-shockwave.png`, `key-frames/v16-0m05.4s-themes-migrated-celebration.png`, sheet `crops/sheet-V16-celebrate.png`.

- Not a sheet: an in-window overlay. The whole window (including titlebar content, excluding the system traffic lights) dims with a dark radial vignette, and a soft blue-white spotlight beam falls from the top centre.
- 0-400 ms: two theme cards (dark and light Ghostty themes, e.g. Carbonfox and Dayfox) fly in from below while spinning in 3D, then settle facing front, tilted about -6 and +6 degrees.
- ~600 ms: a circular shockwave ring expands from behind the cards with a confetti and 4-point sparkle burst; "Themes migrated!" drops in letter by letter (~200 ms).
- Idle: sparkles twinkle, cards bob gently.
- Card: ~155 x 125 including the bezel (measured on the tilted dark card, V16 5.4s 865-1176 x 663-914 px), thick coloured bezel (dark card: periwinkle #7C9BF0-ish; light card: lavender) radius ~12, screen shows "Aa", a `~/` prompt chip with a block cursor, a row of overlapping ANSI colour dots, theme name bottom-left (12 semibold).
- Title 26 bold white, centred, cap top ~55 below the cards. Buttons below: "Use themes" filled accent capsule (100 x 30, #6690E4 here, white 13 medium text) and "Done" grey capsule (62 x 30, white ~12%), 8 apart.
- "Use themes": cards dissolve (~200 ms), overlay fades, theme is applied. "Preview theme import celebration" command replays it.
- illogical: a 540-wide sheet with static confetti capsules, 42 pt palette icon, "Your themes, right at home." 23 semibold, swatch cards, "Keep Current Theme" / "Use These Themes".

## 13. Directory picker (Cmd-Shift-G, "Go to Directory...")

Frame: `key-frames/v12-5m15s-directory-picker-go-to.png`. Same panel as the command palette (331 wide, same position and rim). Field shows the typed path (`/`) with a clear button. First a "Go to" section header (folder icon, 12 semibold tertiary), then the current path row (selected, accent) and one row per directory with a `folder` icon (15 pt tertiary) and name 13 regular; 28 pitch. Lists the directories of the focused session's host (remote-aware). illogical: separate header showing the path in 10 pt monospaced plus "Open terminal here" and ".." rows.

## 14. Menus seen

- Interface style menu = palette scope ("Interface Style" chip): Modern, System, Themed, Blended; current has trailing checkmark, highlight follows keyboard/hover independently (V13 i-0008 to i-0012).
- No right-click context menus appear in any video.
- Empty state: never shown.

## 15. Motion summary

| Interaction | Observed | Conf |
|---|---|---|
| Tab selection | capsule moves instantly (no slide visible at 60 fps) | M |
| Tab hover | fill and close button fade in, ~120 ms | L |
| Palette open/close | appears within one frame at 60 fps (no scale, no slide); list filters instantly | M |
| Theme live preview | chrome and terminal recolour on every selection move, no crossfade visible | M |
| Search open | field appears at once; terminal dim fades in over <=300 ms once a query has matches (V10 0.9 to 1.2 s) | M |
| Search dodge | field jumps to the new y when the current match would be covered (no slide seen at 10 fps) | M |
| Copy feedback | ~170 ms flash + glint (section 11) | H |
| Peek / overview | ~200 ms peek, ~350 ms overview spring (section 9) | M |
| Celebration | ~1 s entrance, idle loop, ~200 ms dismissal (section 12) | M |

## 16. What illogical should change (prioritised, exact values)

P0 = visible in every screenshot; fix first. Values are the 26/30 Sep build unless noted.

**P0**

1. Titlebar geometry (`WorkspaceTitlebar`): height 44 to **42**; add a full-width **1 pt separator at fg 7%** at its bottom in Compact / no-island layouts; centre the traffic lights vertically in the bar (centre y = 21, close centre x = 24, 23 pt spacing) instead of the default plain-titlebar position.
2. Chrome colour (`TerminalTheme.chrome`): dark themes `bg.mix(black, ~0.02)` (titlebar slightly darker than the terminal, e.g. #151515 over #171717); light themes `bg` (or `mix(white, 0.01)`). Today it lightens dark themes by 3.5%, the wrong direction.
3. Session button: remove the `chevron.down`; icon `laptopcomputer` for local (not `rectangle.stack`), `globe` for remote, ~13 pt symbol, secondary colour; start the icon 26 pt after the zoom button's right edge (x ~= 103 from the window edge; today 88 via the 72 pt spacer + 10 + 6); icon-to-text gap 10.5 (today 7); name **12 semibold secondary** (today 11 semibold primary); subtitle **10 regular tertiary** (today 9 at 45%); baselines 20 and 31 from the window top; ~22 pt from the session text to the first tab (today 10).
4. Tabs (`DeckTab`, horizontal): fixed **220 x 28** item, **0** spacing (today min 105 / max 230, spacing 5, height 31); selected = capsule radius 14 with fill fg ~5% (dark) / white (light) and **1 pt** stroke fg ~12% / black ~9% (today 0.5 pt, fill 9% or white 70%); unselected = no fill with a **1 x 20 pt divider at fg ~15-20%** between neighbours, hidden next to the selected/hovered tab; hover = fill fg ~7%, no stroke; leading padding **8** (today 11); badge **21 x 17** (today 23 x 18); badge-title gap 8; title **13 regular** (today 12 medium), primary when selected, secondary otherwise; replace the ellipsis with a ~16 pt trailing fade mask ending 12 pt before the tab edge; close `xmark` only on hover at the trailing edge without reserving space when hidden.
5. Titlebar right side: keep only `+` (11 pt glyph, secondary, centred 26 from the right edge). Move the `...` menu items (Command Palette, Session Overview, Vertical Tabs, Appearance, Add Remote Host) into the palette and app menus.
6. Split dividers and islands: Compact divider fg **7%** (today `border` = 12%). Comfortable: outer inset **7** left/right/bottom and **2** below the titlebar (today 9 all round), gap 8 (ok), radius **10** (today 9), stroke **1 pt** fg ~10% (today 0.5 pt at 6.5-13%), focused pane stroke = **theme accent**.
7. Command palette (`PaletteOverlay`): width **331** (today 360); radius **18** (13); rim 0.5 pt black 50% outside + 1 pt white ~10% inside; opaque fill = bg lightened ~6% (dark) instead of `.regularMaterial`; shadow black 25% r15 y3; field **30 tall, radius 9, fill fg 8%, inset 8**, no Divider; rows **28 pitch** with a **26 pt, radius 8** highlight inset 6 (today 29 + 3 spacing, radius 6); row text **13 regular** at 12 from the highlight edge (today 12 pt behind a 25 pt icon slot); no reserved icon slot; trailing shortcut/value **13 secondary** (today 10 pt at 40%) with `chevron.right` for submenus and `checkmark` for toggles; selection fill = **theme accent** (today system `accentColor`); highlight fuzzy-matched characters in accent; cap height at 498 and scroll.
8. Typography sweep: every chrome string to SF Pro at the sizes in section 1.1 (tab 13 regular, session 12 semibold / 10 regular, pane title 12 medium, palette 13, search 13).

**P1**

9. Pane title row (`TerminalPane`, when enabled): height **32** (30), no background fill (today theme colour), no separator; icon 12 x 10 at 12-13 from the pane edge; title **12 medium**, primary on the focused pane, ~72% on others (today 11 medium at 55%); controls 13 x 10 glyphs, centres 24 apart, last centre 17.5 from the edge, fg ~30%, visible on the focused pane (not only hover).
10. Badges (`DeckIcon`): stacked badges peek out to the right only (up to 2 slivers, 5 pt each, same height); add Claude Code (orange, sunburst), fx (black, italic fx), nvim (teal, N), monitor (pulse) badges keyed on the foreground process; keep the dark shell badge with a green `>_`.
11. Session picker: width **195** (280); anchor under the session button icon, top at the titlebar bottom; field 26 tall, sunken with a 1 pt stroke; host group headers with laptop/globe icons; current session checkmark; ⌘1-⌘9 shortcuts; separators; footer rows "New Session ⇧⌘N" and "Add Remote Host..." with icons; drop the pencil rename button (rename lives in the palette).
12. Search overlay: **300 x 38**, radius 10, fill fg 8% + 1 pt stroke fg 16%, no shadow, no magnifier, placeholder "Find" (today "Find in terminal"); 13 pt text (11 today); dim the pane to ~50% while the query is non-empty; current match yellow #DDD212 with dark text, other matches 1 pt outline.
13. Unfocused panes: add a subtle dim (black ~3%, newest build) including text.
14. Theme list: rename "Oxidized Library" to **"Oxblood Library"**.
15. Vertical tabs: sidebar 240 including traffic lights (no titlebar row across the top), terminal island inset 8 top/right/bottom, rows 34 pitch, selected capsule 220 x 32.5 inset 9.5 with 0.5 pt stroke and a soft shadow in light themes, headers 11 semibold, filter capsule 165 x 30 at the bottom-left with two 16 pt icon buttons.

**P2**

16. Copy feedback flash + glint (~170 ms, section 11).
17. Ghostty migration as an in-window celebration overlay (section 12) instead of a sheet.
18. Tab peek: grow the titlebar tabs into 190 x 130 cards with header + live preview; overview grid 2 columns of 302 x 168 cards, gaps 15, session label 13 semibold 21 above.
19. Directory picker: reuse the palette panel with a "Go to" section and folder rows.
20. Default terminal font: JetBrains Mono 13 pt, cell rounded to whole pixels (Berkeley Mono 13 pt and JetBrains Mono 14 pt reproduce the demo screenshots).

## 17. Not established by any frame

Exact interface-style list after 19 Sep ("Classic" is new); tab overflow behaviour beyond 4 tabs; right-click menus; settings window (all settings are palette commands in every video); nvim badge colours (only described in notes); precise easing curves.
