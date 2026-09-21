# Static terminal image compatibility

illogical renders ordinary Kitty Graphics Protocol RGB, RGBA and PNG image placements through an authoritative service scene. It does not claim complete Kitty or Ghostty renderer parity.

## Supported path

The service uses pinned libghostty's image parser, bounded PNG decoder, raw image pixels, placement geometry, clipping/source rectangles and image generations. It sends a complete placement list with changed pixel blobs after mutations, and a full scene after attachment snapshots. The native replica leaves image storage disabled, avoiding duplicate image registries and protocol responses.

The native Metal renderer uploads RGB/RGBA/gray pixels once per image generation, converts straight alpha to premultiplied output, clips destination geometry and source UVs to the terminal viewport, and composites the three Kitty z layers around cell backgrounds and foreground text. Images bypass text contrast correction. Same-ID, same-size retransmissions replace the cached texture because the generation changed.

Placements are anchored relative to the live screen's top row. Every client resolves that anchor using its own current scrollbar and cell metrics; scrolling, different display scales, overview previews and prepending snapshot history therefore do not depend on the server's visible viewport. Scene cell pixel dimensions preserve placement offsets and image sizing when a replica uses different local font metrics. Synchronized terminal output retains the last submitted image scene until its hold ends or expires.

## Why images need a separate snapshot scene

The pinned upstream snapshot implementation deliberately omits image and placement registries. Its test, `complete snapshot preserves Kitty virtual placeholders`, asserts that the restored image and placement counts are zero. Replaying cursor-position escapes cannot recreate placements anchored in older scrollback.

The service keeps graphics-bearing terminals resident instead of parking them into an incomplete snapshot. The bounded canonical registry preserves unplaced images, placements outside the current viewport, and the inactive screen. Attachments receive current pixels/placements alongside the normal text snapshot; image mutations participate in the same replay sequence as output/resize/theme changes. Native resets discard old scene data, stale attachment messages are ignored, and a missing graphics sequence triggers a full resync.

The image-disabled native parser cannot apply Kitty placement cursor movement or scrolling. After image content changes involving placements, the service therefore sends a selective corrective text snapshot marked `text = "graphics"`, followed by history and a complete image scene. This creates a replay barrier; older replay cursors resynchronize. Native replicas retain their local viewport, selection and search query while history arrives, unless fresh user input changes that local state. Ordinary text, viewport scrolling and geometry-only resize updates do not take corrective snapshots. Image-heavy workloads pay snapshot encoding, transfer and history restoration costs; no equivalent-throughput claim is made for them.

## Resource limits

- Service image storage: 8 MiB per primary/alternate screen; 1,024 canonical image IDs and 1,024 exported placements.
- PNG decoding checks dimensions and decoded size before allocation; image dimensions are bounded to 10,000 pixels before decoding, with the aggregate byte bound enforced separately.
- Native CPU scene retains only images referenced by the current complete placement list, with an 8 MiB aggregate payload bound.
- Native GPU texture cache: 64 MiB shared across terminal renderers, generation-aware LRU eviction and explicit deletion pruning. Submitted GPU commands retain their resources until completion.
- Native snapshot continuation validation: 16 MiB; Kitty APC buffer: 12 MiB. A maintained dependency patch reduces upstream's temporary image/inflate hard limit to 8 MiB.

These are product limits, not claims that every accepted Kitty command can render without limits. Ordinary terminals do not create image textures, scene timers or additional GPU draw calls.

## Remaining compatibility limits

- Automatic Kitty image animation is not implemented; animation frame, control and composition commands explicitly return `ENOTSUP` without mutating the static registry. The public image API exposes the current frame, but clock advancement/deadline scheduling remains internal to Ghostty's renderer; no public C tick API is exposed in the pinned revision.
- Unicode virtual placements and relative placements rooted in them are not rendered. The public placement geometry helper explicitly reports them as not viewport-visible; reproducing them needs a renderer that resolves the placeholder cells and their inherited diacritics.
- Contextual Arabic/Indic grid runs now use the pinned Ghostty CoreText anchoring model, including context across atlas tiles. Complete symbol constraints, Display-P3 emoji and unrelated image protocols remain separate gaps. Paragraph BiDi and contextual runs exceeding the 1,024 UTF-16 context bound are not claimed.
- Exact Superlogical coverage of each graphics variant is not established by the preview corpus. Static graphics passing tests does not establish one-to-one application parity.

## Maintained checks

`scripts/test-graphics.sh` tests native scene transactions and real text-snapshot/reconnect sequencing, including query/selection/viewport retention across a 2,000-row corrective snapshot without viewport echo. `scripts/test-resource-render.sh` exercises the production Metal pipeline and texture cache, including decoded channel formats, generation replacement, deletion, cache bounds, clipping/UVs, independent scrolling, prepended history and alpha pixels. Service integration checks exercise real PTYs and canonical image lifetime separately. Separate native GUI checks verified a four-quadrant RGBA image live and after GUI reopen, with the shell prompt correctly below its placement. The original translucent theme import and saved-theme startup crash reproductions now pass with four panes and an image. The production renderer also passes Address Sanitizer after correcting a single-quad stack-read boundary. These representative checks do not cover every image placement variant.

Primary implementation references in Ghostty revision `27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c`: `include/ghostty/vt/kitty_graphics.h`, `src/terminal/c/kitty_graphics.zig`, `src/terminal/snapshot/snapshot.zig`, and the animation clock in `src/renderer/generic.zig`.
