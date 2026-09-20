# Superlogical research for illogical

Research date: 20 September 2026. Target: a native macOS implementation that closely reproduces the publicly demonstrated Superlogical multiplexer experience.

The strongest finding is that this is a persistent terminal system with native clients, not simply a terminal window with tabs. The demonstrations combine server-owned processes, independent client scrolling, native layouts, remote login, session navigation, and a substantial automation API. A faithful implementation needs that foundation as well as the appearance.

## Read the research

- [Feature inventory](FEATURES.md): observed behavior, supporting sources, and gaps.
- [Architecture](ARCHITECTURE.md): the described system, public Ghostty implementation evidence, and proposed boundaries for illogical.
- [Visual reference](VISUAL_REFERENCE.md): selected frames and interaction details.
- [Caption links and timestamped narration notes](TRANSCRIPT_NOTES.md): original X caption files and feature explanations from all six narrated previews.
- [Implementation and acceptance plan](BUILD_PLAN.md): a sequence for reproducing the demonstrated behavior.
- [Feature parity audit](../../docs/feature-parity.md): implementation evidence, executed checks, and known missing or partial behavior. This is the current acceptance status.
- [Source index](SOURCES.md): all 16 collected video posts, additional primary sources, and research method.
- [Developer reply research](REPLIES-architecture.md): architecture, persistence and remote details; companion notes cover [interface behavior](REPLIES-interface.md) and [copy and migration](REPLIES-copy-migration.md).
- [Machine-readable source manifest](sources.json): dates, durations, dimensions, hashes, and frame paths.

## Coverage

The corpus contains 16 X video files from 20 July through 19 September 2026: six narrated videos totaling **42 minutes 33 seconds**, and ten files with no audio stream. The two 12 August tab-peek posts show substantially the same demonstration; the count is not 16 independent feature demonstrations. There are **67 sampled video frames and two contrast comparison images** in this folder.

A follow-up audit found a seventeenth preview about copy feedback, plus an explicit developer confirmation of a copy-on-selection option. Those sources are indexed in [SOURCES.md](SOURCES.md). They are outside the downloaded corpus, and the new video still needs complete visual review.

A dedicated reply review covered relevant loaded conversations across all 17 video root posts, plus the contrast and copy follow-ups. It pairs questions with developer answers and separates current capabilities, plans, and unanswered requests. Additions include Reduce Motion, independent pane searches, optional synchronized viewports, outage replay, NixOS deployment, and multiplayer sessions. This is bounded coverage of the inspected conversations, not an exhaustive archive of every X reply.

The signed-in X interface was used to inspect Superlogical's reposts, original posts from Mitchell Hashimoto and Alasdair Monk, associated replies, and relevant posts by Jack Pearkes. The company site, Mitchell's announcement, and public Ghostty source were also inspected. This is a substantial public-evidence baseline, not a claim to have found every deleted post, private build, or undisclosed feature.

## Evidence labels

- **Observed**: visible behavior or interface in a preview. A recording demonstrates one case, not a complete reliability guarantee.
- **Stated**: an explicit explanation or claim by a developer. Performance claims remain unbenchmarked here.
- **Upstream**: behavior found in public Ghostty code. This is not access to Superlogical's private implementation.
- **Proposed**: an engineering choice for illogical, chosen to reproduce the evidence.
- **Unknown**: the public material does not establish the answer.

Recordings are prototypes from different dates. Where they disagree, later evidence takes precedence, while older gestures remain candidates until superseded. Exact palette values, layout dimensions, animations, transport schemas, authentication rules, and compatibility promises cannot all be recovered from videos.

## Product boundary

The public company vision extends from multiplexing into composable tools and production operations. That vision is broader than the working terminal features demonstrated so far. The September remote video explicitly calls the multiplexer **Rex**, and the demonstrated command is `rex`. This research uses “Superlogical” for the source product and `illogical` for our implementation; it does not assume the final public product name.

The repository was a SwiftUI “Hello, world!” starter at the beginning of this research. It now contains the native client, persistent service, CLI, streamed terminal state, and local and remote transports described in the [project README](../../README.md). The research remains the evidence and acceptance baseline; implementation does not by itself establish exact feature or visual parity.
