# NixOS module: services.panoptikon
# Runtime: --root stateDir (never /nix/store); tools via package wrap + host_paths.
# GPU: accelerator cpu|cuda|rocm|auto; ROCm installs HIP/HSA into the system
# profile and grants the service user render/video + DRM/KFD device access.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.panoptikon;
  inherit (lib)
    mkEnableOption
    mkPackageOption
    mkOption
    mkIf
    types
    ;

  isLoopback = host: host == "localhost" || host == "::1" || host == "" || lib.hasPrefix "127." host;

  root = cfg.stateDir;
  serverConfig = "${root}/config/server/default.toml";
  panoptikonBin = "${cfg.package}/bin/panoptikon";

  useGpu = cfg.accelerator != "cpu";
  useRocm = cfg.accelerator == "rocm";
  useCuda = cfg.accelerator == "cuda";

  # HIP/HSA for pytorch.org multi-arch rocm7.2 wheels. Fat wheels vendor most
  # math libs; the process still needs the host HIP runtime on the loader path.
  # systemPackages places these under /run/current-system/sw/lib so
  # panoptikon's rocm_env discovery (and the package wrap) can find them.
  rocmRuntimePkgs =
    with pkgs.rocmPackages;
    [
      clr
      rocm-runtime
      rocm-device-libs
      rocminfo
      rocm-smi
    ]
    ++ (with pkgs; [
      numactl
      zstd
    ]);
in
{
  options.services.panoptikon = {
    enable = mkEnableOption "Panoptikon multimodal media search server";

    package = mkPackageOption pkgs "panoptikon" { };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open {option}`services.panoptikon.port` in the firewall.
        Prefer a reverse proxy with authentication for non-loopback access.
      '';
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address (env PANOPTIKON_HOST).";
    };

    port = mkOption {
      type = types.port;
      default = 6342;
      description = "Gateway port (env PANOPTIKON_PORT).";
    };

    accelerator = mkOption {
      type = types.enum [
        "auto"
        "cpu"
        "cuda"
        "rocm"
      ];
      default = "cpu";
      description = ''
        Setup accelerator (PANOPTIKON_ACCELERATOR).
        - `cpu`: no GPU devices; closed device namespace.
        - `cuda`: NVIDIA (host drivers via /run/opengl-driver).
        - `rocm`: AMD ROCm 7.2.x — installs HIP/HSA into the system profile,
          opens DRM/KFD, and adds the service user to render/video.
        - `auto`: host-detect at setup; for AMD, install ROCm on the system
          yourself (or set `rocm` explicitly so this module provides HIP).
      '';
    };

    rocmOverrideGfx = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "10.3.0";
      description = ''
        When set, exports HSA_OVERRIDE_GFX_VERSION for the service (and
        preStart setup). Only needed if ROCm mis-detects the GPU ISA; native
        gfx1030 with multi-arch pytorch.org wheels usually does not need this.
      '';
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/panoptikon";
      description = ''
        Writable `--root` (not under /nix/store). Layout: config/, data/, runtime/.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "panoptikon";
      description = "Service user.";
    };

    group = mkOption {
      type = types.str;
      default = "panoptikon";
      description = "Service group.";
    };

    libraryPaths = mkOption {
      type = types.listOf types.path;
      default = [ ];
      example = [
        "/mnt/media/photos"
        "/var/lib/immich/library"
      ];
      description = "Extra ReadOnlyPaths for media trees (also add to scan config).";
    };

    readWritePaths = mkOption {
      type = types.listOf types.path;
      default = [ ];
      description = "Extra read-write paths.";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        LOGLEVEL = "DEBUG";
        RUST_LOG = "info,panoptikon=debug";
      };
      description = "Extra service environment.";
    };

    autoSetup = mkOption {
      type = types.bool;
      default = true;
      description = ''
        preStart: `panoptikon setup --if-needed` (TimeoutStartSec); process keeps
        PANOPTIKON_AUTO_SETUP for a later stale lockfile. First sync is multi-GB.
        With accelerator=rocm, setup also runs a HIP kernel probe.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra CLI args after the standard flags.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !(lib.hasPrefix "/nix/store" cfg.stateDir);
        message = "services.panoptikon.stateDir must not be under /nix/store (immutable).";
      }
      {
        assertion = cfg.rocmOverrideGfx == null || useRocm || cfg.accelerator == "auto";
        message = "services.panoptikon.rocmOverrideGfx is only meaningful with accelerator rocm or auto.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = false;
      description = "Panoptikon service user";
      # DRM render nodes + /dev/kfd (ROCm); NVIDIA also uses video/render on NixOS.
      extraGroups = lib.optionals useGpu [
        "render"
        "video"
      ];
    };
    users.groups.${cfg.group} = { };

    fonts.packages = [
      pkgs.dejavu_fonts
      pkgs.noto-fonts
    ];

    # HIP/HSA on the system profile so /run/current-system/sw/lib has
    # libamdhip64 (discovered by panoptikon rocm_env without store paths in config).
    environment.systemPackages = lib.optionals useRocm rocmRuntimePkgs;

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
    ];

    warnings =
      lib.optional (cfg.openFirewall && !isLoopback cfg.host) ''
        services.panoptikon.openFirewall is enabled while host is "${cfg.host}".
        Prefer a reverse proxy with authentication; not hardened for direct exposure.
      ''
      ++ lib.optional (!isLoopback cfg.host) ''
        services.panoptikon.host is "${cfg.host}" (not loopback). Ensure policies
        match that Host; seeded nixos.toml only allows localhost under allow_all.
      ''
      ++ lib.optional (cfg.accelerator == "auto") ''
        services.panoptikon.accelerator is "auto". For AMD GPUs prefer
        accelerator = "rocm" so this module installs HIP/HSA and grants KFD access.
      '';

    systemd.services.panoptikon = {
      description = "Panoptikon media search engine";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment =
        {
          PANOPTIKON_HOST = cfg.host;
          PANOPTIKON_PORT = toString cfg.port;
          PANOPTIKON_ACCELERATOR = cfg.accelerator;
          PANOPTIKON_AUTO_SETUP = if cfg.autoSetup then "true" else "false";
        }
        // lib.optionalAttrs (cfg.rocmOverrideGfx != null) {
          HSA_OVERRIDE_GFX_VERSION = cfg.rocmOverrideGfx;
        }
        // lib.optionalAttrs useRocm {
          # Helps HIP tools; worker LD path is still filled by rocm_env at spawn.
          ROCM_PATH = "${pkgs.rocmPackages.clr}";
          HIP_PATH = "${pkgs.rocmPackages.clr}";
        }
        // cfg.extraEnvironment;

      path = [
        cfg.package
        pkgs.coreutils
      ]
      ++ lib.optionals useRocm [
        pkgs.rocmPackages.rocminfo
        pkgs.rocmPackages.rocm-smi
      ];

      preStart = ''
        set -euo pipefail
        root=${lib.escapeShellArg root}
        mkdir -p "$root"/{config/server,config/inference,data,runtime}
        if [ ! -f "$root/config/server/default.toml" ]; then
          cp --no-preserve=mode,ownership \
            ${cfg.package}/share/panoptikon/nixos.toml \
            "$root/config/server/default.toml"
        fi
        if [ ! -f "$root/config/inference/example.toml" ]; then
          cp --no-preserve=mode,ownership \
            ${cfg.package}/share/panoptikon/inference-example.toml \
            "$root/config/inference/example.toml"
        fi
        chown -R ${lib.escapeShellArg cfg.user}:${lib.escapeShellArg cfg.group} "$root"
        ${lib.optionalString cfg.autoSetup ''
          if ! ${panoptikonBin} \
              --root "$root" \
              --config ${lib.escapeShellArg serverConfig} \
              --disable-update-check \
              setup \
              --if-needed \
              --accelerator ${lib.escapeShellArg cfg.accelerator}
          then
            echo "warning: panoptikon setup failed; starting without a complete managed venv" >&2
          fi
        ''}
      '';

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;

        ExecStart = lib.escapeShellArgs (
          [
            panoptikonBin
            "--root"
            root
            "--config"
            serverConfig
            "--disable-update-check"
          ]
          ++ cfg.extraArgs
        );

        WorkingDirectory = root;
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = if cfg.autoSetup then "2h" else "5min";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        # GPU needs real DRM/KFD nodes (ollama-style).
        PrivateDevices = !useGpu;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";

        ReadWritePaths = [ root ] ++ cfg.readWritePaths;
        ReadOnlyPaths = cfg.libraryPaths;

        # Optional (-): VMs / headless hosts may lack /run/opengl-driver.
        BindReadOnlyPaths = lib.optionals useGpu [ "-/run/opengl-driver" ];

        # Match nixpkgs ollama GPU unit: closed policy + explicit DRM/KFD/NVIDIA.
        DevicePolicy = "closed";
        DeviceAllow = lib.optionals useGpu [
          "char-drm"
          "char-fb"
          "char-kfd"
          "char-nvidiactl"
          "char-nvidia-caps"
          "char-nvidia-frontend"
          "char-nvidia-uvm"
        ];
        SupplementaryGroups = lib.optionals useGpu [
          "render"
          "video"
        ];
      };
    };
  };
}
