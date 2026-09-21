# Releases

`.github/workflows/release.yml` builds everything a user downloads: the macOS
application and the Linux service archives. It runs on `v*` tags, on manual
dispatch, and on pull requests that touch the packaging scripts, the pinned
Ghostty patches, or the workflow itself.

## Artifacts

| File | Contents |
| --- | --- |
| `illogical-VERSION-macos-arm64.dmg` | The app for Apple Silicon, macOS 15 or later, with an Applications shortcut |
| `illogical-VERSION-macos-arm64.zip` | The same bundle for scripted installs |
| `illogical-service-VERSION-linux-x86_64.tar.gz` | Linux service and CLI, glibc 2.34 or newer |
| `illogical-service-VERSION-linux-aarch64.tar.gz` | The same for 64-bit Arm |
| `SHA256SUMS` | Checksums, written by the release job |

Both macOS archives carry the app and its bundled `illogical` CLI at
`Contents/Resources/bin/illogical`. The Linux archives carry `bin/illogical` and
the compile-closure license texts; they do not carry the setuid PAM login
helper, which the flake's `login-helper` package and the NixOS module install.

## Cutting a release

Push a tag: `git tag v0.2.0 && git push origin v0.2.0`. The workflow builds each
platform, then opens a **draft** release with the artifacts, the download
instructions, and generated commit notes. Review the draft and publish it.

`workflow_dispatch` takes a `version` for the artifact names and a `publish`
switch. With `publish` off it only uploads workflow artifacts, which is the way
to rehearse packaging without touching the releases page.

Tagged builds set `MARKETING_VERSION` from the leading dotted number in the tag
and `CURRENT_PROJECT_VERSION` from the run number, so the installed bundle
reports the released version.

## Signing and notarization

Without secrets the macOS build is ad-hoc signed, exactly like `just install`
produces locally, and Gatekeeper treats it as an unidentified developer. Adding
these repository secrets switches the packaging script to a Developer ID
signature with the hardened runtime and a secure timestamp, notarizes the zip
and the disk image, and staples both:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64 of the Developer ID Application `.p12` export |
| `MACOS_CERTIFICATE_PASSWORD` | Password for that export |
| `MACOS_SIGNING_IDENTITY` | Identity name, for example `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` | Apple account used for notarization |
| `APPLE_TEAM_ID` | Team identifier |
| `APPLE_APP_PASSWORD` | App-specific password for that account |

The certificate is imported into a throwaway keychain in `RUNNER_TEMP`.
Notarization runs only when the identity and all three notary values are set;
otherwise the run still produces installable ad-hoc artifacts.

## Building the same artifacts locally

```sh
just package        # macOS: Release build, then the dmg and zip
./scripts/package-linux.sh   # Linux: the service and CLI archive
```

Both write to `.build/release`. `ILLOGICAL_VERSION` overrides the version, which
otherwise comes from `git describe`. `scripts/bootstrap.sh` now builds the
pinned `libghostty-vt` for Apple Silicon macOS and for x86_64 and aarch64 Linux;
the Linux targets pin glibc 2.34 so the released binaries run on Ubuntu 22.04,
Debian 12, and RHEL 9.

## Known limits

Intel Macs are not built; the bootstrap has no matching Ghostty library for
them. The workflow does not run `scripts/test.sh`, which needs a Metal device
and real pseudo-terminals, so releases carry whatever was validated on the
maintainer's machine. Linux artifacts are built on the GitHub-hosted
`ubuntu-22.04` and `ubuntu-22.04-arm` runners; an Arm runner is available
because this repository is public.
