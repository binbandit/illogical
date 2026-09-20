# Remote service deployment

Remote support now includes ordinary CLI routing, SSH bootstrap with QUIC preference and SSH fallback, explicit embedded Tailscale listeners, and an opt-in Linux PAM helper. The macOS and loopback tests below are complete. No real external host, user tailnet, NixOS VM, or blocked-UDP WAN has been exercised.

## SSH and remote CLI

Install the CLI/service on the remote host. Its Unix account owns the service, socket, and terminals. Add and verify that host in normal OpenSSH configuration and `known_hosts` first. illogical uses strict host verification and batch authentication.

```sh
illogical --host work --remote-executable '~/.local/bin/illogical' ls
illogical --host work new build --cwd /home/me/project
illogical --host work send-key --block BLOCK_ID ctrl-c
```

Quote a remote `~/` executable path when invoking it from a shell, or pass its absolute remote path. An explicit remote target clears the caller's inherited local `ILLOGICAL_BLOCK`; pass the remote block ID explicitly. Remote and `--socket` targets cannot be combined. Requests and terminal bytes use the selected transport once, after bootstrap succeeds. A successful SSH probe obtains scoped QUIC credentials; failed UDP dialing falls back to an authenticated SSH relay before any request bytes have been forwarded.

Tests: `TestRemoteCLIRequestsUseAuthenticatedSSHFallback` starts a private service, a Go SSH server with a generated key, and real `/usr/bin/ssh` with a private known-hosts file. It creates a remote terminal, closes and reconnects, and verifies the same process survives. `TestSSHConnectionCloseUnblocksReadAndReapsProcess` checks transport cancellation. Fixtures do not use an external account.

## Embedded Tailscale

The local service does not enroll a node simply because the library is linked. This is activated only by `serve --tailscale-config /private/path/config.json`. Example configuration:

```json
{
  "hostname": "illogical-work",
  "stateDirectory": "/var/lib/illogical/me/tailscale",
  "authKeyFile": "/run/secrets/illogical-tailnet-key",
  "advertiseTags": ["tag:illogical-server"],
  "serviceName": "svc:illogical-work",
  "port": 7243,
  "allowedUsers": ["me@example.com"]
}
```

The auth-key file must be private (0600), and node state is stored in a 0700 directory. Keep secrets out of the Nix store. `allowedUsers` or `allowedTags` is required. Tagged devices must match an explicit allowed tag; they cannot inherit access from the tag creator's login name. WireGuard peer identity is checked with the Tailscale Local API before the service greeting. Tailscale clients cannot issue additional QUIC pairing credentials through this connection.

A registered Service requires a tagged node and the tailnet's service approval/ACL configuration. Omit `serviceName` for a plain embedded node listener and connect by that node's MagicDNS name or Tailscale IP. Service discovery intentionally returns only registered `svc:illogical-*` entries with a concrete TCP port:

```sh
illogical tailscale discover
illogical --host tailscale:illogical-work:7243 ls
```

The client requires a running local Tailscale daemon. It resolves destinations from that daemon's trusted peer/service map and uses Local API `DialTCP`; arbitrary public/LAN DNS destinations are rejected. Discovery does not enroll anything or enumerate every machine as an illogical server.

Tests cover admission, tagged identity behavior, malformed/oversized configuration, pairing denial, registered-service filtering, IPv6 and MagicDNS matching, and rejection of destinations absent from the network map. **Live node enrollment, service publication, tailnet ACLs, and WAN behavior remain unverified.** The integration uses [tsnet's official server API](https://tailscale.com/docs/reference/tsnet-server-api) and [service registration API](https://tailscale.com/docs/features/tsnet/how-to/register-service).

## Linux login sessions

PAM is opt-in through `serve --login-helper /run/wrappers/bin/illogical-login`. This applies before persisted terminals are restored. The service remains unprivileged. An administrator installs the separately compiled helper as a root-owned setuid executable in protected directories.

The helper selects the account using the caller's immutable real UID, accepts no target username, rejects a root caller and a terminal owned by another user, uses fixed PAM service `illogical`, validates account policy, establishes credentials, opens a real PAM session, drops all real/effective/saved UID/GID values to the caller for the child, and closes the PAM session on exit. The privileged stage clears inherited environment hooks. Identity values come from the system account database. The helper does not invent `XDG_SESSION_ID`, utmp entries, logind metadata, or a remote identity. The configured PAM stack supplies supported platform session integration.

SSH authentication or the service's explicit tailnet admission authorizes access to this per-user service. PAM account/session hooks run for that same user; there is no password RPC or cross-user login broker. The helper needs a system-specific PAM policy. The NixOS module enables its account/session policy through `security.pam.services.illogical` and `startSession`/`setLoginUid`.

`tests/login_pam_fixture.py`, run only inside a disposable Linux container by `scripts/test-login-linux.sh`, exercises real Linux libpam: session open/close, same-UID execution, identity/environment sanitization, account denial, Ctrl+C cleanup, a real `pam_unix`/`pam_loginuid` policy with the expected audit login UID, enforced `pam_limits` file limits, foreign-owned PTY rejection, and SIGTERM delivered during a deliberately delayed PAM open hook. It does not test systemd-logind or a real machine's production PAM policy. `TestLoginCommandIsExplicitAndPreservesArgumentBoundaries` and `TestLoginHelperRejectsUntrustedOrUnsupportedPath` verify the Go integration. No helper or PAM policy was installed on the macOS host.

## NixOS

The root flake pins Ghostty's exact revision and its nixpkgs graph, builds the service against `libghostty-vt`, and exports a NixOS module. Go 1.27.1 source is pinned by its upstream checksum. The vendored module NAR hash was generated with actual Nix from `go mod vendor`. An example host configuration:

```nix
{
  imports = [ illogical.nixosModules.default ];
  services.illogical = {
    enable = true;
    package = illogical.packages.${pkgs.system}.illogical;
    pamLogin = true; # Explicit installation of the privileged same-UID helper.
    users.me = {
      # The existing normal Unix account owns this independent service.
      tailscaleConfig = null; # Or a private runtime JSON config path.
    };
  };
}
```

Each configured account gets a system service, a private `$HOME/.local/share/illogical` directory matching ordinary CLI/SSH lookup, and a 0600 socket. It is independent of an SSH client's lifetime. Restarting the service still terminates its processes; GUI/CLI disconnects do not. Existing processes are not silently migrated into this deployment. If changing `stateDirectory`, provision a user-writable parent and configure the same `ILLOGICAL_HOME` for SSH/CLI invocations. For NixOS use remote executable `/run/current-system/sw/bin/illogical`.

`nix build .#illogical` builds the Linux CLI/service. `nix build .#checks.aarch64-linux.linux-login` (or x86_64-linux) builds the VM regression for per-user deployment, PAM, private socket and client-disconnect persistence. Package and VM derivations were evaluated with real Nix in an isolated Linux container. Both service and helper packages built successfully under real Nix, and the service package CLI tests passed. The compiled service plus compiled Nix/PAM helper then passed a container end-to-end test: same process after CLI disconnect/reconnect, correct foreground UID, real PAM audit identity and file limit, protocol Ctrl+C exit 130, 0600 socket and 0700 state. No full NixOS VM was started.

## Default resource impact

Measured before/after linking tsnet with Tailscale disabled, same Mac on AC:

| Metric | Before | After |
| --- | ---: | ---: |
| Helper bytes | 17,098,994 | 37,193,538 |
| Median socket-greeting startup, 12 isolated service runs | 6.96 ms | 8.40 ms |
| First launch in that sequence | 450.81 ms | 475.49 ms |
| Empty-service footprint, final 10-second sample | 4.90 MB | 5.83 MB |
| Idle CPU time during 10 seconds | 0 | 0.054 ms |
| Idle interrupt wake counter delta | 0 | 5 |
| Idle disk writes | 0 | 0 |

These are process counters and service startup measurements, not native app cold-cache timing or battery-life estimates. First-launch code-signing/cache effects were not controlled; nearby service edits make the comparison observational rather than a library-only laboratory attribution. Raw data: `.build/resource-efficiency/tsnet-default-impact.json`. Added compile-closure licenses: `illogical/Resources/Licenses/GoModules/GoModules-INDEX.md`, generated by `scripts/collect-go-notices.py`.

Focused test log: `.build/remote-focused-tests.txt`. Linux PAM log: `.build/linux-remote/login-pam-tests.json`. Nix lock/evaluation logs: `.build/linux-remote/nix-lock.log`, `nix-package-eval.log`, and `nix-vm-eval.log`.

Final build/acceptance logs: `.build/linux-remote/nix-build-final.log`, `nix-login-helper-build.log`, `nix-service-checks.log`, `login-service-nix-tests.json`, and `component-hashes.txt`. The maintained full-service fixture is `tests/login_service_fixture.py`. Nix’s PAM library expects `/run/wrappers/bin/unix_chkpwd`; the disposable container supplied this standard NixOS runtime helper for the test. The full Linux distribution policy, logind and utmp remain outside that fixture. Linux Go compile-closure notices are in `deploy/linux/licenses` (39 modules); the macOS bundle retains its own 35-module closure.

The final Linux build also applies the maintained `patches/ghostty-image-budget.patch` and includes the bounded/cancellable SSH probe and relay-child cleanup. This required updating the vendor NAR hash for the newly imported PNG binding. Final logs are `.build/linux-remote/nix-build-patched-final.log`, `nix-service-patched-checks.log`, `login-service-nix-patched-tests.json`, and `component-patched-hashes.txt`. The complete CLI race suite including remote cancellation/64-KiB probe bounds passes in `.build/remote-cli-final-tests.txt`.

The flake additionally applies `patches/ghostty-image-count.patch` (1,024 canonical images per screen) and `patches/ghostty-static-images.patch` (explicit rejection of animation commands before retaining metadata). Both later patches were checked against the pinned original source fingerprints and applied cleanly; exact resulting fingerprints are recorded in `.build/linux-remote/nix-final-patches.txt`. The final Linux package was rebuilt successfully with all three guards on 21 September. Its CLI package checks pass after adding OpenSSH to native test dependencies. The Nix-built helper and service also pass the full same-UID/PAM, account-denial, signal cleanup, resource-limit and Ctrl+C fixtures. Logs: `.build/linux-remote/nix-final-install-build.log`, `nix-final-package-checks.log`, `login-pam-final-tests.json`, `login-service-final-tests.json`, and `component-final-hashes.txt`. The disposable container was removed after validation.
