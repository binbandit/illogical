# Third-party notices

illogical includes the components below. Their original license and attribution texts are retained with the application. These notices describe third-party components and do not assign license terms to illogical itself.

| Component | Revision / version | License | Included text |
| --- | --- | --- | --- |
| [Ghostty / libghostty-vt](https://github.com/ghostty-org/ghostty) | 27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c | MIT | [Ghostty-LICENSE.txt](Ghostty-LICENSE.txt) |
| [Go libghostty bindings](https://tangled.org/mitchellh.com/go-libghostty) | 7c854ef33a99b35aff75b21bbcb4c215c60dd019 | MIT | [libghostty-go-LICENSE.txt](libghostty-go-LICENSE.txt) |
| [creack/pty](https://github.com/creack/pty) | 1.1.24 | MIT | [creack-pty-LICENSE.txt](creack-pty-LICENSE.txt) |
| [quic-go](https://github.com/quic-go/quic-go) | 0.62.0 | MIT | [quic-go-LICENSE.txt](quic-go-LICENSE.txt) |
| [Go runtime and standard library](https://go.dev) | 1.27.1 | BSD 3-Clause | [Go-LICENSE.txt](Go-LICENSE.txt) |
| [golang.org/x/crypto](https://go.googlesource.com/crypto) | v0.54.0 | BSD 3-Clause; patent grant | [golang-x-crypto-LICENSE.txt](golang-x-crypto-LICENSE.txt), [golang-x-crypto-PATENTS.txt](golang-x-crypto-PATENTS.txt) |
| [golang.org/x/net](https://go.googlesource.com/net) | v0.56.0 | BSD 3-Clause; patent grant | [golang-x-net-LICENSE.txt](golang-x-net-LICENSE.txt), [golang-x-net-PATENTS.txt](golang-x-net-PATENTS.txt) |
| [golang.org/x/sys](https://go.googlesource.com/sys) | v0.48.0 | BSD 3-Clause; patent grant | [golang-x-sys-LICENSE.txt](golang-x-sys-LICENSE.txt), [golang-x-sys-PATENTS.txt](golang-x-sys-PATENTS.txt) |
| [Zig standard library and compiler runtime](https://ziglang.org) | 0.16.0 | MIT | [Zig-LICENSE.txt](Zig-LICENSE.txt) |
| [uucode / Unicode / Hoehrmann material](https://github.com/jacobsandlund/uucode) | 9d55524551411b493cca41ca06363625d90aff1e | MIT; Unicode License v3 | [uucode-LICENSE.md](uucode-LICENSE.md), [uucode-Bjoern-Hoehrmann-LICENSE.txt](uucode-Bjoern-Hoehrmann-LICENSE.txt), [uucode-Unicode-LICENSE.txt](uucode-Unicode-LICENSE.txt) |
| [simdutf](https://github.com/simdutf/simdutf) | 9.0.0 (bundled header version) | MIT / Apache 2.0; BSD attribution | [simdutf-LICENSE-MIT.txt](simdutf-LICENSE-MIT.txt), [simdutf-LICENSE-APACHE.txt](simdutf-LICENSE-APACHE.txt), [simdutf-isadetection-NOTICE.txt](simdutf-isadetection-NOTICE.txt) |
| [Google Highway](https://github.com/google/highway) | 66486a10623fa0d72fe91260f96c892e41aceb06 | Apache 2.0 / BSD 3-Clause | [Highway-LICENSE-APACHE.txt](Highway-LICENSE-APACHE.txt), [Highway-LICENSE-BSD3.txt](Highway-LICENSE-BSD3.txt) |
| [Wuffs](https://github.com/google/wuffs) | 7411f488fe2e2c205c3d3b3d28638b7356522930 | MIT / Apache 2.0 | [Wuffs-LICENSE.txt](Wuffs-LICENSE.txt) |
| [Nerd Fonts patching and symbols](https://github.com/ryanoasis/nerd-fonts) | font from pinned Ghostty revision | SIL OFL 1.1; MIT for tooling | [Nerd-Fonts-LICENSE.md](Nerd-Fonts-LICENSE.md) |

The bundled JetBrains Mono Nerd Font is copied unchanged from the pinned Ghostty source. Its [SIL OFL text](../Fonts/JetBrainsMono-OFL.txt) and [font notice](../Fonts/NOTICE.txt) remain alongside the font.

Ghostty supplies uucode, simdutf, Highway, and Wuffs to the statically linked terminal library. Go module revisions are recorded in `service/go.mod` and `service/go.sum`. The native application uses macOS system frameworks, including AppKit, SwiftUI, CoreText, and Metal.

License texts were copied from the installed dependency source trees. The pinned uucode source archive supplies its additional licenses omitted from its Zig package. The simdutf v9.0.0 source archive supplies upstream licenses for the amalgamated header shipped by Ghostty; that header identifies itself as 9.0.0. Its embedded isadetection attribution is retained separately.

[Source locations and checksums](SOURCES.txt) record each retained notice. Relative links inside an original upstream license refer to that upstream repository.
