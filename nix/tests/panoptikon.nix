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
    assert "ROCM_PATH=" not in env

    # CPU service must not pull in AMD GPU device / group wiring.
    unit = machine.succeed("systemctl cat panoptikon.service")
    assert "char-kfd" not in unit

    # Default package wrap is CPU-only (no host HIP injection script).
    exe = machine.succeed(
        "systemctl cat panoptikon.service | sed -n 's|^ExecStart=\\([^ ]*\\).*|\\1|p' | head -1"
    ).strip()
    assert exe, "missing ExecStart binary"
    machine.succeed(f"test -x '{exe}'")
    machine.fail(f"grep -q '/opt/rocm/lib' '{exe}'")

    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:6342/api/client-config | grep -q capabilities",
        timeout=120,
    )
    machine.succeed("systemctl is-active panoptikon.service")
  '';
}
