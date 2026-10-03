{ config, lib, pkgs, ... }:

let
  cfg = config.microvm.overlayStore;
  roStore = "/nix/.ro-store";
  roVar = "/nix/.ro-var";
  rwStore = "/nix/.rw-store";

  remountHook = pkgs.writeShellScript "remount-nix-store" ''
    ${lib.getExe' pkgs.util-linux "mount"} -o remount /nix/store
  '';

  lowerStore = "local%3A//%3Freal%3D${roStore}%26state%3D${roVar}/nix%26read-only%3Dtrue";
in
{
  options.microvm.overlayStore = {
    enable = lib.mkEnableOption ''
      a persistent writable Nix store layered over the host's store.

      The host's `/nix/store` and `/nix/var` are the read-only lower
      store. Paths built or fetched in the guest go to an upper layer on
      a volume, and the guest's Nix database and profiles live on a
      second volume at `/nix/var`. Both survive restarts. The guest's
      nix-daemon serves the combination as a `local-overlay` store

      Deleting host store paths that the guest's upper layer references
      breaks those paths until they are repaired. Collect garbage on the
      host only while guests are stopped; `verifyOnBoot` substitutes
      missing paths at the next boot
    '';

    upperImage = lib.mkOption {
      type = lib.types.str;
      default = "nix-store-overlay.img";
      description = "Volume image holding the upper store layer.";
    };

    upperSize = lib.mkOption {
      type = lib.types.int;
      default = 65536;
      description = "Size of the upper store layer volume in MB.";
    };

    varImage = lib.mkOption {
      type = lib.types.str;
      default = "nix-var.img";
      description = "Volume image holding the guest's `/nix/var`.";
    };

    varSize = lib.mkOption {
      type = lib.types.int;
      default = 1024;
      description = "Size of the `/nix/var` volume in MB.";
    };

    verifyOnBoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run `nix-store --verify --repair` at boot, before user sessions.
        It drops database entries for missing paths nothing refers to and
        substitutes missing paths that are still referenced.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (config.nix.package.pname or "nix") != "lix";
        message = "microvm.overlayStore needs the local-overlay-store experimental feature, which Lix does not implement";
      }
      {
        assertion = builtins.any ({ source, mountPoint, ... }:
          source == "/nix/store" && mountPoint == roStore
        ) config.microvm.shares;
        message = "microvm.overlayStore requires the host /nix/store shared at ${roStore}";
      }
    ];

    microvm.writableStoreOverlay = rwStore;
    microvm.registerClosure = false;

    microvm.shares = [ {
      proto = "virtiofs";
      tag = "nix-var";
      source = "/nix/var";
      mountPoint = roVar;
      socket = "nix-var.sock";
      readOnly = true;
    } ];

    microvm.volumes = [
      {
        image = cfg.upperImage;
        size = cfg.upperSize;
        mountPoint = rwStore;
        label = "nix-upper";
      }
      {
        image = cfg.varImage;
        size = cfg.varSize;
        mountPoint = "/nix/var";
        label = "nix-var";
      }
    ];

    fileSystems.${roVar}.neededForBoot = true;
    fileSystems."/nix/var".neededForBoot = true;

    nix.settings.experimental-features = [ "nix-command" "local-overlay-store" "read-only-local-store" ];

    environment.etc."nix/nix-daemon-env".text =
      "NIX_REMOTE=local-overlay://?upper-layer=${rwStore}/store&lower-store=${lowerStore}&check-mount=false&remount-hook=${remountHook}\n";
    systemd.services.nix-daemon.serviceConfig.EnvironmentFile = "/etc/nix/nix-daemon-env";

    environment.variables.NIX_REMOTE = "daemon";
    systemd.globalEnvironment.NIX_REMOTE = "daemon";

    systemd.services.microvm-verify-store = lib.mkIf cfg.verifyOnBoot {
      description = "Reconcile the Nix database with the store";
      wantedBy = [ "multi-user.target" ];
      before = [ "systemd-user-sessions.service" ];
      requires = [ "nix-daemon.socket" ];
      after = [ "nix-daemon.socket" "network-online.target" ];
      wants = [ "network-online.target" ];
      environment.NIX_REMOTE = "daemon";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ config.nix.package ];
      script = "nix-store --verify --repair";
    };
  };
}
