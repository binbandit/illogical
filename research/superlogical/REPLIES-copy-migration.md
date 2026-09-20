# Copy, migration, and early-preview reply audit

Read on 20 September 2026 through the signed-in X interface. This review covered
V01, V05, V16, V17, and the V17 follow-up explanation. Developer answers were read
alongside their parent questions, including expanded replies. This is a bounded
review of the loaded conversations, not a claim that X exposed every reply.
No messages, reactions, account settings, or other social actions were submitted.

## Confirmed behavior and limits

| Source pair | What the developer establishes | Consequence for illogical |
| --- | --- | --- |
| [Copy-on-selection question](https://x.com/hamedhsn/status/2101312512171921696) and [Alasdair's answer](https://x.com/almonk/status/2101342381635235882) | An auto-copy selection option exists. The answer does not establish its default or precise timing. | A10 is missing: selection release does not copy and no preference exists. This is additional behavior beyond ordinary Cmd-C. |
| [Earlier pane treatment question](https://x.com/evkaky/status/2101300581780406280) and [Alasdair's answer](https://x.com/almonk/status/2101301158799093915) | The separated pane appearance remains available through a setting. It was not simply removed by the later compact design. | Retain both Comfortable and Compact acceptance cases, A04. Do not copy only the latest screenshot's density. |
| [Keybinding import question](https://x.com/mikker/status/2101352161367966057) and [Alasdair's answer](https://x.com/almonk/status/2101356033000050922) | Keybindings are not imported at that revision; migration currently covers themes and theme-related configuration. | A08 should be tested against that narrower contract. Missing full Ghostty keybinding migration is not evidence of falling behind this preview. Exact coverage of every theme-related field is still unknown. |
| [Why copy feedback will become less necessary](https://x.com/sudomateo/status/2101354122645549105) and [Alasdair's explanation](https://x.com/almonk/status/2101400341203877966) | Predictable behavior across local and remote hosts is a product goal. The [follow-up question](https://x.com/sudomateo/status/2101403662236942402) and [affirmation](https://x.com/almonk/status/2101407646247006244) attribute that behavior to the Rex server. | R09 needs an actual cross-host clipboard acceptance case. This does not establish image clipboard support, every clipboard format, or arbitrary remote clipboard reads. |
| [V17](https://x.com/almonk/status/2101298258706362515) and [copy-feedback explanation](https://x.com/almonk/status/2101307051087430097) | The video demonstrates an experiment in visual reassurance after copying selected terminal text. Playback and selected frames show text selection within a split terminal, including a selected domain and larger text regions. | A09 is missing. Exact animation geometry, duration and trigger semantics need deliberate visual acceptance; they are not recovered from comments alone. |
| [Synchronized-rendering question](https://x.com/bcomnes/status/2079332932523839826) and [Mitchell's answer](https://x.com/mitchellh/status/2079333481306550772) | The reported Ghostty flashing is attributed to a TUI drawing without synchronized rendering. This is an explanation of tearing, not a claim that every program is automatically synchronized. | Preserve the synchronized-output tests and bounded timeout. Do not promise to eliminate every application's intermediate drawing without its participation. |
| [Split-library question](https://x.com/wiedymi/status/2079609596323446896) and [Mitchell's answer](https://x.com/mitchellh/status/2079610247338197018) | The early native prototype used the split-pane library he had previously shared. This reply does not name a version or establish an internal implementation contract. | Supports the native split-layout architecture; no source-level compatibility or exact dependency is inferred. |
| [Early sessions confirmation](https://x.com/mitchellh/status/2079546027640770608), within [V01](https://x.com/mitchellh/status/2079327969416482859) | Sessions were present in the early prototype. | Reinforces N01, already established more fully by V04. |

## What these conversations do not establish

Questions about multiline-copy newline behavior, copy-effect delay, vi selection,
release access, and image clipboard behavior do not become requirements simply
because someone asked. No matching developer answer was found in the reviewed
copy thread for those details. Ordinary selection, auto-copy, and feedback are
three different acceptance cases.

The [companion peek post, V05](https://x.com/almonk/status/2087535957100613892)
links the longer session video and contains general native-app design discussion.
Its reviewed questions about Windows server support, keyboard navigation and
compact tabs did not have feature-confirming developer answers there. The V06
thread separately confirms non-gesture activation and Reduce Motion; see the
[interface reply audit](REPLIES-interface.md).

The initial V17 playback was interrupted by a locked Mac. Browser playback and
selected frames were subsequently inspected after access returned. The video is
not added to the original downloaded 16-file manifest, and no audio/caption or
hash claim is made for it.
