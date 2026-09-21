# Terminal rendering

The native client uses libghostty-vt for terminal state, Unicode cell widths, selection, and escape-sequence behavior. Metal draws that state with a CoreText glyph atlas. It does not embed Ghostty's complete renderer, so sharing the parser is not a claim of pixel-for-pixel rendering parity.

## Font and geometry behavior

- The selected native font supplies regular, bold, italic, and bold-italic faces. CoreText shapes complete grapheme clusters, including combining marks and emoji sequences. Color emoji keep their original colors.
- Private-use Nerd Font characters first use the selected face when it contains the character, then an installed Symbols Nerd Font face, then the bundled OFL-licensed JetBrains Mono Nerd Font. The bundled fallback is opened privately and lazily, without installing fonts or enumerating the user's entire font collection at launch.
- Nerd symbols can occupy spare space in the following blank cell. Adjacent icons retain a single-cell constraint. Common Powerline separators, box drawing, and Braille are drawn from the cell geometry; block elements are direct Metal rectangles. This avoids baseline gaps in terminal graphics such as DOOM Fire's upper-half blocks.
- Graphics elements retain their requested colors, including when minimum text contrast correction is enabled. Text contrast follows the chosen app preference.
- OpenType features and variable font axes are part of the font and atlas cache identity. Adjacent code operators share a cached shaped run, which enables code-font ligatures. Operator glyph origins follow the terminal grid without stretching their outlines; genuine font ligatures remain enabled.
- Font thickening uses CoreText smoothing in an alpha-only linear-gray context, including its configurable 0–255 strength, following Ghostty's macOS rasterizer. Monochrome coverage is tinted in Metal, so changing foreground color does not create another bitmap for the same glyph.
- The block cursor uses an opaque cursor background and inverted text; wide characters receive a wide cursor. Unfocused and explicitly hollow cursors use outlines.
- Presentation follows the current display's native refresh cadence, coalescing terminal-state invalidations without discarding any PTY bytes. A private serial queue acquires Metal drawables, so a saturated swap queue cannot block the main thread's terminal parser. At most one drawable acquisition and three GPU-owned buffers exist per surface. Unchanged surfaces submit no GPU frames and pause their display link after a 100 ms grace period, avoiding display-link thread churn between output bursts. Fully hidden surfaces pause immediately. The Metal child's attachment, visibility, and screen changes wake it with the latest state, including when it joins an already visible window.

## Display clarity

Grid metrics round to physical pixels at the current display scale, following the pinned Ghostty `src/font/Metrics.zig` approach. Moving between 1x and 2x displays invalidates the metric cache and updates the terminal's pixel geometry while idle. The Metal child aligns its origin and edges through AppKit backing conversion, and the shader viewport uses the actual drawable size so fractional split bounds cannot stretch the entire terminal image.

Ordinary glyphs use nearest-texel atlas sampling, as in Ghostty's `src/renderer/shaders/shaders.metal`. CoreText still supplies antialiased coverage; nearest sampling prevents a second interpolation from softening it. Scaled tab previews and images retain linear sampling. Grouped ASCII operators use the existing CoreText grid shaper instead of horizontally scaling a complete line.

The original code reproduced alternating blurred letters on 1x displays and fractional-bounds softening at both scales. [Clarity evidence and limits](font-clarity.md) records the actual Metal readback and AppKit lifecycle checks.

## Verification

Run `./scripts/test-rendering.sh` on macOS with the pinned dependencies available. The test renders through the actual Metal shader into an offscreen texture, checks gap-free half-block pixel rows, and writes `.build/tests/terminal-rendering.png` for inspection. It also checks BMP and supplementary Nerd Font coverage, the bundled fallback font, combining marks, CJK, color emoji, variable font weight, font smoothing, and code ligatures. The variable font fixture is Ghostty's pinned Lilex font; tests do not depend on the user's private MonoLisa installation.

The same script verifies presentation scheduling under bursts, an update arriving after a frame begins, exhausted GPU buffers, failed drawable acquisition, and cancellation. It asserts that the final dirty state is retried rather than being lost.

The original fallback defect was reproduced with the app's system monospace face: CoreText selected LastResort for U+F115, U+F120, and other common Nerd Font characters even though suitable fonts were installed. The explicit PUA fallback fixes that condition.

## Remaining differences from Ghostty's renderer

Arabic and Indic text now uses bounded same-style contextual runs with CoreText glyph indices and terminal-grid anchors. Maintained tests cover Arabic, Devanagari and Bengali, fallback fonts and exact tiled rendering. This follows forced-LTR terminal-grid behavior, not paragraph-level bidirectional layout. Context is limited to 1,024 UTF-16 units; arbitrary-script conformance remains unverified. Ghostty's complete per-symbol Nerd Font constraint table and all legacy-computing sprite shapes are not reproduced. Color emoji use the client's current RGB atlas rather than Ghostty's dedicated Display-P3 color atlas. These differences must be checked against a selected font, theme, scale, and representative terminal program before claiming exact visual parity.

The installed `MonoLisaVariable Nerd Font` on the development machine has no variable axes, despite its name. The separate `MonoLisa Variable` face exposes a weight axis. Importing a `wght` setting preserves the user's selected font; CoreText can apply it only when that face actually contains the axis.

Static Kitty images, extended decorations, demand-driven blinking text and imported opacity are covered in [graphics compatibility](graphics-compatibility.md) and the [rendering audit](audit-rendering.md). The production renderer passes a four-pane test with images and 40 opacity/theme transitions, including Address Sanitizer.
