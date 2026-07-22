# services.panoptikon: --root stateDir; accelerator → setup/devices/HIP/package wrap.
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

  useRocm = cfg.accelerator == "rocm";
  useCuda = cfg.accelerator == "cuda";
  # auto: GPU device nodes for host detect; no HIP packages (use rocm for AMD).
  useGpu = cfg.accelerator != "cpu";

  # Rebuild only when wrap flags would change (nixpkgs package args).
  package =
    let
      p = cfg.package;
      already =
        (p.cudaSupport or false) == useCuda && (p.rocmSupport or false) == useRocm;
    in
    if already then
      p
    else
      p.override {
        cudaSupport = useCuda;
        rocmSupport = useRocm;
      };
  panoptikonBin = "${package}/bin/panoptikon";

  pkgsCuda = pkgs.config.cudaSupport or false;
  pkgsRocm = pkgs.config.rocmSupport or false;

  defaultAccelerator =
    if pkgsRocm && !pkgsCuda then
      "rocm"
    else if pkgsCuda && !pkgsRocm then
      "cuda"
    else
      "cpu";

  rocmRuntimePkgs = import ./rocm-packages.nix { inherit pkgs; };
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
      default = defaultAccelerator;
      defaultText = lib.literalExpression ''
        if pkgs.config.rocmSupport then "rocm"
        else if pkgs.config.cudaSupport then "cuda"
        else "cpu"
      '';
      description = ''
        Setup accelerator (`PANOPTIKON_ACCELERATOR` / `setup --accelerator`).
        Default follows `nixpkgs.config.rocmSupport` / `cudaSupport` when exactly
        one is set; otherwise `cpu`.

        - `cpu`: closed devices; package wrap without GPU host paths.
        - `cuda`: NVIDIA DeviceAllow, render/video, opengl-driver bind;
          package with `cudaSupport = true`.
        - `rocm`: HIP/HSA packages, KFD, render/video, `ROCM_PATH`/`HIP_PATH`;
          package with `rocmSupport = true`.
        - `auto`: detect at setup; opens DRM/KFD/NVIDIA devices but does not
          install HIP — prefer `rocm` on AMD.
      '';
    };

    rocmOverrideGfx = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "10.3.0";
      description = ''
        Export HSA_OVERRIDE_GFX_VERSION (`rocm` or `auto`). Usually unneeded
        with multi-arch pytorch.org wheels on gfx1030.
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
        preStart: `panoptikon setup --if-needed` (long TimeoutStartSec). First
        sync is multi-GB; `rocm` also HIP-probes torch after sync.
        PANOPTIKON_AUTO_SETUP still covers a later stale lockfile after start.
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
        assertion = !(pkgsCuda && pkgsRocm);
        message = ''
          services.panoptikon: nixpkgs.config.cudaSupport and rocmSupport cannot
          both be true (same rule as the panoptikon package).
        '';
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
        services.panoptikon.accelerator is "auto". For AMD prefer accelerator = "rocm"
        so this module installs HIP/HSA and enables package rocmSupport wrap.
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
          ROCM_PATH = "${pkgs.rocmPackages.clr}";
          HIP_PATH = "${pkgs.rocmPackages.clr}";
        }
        // cfg.extraEnvironment;

      path = [
        package
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
            ${package}/share/panoptikon/nixos.toml \
            "$root/config/server/default.toml"
        fi
        if [ ! -f "$root/config/inference/example.toml" ]; then
          cp --no-preserve=mode,ownership \
            ${package}/share/panoptikon/inference-example.toml \
            "$root/config/inference/example.toml"
        fi
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

        # Optional (-): VMs may lack /run/opengl-driver.
        BindReadOnlyPaths = lib.optionals useGpu [ "-/run/opengl-driver" ];

        DevicePolicy = "closed";
        DeviceAllow =
          lib.optionals useGpu [
            "char-drm"
            "char-fb"
          ]
          ++ lib.optionals (useRocm || cfg.accelerator == "auto") [ "char-kfd" ]
          ++ lib.optionals (useCuda || cfg.accelerator == "auto") [
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
