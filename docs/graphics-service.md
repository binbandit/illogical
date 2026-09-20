# Static terminal images

The service supports direct Kitty RGB, RGBA and PNG images with ordinary pinned placements, cropping, offsets, z-order, scrolling, resizing, deletion and primary/alternate screens. Images are service-owned. Native clients receive an ordered graphics scene alongside terminal output, rather than answering image queries or keeping a second terminal image registry.

This is **static graphics support**, not complete Kitty protocol parity. Animation playback and Unicode virtual placements are not implemented by the native renderer. File, temporary-file and shared-memory transmission are disabled. Animation frame uploads, controls and composition commands are rejected with ENOTSUP before retaining hidden animation state; quiet requests still suppress responses. Unicode virtual placement rendering remains unsupported.

## Reconnect and parking

Ghostty snapshot v1 deliberately omits image registries. A snapshot is therefore followed by a complete graphics scene at the same replay cursor, with `reset: true` and no `previousSequence`. Geometry-only live graphics updates are ordinary sequenced replay mutations, following the output or resize that produced them. They contain a complete placement list and only newly referenced or changed image blobs. Clients discard unreferenced blobs. Empty arrays are encoded as `[]`.

Native acceptance exposed a separate parser issue: Kitty display commands move the authoritative cursor and can scroll, while the image-disabled replica skips these effects. Text immediately following an image therefore appeared on the wrong row until reconnect. Image content/placement changes now establish an authoritative correction boundary: the service advances the sequence, retires earlier replay cursors, and sends an active-screen/history snapshot with `text: "graphics"`, followed by the complete scene. Native clients preserve local viewport, selection and search across that correction. A disconnected client behind the boundary receives explicit resync instead of replaying divergent image bytes. Ordinary text, scrolling and geometry-only resize do not trigger these correction snapshots.

This trades snapshot/history encoding and delivery on image content/placement changes for correct terminal state. It is bounded static image support, not an efficient animated-image or video transport. Full-history snapshot cost and temporary snapshot allocations remain material for image-heavy terminals with long histories.

Placement rows are relative to the live terminal top, not the viewer's viewport. The client resolves them using its current scroll offset and scales pixel dimensions from the scene's authoritative cell size. This preserves images above the active screen and permits independent client scrolling, including while older history is being prepended.

After an APC introducer, the service conservatively keeps the emulator resident until explicit terminal reset. This includes graphics queries and incomplete chunked uploads because the public API cannot expose all pending/inactive image state for serialization. Idle and explicit parking leave such terminals resident; reset allows parking again. Text-only terminals retain normal parking and have no extra terminal queries or periodic graphics timer. Service restart does not preserve image registries, just as it does not preserve live child processes.

## Resource limits

- Stored image payload: 8 MiB per primary/alternate screen, at most 1,024 image IDs per screen, including unplaced images. New IDs beyond the cap fail; replacing an existing ID remains possible.
- Pending image upload and decompressed payload: 8 MiB each. The decoder rejects larger PNG dimensions before allocating pixels, and dimensions are limited to Ghostty's 10,000-pixel maximum.
- APC parser buffer: 12 MiB. Continuation tracking rises from 1 MiB to 16 MiB only after APC traffic, and resets to 1 MiB on explicit reset.
- Active side-channel image blobs: 8 MiB; placement count: 1,024. Exceeding the placement limit clears both service image registries and emits an error event.
- Replay ring: 8 MiB including image payload/metadata. A single larger record invalidates old resume positions, which then receive an explicit resync and complete scene.
- Per-client outbound queue: 32 MiB including graphics data, plus one writer message in flight. Up to three full 8 MiB scenes can be queued because metadata is also charged. JSON/base64 serialization and decoding create additional bounded transient allocations, so these figures are not a total process-memory limit.

Three narrow resource patches apply to pinned Ghostty revision `27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c`: [ghostty-image-budget.patch](../patches/ghostty-image-budget.patch) changes `graphics_image.zig`'s pending/decode maximum from 400 MiB to 8 MiB; [ghostty-image-count.patch](../patches/ghostty-image-count.patch) caps new image IDs at 1,024 in `graphics_storage.zig`; [ghostty-static-images.patch](../patches/ghostty-static-images.patch) rejects animation actions in `graphics_exec.zig` before mutation.

[apply-ghostty-patches.sh](../scripts/apply-ghostty-patches.sh) is idempotent and accepts only these original or patched SHA-256 fingerprints:

| File | Original | Patched |
| --- | --- | --- |
| `graphics_image.zig` | `4cbefd0e7122b6c378c4ac5d65ad16014f38a74f528cd958311b10757f3e2903` | `bd15764dbf9dfcc74cf603b4b90aeedc397109eee8773a644bf00d16ffc072cf` |
| `graphics_storage.zig` | `a2c29c02531f00b939485a9e45eeb8198d55648f116282c31e37bed84677328d` | `4367af0d6005f50024da9591e0d1fcc2348828d44299404b6675ead9765356aa` |
| `graphics_exec.zig` | `617587c5edd81699029ae726436abf01a2852ed06598fea8ad4456a1bb99e8e2` | `7f3f533e5db4c71a58e45dfc4b8c4fa77b4f5ddafa6e4e60a0d030af461c30a4` |

Bootstrap applies all three before rebuilding the shared native/Go static library. The Nix derivation lists the same patches. The macOS bootstrap explicitly targets `aarch64-macos.15.0`. These component limits do not establish a total process-memory bound.

## Verification

Before patching, the focused regression reproduced a pending upload growing past 8 MiB without an error, and a compressed payload inflating past 8 MiB. With the rebuilt library both reject at the intended boundary.

`PKG_CONFIG_PATH="$PWD/.build/ghostty/share/pkgconfig" go -C service test -race ./internal/mux -run '^TestGraphics' -count=1` covers real PTY RGB/RGBA/PNG output, offscreen positions, physical cell resize, alternate-screen isolation, deletion, ordered reconnect replay, complete snapshot reconstruction, image retention during parking, reset restoring parking, malformed and oversized PNGs, metadata/payload queue charging, placement exhaustion, and upload/inflate bounds. A real child also pauses mid-APC at 2 MiB, reconnects successfully, completes a full 8 MiB image, and transmits the roughly 11 MiB JSON/base64 scene over a Unix socket intact.

All fixtures use private service sockets and real disposable subprocesses. No daily-driver daemon or user session is restarted. Rendering correctness is separately covered by native graphics tests.

`TestGraphicsPlacementCorrectsLiveTextAndForcesReplayBoundary` reproduces live text after transmit-and-display and after a later placement referencing an existing image. An image-disabled replica receives corrections and matches authoritative text and cursor row, while ordinary subsequent text produces no correction snapshot. A client that missed the image boundary receives resync and a complete snapshot.

`TestGraphicsUnplacedImageMetadataBudget` reproduced 1,025 unique unplaced 1x1 RGB images using just 3,075 pixel bytes before the guard. The patched library retains the first 1,024, rejects the next ID, and still permits replacing an existing image.

`TestGraphicsRejectsUnsupportedAnimationWithoutMutation` reproduced an accepted frame upload before the policy patch. The patched library rejects frame upload, playback controls and frame composition with ENOTSUP, preserves the canonical generation and pixels, and suppresses the response under quiet mode.

The final complete Go race suite, linked against all three patches with macOS 15 CGO flags, passed: CLI 2.961 seconds and mux 12.496 seconds. The rebuilt shared library SHA-256 is `1b695ab0848e0524ccc88daea6c5cae4819bac39b9250abd9bf911e9118b8344`. Its bootstrap target is explicitly `aarch64-macos.15.0`; this is build-target verification, not an execution test on a macOS 15 machine.
