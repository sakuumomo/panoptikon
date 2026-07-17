# NixOS VM test for services.panoptikon.
# nixpkgs: nixos/tests/panoptikon.nix + all-tests.nix entry.
# Flake injects nixosModules.default via defaults.imports.
{
  name = "panoptikon";
  meta.maintainers = [ ];

  nodes.machine =
    { pkgs, ... }:
    {
      services.panoptikon = {
        enable = true;
        autoSetup = false;
        accelerator = "cpu";
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
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:6342/api/client-config | grep -q capabilities",
        timeout=120,
    )
    machine.succeed("systemctl is-active panoptikon.service")
  '';
}
