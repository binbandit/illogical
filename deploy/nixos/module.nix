{ config, lib, pkgs, ... }:
let
  cfg = config.services.illogical;
  inherit (lib) mkEnableOption mkOption types;
  loginHelper = pkgs.callPackage ./login-helper.nix {};
  instances = lib.mapAttrs' (name: instance:
    lib.nameValuePair "illogical-${name}" {
      description = "illogical terminal service for ${name}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      path = [ pkgs.coreutils pkgs.openssh config.users.users.${name}.shell ];
      environment = {
        HOME = config.users.users.${name}.home;
        SHELL = lib.getExe config.users.users.${name}.shell;
        ILLOGICAL_HOME = instance.stateDirectory;
        ILLOGICAL_SOCKET = "${instance.stateDirectory}/daemon.sock";
      };
      serviceConfig = {
        User = name;
        WorkingDirectory = config.users.users.${name}.home;
        ExecStartPre = "${pkgs.coreutils}/bin/install -d -m0700 ${lib.escapeShellArg instance.stateDirectory}";
        ExecStart = "${cfg.package}/bin/illogical serve"
          + lib.optionalString cfg.pamLogin " --login-helper /run/wrappers/bin/illogical-login"
          + lib.optionalString (instance.tailscaleConfig != null) " --tailscale-config ${lib.escapeShellArg instance.tailscaleConfig}";
        Restart = "on-failure";
        RestartSec = 2;
        UMask = "0077";
        # Shells must retain normal user access and PTY/session capabilities.
        KillMode = "control-group";
        TimeoutStopSec = 10;
      };
    }) cfg.users;
in {
  options.services.illogical = {
    enable = mkEnableOption "persistent illogical terminal workspaces";
    pamLogin = mkEnableOption "real per-terminal PAM sessions via an explicit same-UID privileged helper";
    package = mkOption { type = types.package; description = "illogical package built by this repository's flake"; };
    users = mkOption {
      default = {};
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          stateDirectory = mkOption { type = types.str; default = "${config.users.users.${name}.home}/.local/share/illogical"; };
          tailscaleConfig = mkOption { type = types.nullOr types.str; default = null; description = "Runtime path to opt-in Tailscale JSON config; secrets must not enter the Nix store"; };
        };
      }));
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (name: _: {
      assertion = builtins.hasAttr name config.users.users && config.users.users.${name}.isNormalUser;
      message = "illogical requires an existing normal Unix user: ${name}";
    }) cfg.users;
    environment.systemPackages = [ cfg.package ];
    systemd.services = instances;
    security.wrappers = lib.mkIf cfg.pamLogin {
      illogical-login = {
        owner = "root";
        group = "root";
        setuid = true;
        source = "${loginHelper}/bin/illogical-login";
      };
    };
    security.pam.services.illogical = lib.mkIf cfg.pamLogin {
      # Caller identity is the setuid helper's immutable real UID. No password
      # flow is exposed over RPC; normal account and session policies still run.
      startSession = true;
      setLoginUid = true;
    };
  };
}
