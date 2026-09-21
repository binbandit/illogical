# Releases

`.github/workflows/release.yml` builds everything a user downloads: the macOS
application and the Linux service archives. It runs on every push to `main`,
on `v*` tags, on manual dispatch, and on pull requests that touch the packaging
scripts, the pinned Ghostty patches, or the workflow itself.

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

Merging to `main` releases automatically. `scripts/next-version.sh` reads the
[Conventional Commits](https://www.conventionalcommits.org/) since the last `v*`
tag and picks the bump:

| Commits since the last tag | Bump | Example |
| --- | --- | --- |
| A `!` after the type, or a `BREAKING CHANGE:` footer | major | `feat(service)!: drop the v1 socket protocol` |
| `feat` | minor | `feat(workspace): add session rename` |
| `fix`, `perf`, `revert` | patch | `fix(render): keep the cursor on resize` |
| Anything else (`docs`, `build`, `ci`, `chore`, `refactor`, `test`) | none | no release |

The highest bump wins; with no tag yet the whole history counts and the base is
`0.0.0`. When there is a bump the workflow builds each platform, tags the
commit `vVERSION`, and publishes the release with the artifacts, the download
instructions, and generated commit notes. When there is none the build jobs are
skipped and the push costs a few seconds. Runs on `main` queue rather than
cancel each other, so each one sees the tag the previous one created. Squash
merges take their subject from the pull request title, so word the title as
the commit you want analyzed.

Pushing a tag by hand (`git tag v0.2.0 && git push origin v0.2.0`) releases
exactly that version the same way, for a release the commit messages would not
produce. `workflow_dispatch` takes a `version` for the artifact names and a
`publish` switch that opens a **draft** release instead; with `publish` off it
only uploads workflow artifacts, which is the way to rehearse packaging without
touching the releases page.

Released builds set `MARKETING_VERSION` from the leading dotted number in the
version and `CURRENT_PROJECT_VERSION` from the run number, so the installed
bundle reports the released version.

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

The app ships for Apple Silicon only, which is the supported platform; the
build pins `ARCHS=arm64` so a Release configuration never adds the x86_64 slice
the pinned terminal library cannot link. The workflow does not run
`scripts/test.sh`, which needs a Metal device and real pseudo-terminals, so
releases carry whatever was validated on the maintainer's machine. Linux
artifacts are built on the GitHub-hosted `ubuntu-22.04` and `ubuntu-22.04-arm`
runners; an Arm runner is available because this repository is public.
