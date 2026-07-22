# CUDA wiring when services.panoptikon.accelerator = "cuda".
# Pure config/wrap assertions (no NVIDIA hardware required).
{
  name = "panoptikon-cuda-config";
  meta.maintainers = [ ];

  nodes.machine =
    { pkgs, ... }:
    {
      services.panoptikon = {
        enable = true;
        autoSetup = false;
        accelerator = "cuda";
        host = "127.0.0.1";
        port = 6342;
      };
      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    machine.wait_for_unit("panoptikon.service")
    machine.wait_for_open_port(6342)

    unit = machine.succeed("systemctl cat panoptikon.service")
    # NVIDIA device nodes; not AMD KFD.
    assert "char-nvidiactl" in unit
    assert "char-nvidia-uvm" in unit
    assert "char-kfd" not in unit
    assert "render" in unit
    machine.succeed("systemctl show panoptikon.service -p SupplementaryGroups --value | grep -q render")

    env = machine.succeed("systemctl show panoptikon.service -p Environment --value")
    assert "PANOPTIKON_ACCELERATOR=cuda" in env
    # ROCm-only service env must not be set for CUDA.
    assert "ROCM_PATH=" not in env
    assert "HIP_PATH=" not in env

    # Package wrap: cudaSupport pin + opengl-driver host path; no HIP paths.
    exe = machine.succeed(
        "systemctl cat panoptikon.service | sed -n 's|^ExecStart=\\([^ ]*\\).*|\\1|p' | head -1"
    ).strip()
    assert exe, "missing ExecStart binary"
    machine.succeed(f"test -x '{exe}'")
    machine.succeed(f"grep -q PANOPTIKON_ACCELERATOR '{exe}'")
    machine.succeed(f"grep -q cuda '{exe}'")
    machine.succeed(f"grep -q opengl-driver '{exe}'")
    machine.fail(f"grep -q '/opt/rocm/lib' '{exe}'")

    machine.succeed("systemctl is-active panoptikon.service")
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:6342/api/client-config | grep -q capabilities",
        timeout=120,
    )
  '';
}
