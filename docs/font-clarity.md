# Font clarity on external displays

The 21 September 2026 report concerned most terminal text, especially on monitors. Inspection used the pinned Ghostty source at `27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c`, including `src/font/Metrics.zig`, `src/font/face/coretext.zig`, `src/font/shaper/coretext.zig` and `src/renderer/shaders/shaders.metal`. Ghostty's MIT license remains bundled in `illogical/Resources/Licenses/Ghostty-LICENSE.txt`.

## Reproduced defects

- Cell width always rounded upward to half a point, assuming Retina's 2x backing scale. At 1x, SF system monospace at 12, 13 and 15 pt placed alternate columns between pixels. In a row of 24 identical letters, 12 of the following 23 columns differed from the first glyph's coverage.
- Fractional split geometry stretched the entire drawable. A real AppKit pane with fractional origin and extent produced an 803x601 texture displayed across 802.7x601.3 physical pixels. Offscreen full-renderer checks with fractional bounds altered all 23 comparison columns at both 1x and 2x.
- Linear atlas sampling interpolated already-rasterized glyph coverage. Ghostty's ordinary glyph path uses nearest sampling instead.
- Grouped ASCII operators were horizontally stretched to fill the rounded grid width. With ligatures disabled, the grouped pixels differed from separately rendered characters in every tested font/scale combination.

## Changes

Cell dimensions now round in device pixels at the current backing scale, and the metric cache includes that scale. AppKit aligns the Metal child's physical origin and extent. The renderer maps positions against the actual drawable dimensions. Backing and screen changes schedule layout while the terminal is idle, updating the PTY's cell pixels and native search geometry. Mouse reporting, IME placement and copy feedback share the adjusted origin.

Full-size glyphs sample exact atlas texels; scaled previews and Kitty images keep linear filtering. CoreText antialiasing, smoothing preferences and font thickness are unchanged. Grouped operators now use the existing grid-aware CoreText shaping path, which positions glyphs without stretching their outlines and preserves true ligatures.

The corrections add no timers or polling and do not add per-frame glyph rasterization. Atlas reuse, event-driven redraw and preview isolation remain in place. Changing monitors can change the number of columns that fit because the point-space cell width must round to that monitor's device pixels.

## Validation

- `scripts/test-display-text.sh` renders through the production Metal encoder and reads the GPU pixels. All 16 combinations of 1x/2x, 12/13/14/15 pt and integral/fractional pane bounds now produce identical coverage at every repeated-letter column. The same check failed before the correction.
- `scripts/test-font-rasterization.sh` passes 36 SF system monospace/JetBrains combinations across 12/13/14 pt, 1x/2x, regular/bold/italic. Grouped non-ligating operators exactly match separate glyphs. Lilex code ligatures still render differently when enabled.
- `scripts/test-display.sh` exercises the production AppKit view: physical alignment, 2x-to-1x-to-2x lifecycle, idle pixel-geometry updates, notification deduplication, mouse boundaries, IME alignment, preview isolation and observer teardown.
- Existing rendering, contextual-shaping, native input and surface-resource checks pass, including Nerd Font/emoji coverage, copy/link behavior and 32 idle previews without cursor timers. The complete Metal renderer also passes four panes with images and 40 opacity/theme transitions.
- The isolated Release app displayed ordinary text, repeated operators and Nerd Font symbols in two panes. Native divider dragging resized the panes correctly, and the tab preview retained its scaled terminal contents.

Only the built-in Retina display was connected during this work. Real AppKit geometry was checked there; backing-scale transitions were simulated through the actual view, and 1x output was verified using GPU readback. Physical external-monitor acceptance remains a separate check. macOS display scaling, monitor configuration and panel characteristics can still affect final on-screen appearance.

Local artifacts: `.build/display-text-before.log`, `.build/display-text-after.log`, `.build/display-text/before-1x.png` and `.build/display-text/text-1x.png`. These are ignored build outputs; the maintained scripts reproduce the current checks. The geometry change also means older throughput samples must retain their recorded grid dimensions when compared with this build.
