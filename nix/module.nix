# NixOS module: services.panoptikon
# Runtime: --root stateDir (never /nix/store); tools via package wrap + host_paths.
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
        Setup accelerator (PANOPTIKON_ACCELERATOR). cuda/rocm need host drivers.
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
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = false;
      description = "Panoptikon service user";
    };
    users.groups.${cfg.group} = { };

    fonts.packages = [
      pkgs.dejavu_fonts
      pkgs.noto-fonts
    ];

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];

    # ProtectSystem=strict needs stateDir before namespace setup (before preStart).
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
      '';

    systemd.services.panoptikon = {
      description = "Panoptikon media search engine";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PANOPTIKON_HOST = cfg.host;
        PANOPTIKON_PORT = toString cfg.port;
        PANOPTIKON_ACCELERATOR = cfg.accelerator;
        PANOPTIKON_AUTO_SETUP = if cfg.autoSetup then "true" else "false";
      }
      // cfg.extraEnvironment;

      path = [
        cfg.package
        pkgs.coreutils
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
        PrivateDevices = cfg.accelerator == "cpu";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";

        ReadWritePaths = [ root ] ++ cfg.readWritePaths;
        ReadOnlyPaths = cfg.libraryPaths;

        BindReadOnlyPaths = lib.mkIf (cfg.accelerator != "cpu") [
          "/run/opengl-driver"
        ];

        DevicePolicy = if cfg.accelerator == "cpu" then "closed" else "auto";
      };
    };
  };
}
