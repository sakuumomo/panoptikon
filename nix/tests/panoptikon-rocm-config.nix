# Evaluate-time style checks via a VM: service unit includes ROCm wiring
# (HIP packages, KFD, render group) without requiring a physical GPU.
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

    # Unit exposes ROCm/GPU hardening knobs from the module.
    unit = machine.succeed("systemctl cat panoptikon.service")
    assert "DeviceAllow" in unit or "DeviceAllow=" in unit or "char-kfd" in unit
    assert "render" in unit
    machine.succeed("systemctl show panoptikon.service -p SupplementaryGroups --value | grep -q render")

    # HIP runtime landed on the system profile (module environment.systemPackages).
    machine.succeed("test -e /run/current-system/sw/lib/libamdhip64.so || test -e /run/current-system/sw/lib/libamdhip64.so.7 || ls /run/current-system/sw/lib/libamdhip64.so*")

    # Service environment for ROCm paths.
    env = machine.succeed("systemctl show panoptikon.service -p Environment --value")
    assert "PANOPTIKON_ACCELERATOR=rocm" in env
    assert "ROCM_PATH=" in env

    machine.succeed("systemctl is-active panoptikon.service")
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:6342/api/client-config | grep -q capabilities",
        timeout=120,
    )
  '';
}
