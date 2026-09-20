{ pkgs, package }:
pkgs.testers.runNixOSTest {
  name = "illogical-login-and-persistence";
  nodes.machine = { ... }: {
    imports = [ ./module.nix ];
    users.users.fixture = {
      isNormalUser = true;
      home = "/home/fixture";
      createHome = true;
    };
    services.illogical = {
      enable = true;
      inherit package;
      pamLogin = true;
      users.fixture = {};
    };
  };
  testScript = ''
    import json
    machine.wait_for_unit("illogical-fixture.service")
    cli = "su - fixture -c 'ILLOGICAL_HOME=/home/fixture/.local/share/illogical ${package}/bin/illogical "
    machine.succeed(cli + "new persistent --keep-open -- /bin/sh -c \"id; sleep 120\"'")
    first = json.loads(machine.succeed(cli + "ls'"))
    machine.succeed(cli + "ls'")
    second = json.loads(machine.succeed(cli + "ls'"))
    def pids(reply):
        return sorted(block["pid"] for block in reply["state"]["blocks"])
    assert pids(first) == pids(second) and pids(first), "detached CLI should not replace terminal processes"
    machine.succeed("journalctl -u illogical-fixture.service --no-pager | grep 'session opened for user fixture'")
    machine.succeed("stat -c %a /home/fixture/.local/share/illogical/daemon.sock | grep '^600$'")
    machine.succeed("systemctl stop illogical-fixture.service")
    machine.succeed("journalctl --no-pager | grep 'session closed for user fixture'")
  '';
}
