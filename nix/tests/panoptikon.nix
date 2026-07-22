# NixOS VM smoke for services.panoptikon (CPU). Flake injects the module.
{
  name = "panoptikon";
  meta.maintainers = [ ];

  nodes.machine =
    { pkgs, ... }:
    {
      services.panoptikon = {
        enable = true;
        autoSetup = false;
        host = "127.0.0.1";
        port = 6342;
      };
      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    machine.wait_for_unit("panoptikon.service")
    machine.wait_for_open_port(6342)
    machine.succeed("test -f /var/lib/panoptikon/config/server/default.toml")
    machine.succeed("test -f /var/lib/panoptikon/config/inference/example.toml")
    env = machine.succeed("systemctl show panoptikon.service -p Environment --value")
    assert "PANOPTIKON_ACCELERATOR=cpu" in env
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:6342/api/client-config | grep -q capabilities",
        timeout=120,
    )
    machine.succeed("systemctl is-active panoptikon.service")
  '';
}
