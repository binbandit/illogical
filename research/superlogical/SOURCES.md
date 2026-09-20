# Sources and research method

Retrieved 20 September 2026. Dates below are UTC dates from the source metadata. X displayed in Melbourne can show the following calendar day.

## Video corpus

| ID | UTC date | Source | Length | Audio and notes |
|---|---|---|---|---|
| V01 | 2026-07-20 | [Early UI preview](https://x.com/mitchellh/status/2079327969416482859) | 0:22 | No audio stream |
| V02 | 2026-07-30 | [Architecture explanation](https://x.com/mitchellh/status/2082936029426892960) | 10:40 | Narration; X captions; [timestamped notes](TRANSCRIPT_NOTES.md) |
| V03 | 2026-08-04 | [Deck and process icons](https://x.com/almonk/status/2084549282120511575) | 0:27 | No audio stream |
| V04 | 2026-08-12 | [Session and tab management](https://x.com/almonk/status/2087533118429294920) | 3:29 | Narration; X captions; [timestamped notes](TRANSCRIPT_NOTES.md) |
| V05 | 2026-08-12 | [Tab peek, Alasdair post](https://x.com/almonk/status/2087535957100613892) | 0:14 | No audio stream; substantially the same peek demo |
| V06 | 2026-08-12 | [Tab peek, Mitchell post](https://x.com/mitchellh/status/2087537750182666290) | 0:14 | No audio stream; substantially the same peek demo |
| V07 | 2026-08-14 | [Theme collection](https://x.com/almonk/status/2088311080476872898) | 0:28 | No audio stream |
| V08 | 2026-08-27 | [Vertical tabs](https://x.com/almonk/status/2092908172381982782) | 0:15 | No audio stream |
| V09 | 2026-08-28 | [Basic terminal and persistence demo](https://x.com/mitchellh/status/2093451043661316217) | 2:53 | Narration; X captions; [timestamped notes](TRANSCRIPT_NOTES.md) |
| V10 | 2026-09-02 | [Scrollback search](https://x.com/almonk/status/2095134190631096428) | 0:10 | No audio stream |
| V11 | 2026-09-02 | [Memory use and parking](https://x.com/mitchellh/status/2095232081853039041) | 11:43 | Narration; X captions; [timestamped notes](TRANSCRIPT_NOTES.md) |
| V12 | 2026-09-08 | [Remote persistent sessions](https://x.com/mitchellh/status/2097424868203758046) | 6:16 | Narration; X captions; [timestamped notes](TRANSCRIPT_NOTES.md) |
| V13 | 2026-09-08 | [Appearance and density](https://x.com/almonk/status/2097439320076403125) | 0:31 | No audio stream |
| V14 | 2026-09-14 | [CLI and block API](https://x.com/mitchellh/status/2099622049325232505) | 7:31 | Narration; X captions; [timestamped notes](TRANSCRIPT_NOTES.md) |
| V15 | 2026-09-15 | [2048 through the CLI](https://x.com/mitchellh/status/2099915915056074807) | 0:51 | No audio stream |
| V16 | 2026-09-19 | [Ghostty theme migration](https://x.com/almonk/status/2101298597811679433) | 0:11 | No audio stream |

Six narrated videos total 2,553.147 seconds, approximately 42:33. Individual durations above are rounded. Ten other files have no audio stream, verified with media inspection. Captions are therefore not missing speech from those silent clips.

### Follow-up audit discovery

The 20 September parity audit found one additional preview beyond the downloaded corpus:

| ID | UTC date | Source | Review status |
|---|---|---|---|
| V17 | 2026-09-19 | [Feedback when copying terminal selections](https://x.com/almonk/status/2101298258706362515) | X displays a 17-second video. Read the post and replies; playback and selected frames were inspected after a temporary Mac lock. Exact effect/timing remains unverified. No audio/caption classification, downloaded media, hash, or repository frame evidence is claimed. |

The original 16-file manifest remains the downloaded research corpus. V17 is a newly discovered source, not a fully analyzed seventeenth recording.

## Other primary sources

| ID | Source | Contribution |
|---|---|---|
| S01 | [Official company site](https://www.superlogical.com/) | Company vision, durable local/remote sessions, native/web clients, future composable tools and operations. |
| G01 | [Mitchell’s announcement](https://mitchellh.com/writing/superlogical) | Relationship to Ghostty and publicly available MIT-licensed components. |
| G02 | [Ghostty public source](https://github.com/ghostty-org/ghostty) | Public terminal implementation; inspected revision recorded below. |
| G03 | [Snapshot C API](https://github.com/ghostty-org/ghostty/blob/27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c/include/ghostty/vt/snapshot.h) | Snapshot encoding, restoration, readiness, deferred history, concurrency requirements. |
| G04 | [Snapshot implementation](https://github.com/ghostty-org/ghostty/blob/27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c/src/terminal/snapshot/main.zig) | Versioned record stream and state serialization. |
| G05 | [C snapshot example](https://github.com/ghostty-org/ghostty/tree/27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c/example/c-vt-snapshot) | Public integration example. |
| P01 | [Implementation languages](https://x.com/mitchellh/status/2082623830510710865) | Go server/networking, Swift Apple apps, Zig low-level bindings. |
| P02 | [SSH hiring experience](https://x.com/pearkes/status/2085831422703776119) | Uses charmbracelet/wish for the hiring experience. This is not evidence that the multiplexer server uses that framework. |
| P03 | [Automatic contrast correction](https://x.com/almonk/status/2100659108697305577) | Runtime color correction explanation and before/after images. |
| P04 | [Internal iOS app](https://x.com/pearkes/status/2099971013425381401) | Author says an internal iOS client is in use; no iOS walkthrough reviewed. |
| P05 | [SSH and direct login](https://x.com/mitchellh/status/2097430395667271799) | Author describes SSH transport or direct PAM-respecting authenticated/authorized login. |
| P06 | [QUIC and fallback](https://x.com/mitchellh/status/2097431305168605319) | Affirmative reply to QUIC question, with fallback protocols. Parent question was inspected. |
| P07 | [Tailscale registration](https://x.com/mitchellh/status/2093565819909542332) | Integrated per-server Tailscale node registration, or manual connectivity. |
| P08 | [Tailscale discovery](https://x.com/mitchellh/status/2082634453474795885) | Automatic service registration and client discovery described as intended integration. |
| P09 | [New-session host selection](https://x.com/mitchellh/status/2097525970593021973) | Picker creates on the host of the currently focused session for that window. |
| P10 | [Custom bidirectional protocol](https://x.com/mitchellh/status/2089399515740819484) | Author describes a custom bidirectional data protocol; full protocol not published. |
| P11 | [Copy-feedback rationale](https://x.com/almonk/status/2101307051087430097) | Author describes feedback as confirmation that copying worked, including on remote terminals. |
| P12 | [Copy-on-selection option](https://x.com/almonk/status/2101342381635235882) | Affirmative reply to the [explicit auto-copy question](https://x.com/hamedhsn/status/2101312512171921696), both read in the V17 thread. |
| P13 | [Pane density remains configurable](https://x.com/almonk/status/2101301158799093915) | Reply confirms that the earlier separated pane treatment remains a setting. Read in the V17 thread. |

The parity audit also re-read the official site and announcement and checked the signed-in X Latest search for posts from Mitchell Hashimoto, Alasdair Monk, and Superlogical since 19 September. This found V17; it does not prove exhaustive coverage of all public or unpublished work.

The subsequent reply audit reads developer answers together with their parent questions across relevant loaded conversations on all 17 video root posts, plus the contrast and copy follow-ups. See [architecture and remote replies](REPLIES-architecture.md), [interface replies](REPLIES-interface.md), and [copy and migration replies](REPLIES-copy-migration.md). These documents record new requirements, explicit limitations, and unanswered requests separately. Important additions are T08, R10-R12, A11 and A12 in the feature inventory. They also clarify existing keyboard access, filter-match emphasis, theme-only migration, and mobile client-local reflow. Kubernetes, floating panels and a notification inbox remain plans/design work rather than confirmed completed features.

## Method and limits

1. Used the signed-in X interface to inspect the company’s reposts and developers’ original posts/replies. Searched relevant author timelines and followed source threads. Read the official site and announcement.
2. Collected the publicly available video files and their metadata into a temporary analysis cache. No account cookies were exported to the media downloader.
3. Retrieved available English X caption tracks for all six narrated videos. Preserved their cue timing for analysis. These tracks contain recognition errors; they are not authoritative spellings of API names.
4. Ran supplementary local `mlx-community/whisper-turbo` transcription on the architecture and session-management clips. This helped recover a roughly 30-second gap around 1:22-1:52 in the session-management X captions. It is still unverified machine output.
5. Discarded 13 local-ASR segments beginning after the measured session-management video ended; they were spurious repeated closing words. Clipped any remaining ASR cue overruns to media duration. No product claims rely on that tail.
6. Extracted selected timestamped frames, usually scaled to 1,600 pixels wide, and inspected individual frames/contact sheets. Original video dimensions remain in `sources.json`. Two contrast images come directly from P03.
7. Cross-checked architecture claims against the public Ghostty snapshot header and implementation at commit `27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c`.

The repository contains original research summaries, timestamped paraphrases, a source manifest, and selected reference images. Full third-party caption tracks, automatic transcriptions, and video files were used as temporary analysis inputs rather than reproduced as repository documents. Original posts remain the source of truth for the complete narration.

## Artifact provenance

- `sources.json` identifies each source video, original post, media hash, caption hash when present, and derived frame paths. Extractor descriptions may be truncated; findings use the original posts and videos.
- A frame named `VIDEO_ID-SECONDS.jpg` samples that offset from the corresponding video. It is a visual reference, not an exact measurement in macOS points.
- `frames/contrast-off.jpg`: first image in P03, marked “Acc off” by the author. Source media: `https://pbs.twimg.com/media/HScI8d0W4AAaIkn?format=jpg&name=medium`.
- `frames/contrast-on.jpg`: second image in P03, marked “Acc on” by the author. Source media: `https://pbs.twimg.com/media/HScI9EmXoAEz8oB?format=jpg&name=medium`.
- The corpus includes prototype changes over time. A menu being visible proves that label existed in that build; it does not prove every backing implementation was complete.

## Reacquiring a source

For a source that remains public, a standard media downloader such as yt-dlp can retrieve its metadata, media, and available English subtitle tracks using the canonical post URL in the manifest. Media manifests and CDN URLs may expire, so preserve canonical post IDs rather than relying on a cached stream URL. Compare hashes only when using the same media variant.

Research was read-only on X: no replies, direct messages, likes, follows, or account settings were changed.
