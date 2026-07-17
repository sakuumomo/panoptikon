# ROCm wiring when services.panoptikon.accelerator = "rocm".
{
  name = "panoptikon-rocm-config";
  meta.maintainers = [ ];

  nodes.machine =
    { pkgs, ... }:
    {
      services.panoptikon = {
        enable = true;
        autoSetup = false;
        accelerator = "rocm";
        host = "127.0.0.1";
        port = 6342;
      };
      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    machine.wait_for_unit("panoptikon.service")
    machine.wait_for_open_port(6342)

    unit = machine.succeed("systemctl cat panoptikon.service")
    assert "char-kfd" in unit
    assert "render" in unit
    machine.succeed("systemctl show panoptikon.service -p SupplementaryGroups --value | grep -q render")

    machine.succeed(
        "test -e /run/current-system/sw/lib/libamdhip64.so "
        "|| test -e /run/current-system/sw/lib/libamdhip64.so.7"
    )

    env = machine.succeed("systemctl show panoptikon.service -p Environment --value")
    assert "PANOPTIKON_ACCELERATOR=rocm" in env
    assert "ROCM_PATH=" in env

    # Package rebuilt with rocmSupport (host HIP paths in wrap).
    exe = machine.succeed(
        "systemctl cat panoptikon.service | sed -n 's|^ExecStart=\\([^ ]*\\).*|\\1|p' | head -1"
    ).strip()
    machine.succeed(f"grep -q '/opt/rocm/lib' '{exe}'")

    machine.succeed("systemctl is-active panoptikon.service")
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:6342/api/client-config | grep -q capabilities",
        timeout=120,
    )
  '';
}
