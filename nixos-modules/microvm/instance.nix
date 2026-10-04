{ config, lib, ... }:

let
  cfg = config.microvm.instance;
in
{
  options.microvm.instance = {
    enable = lib.mkEnableOption ''
      the per-instance share for MicroVMs created from a template.

      The host directory `instance/` inside the instance state directory
      is mounted at `microvm.instance.mountPoint`. If it contains a
      `hostname` file, its content becomes the hostname at boot.
    '';

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/run/microvm/instance";
      description = "Where the per-instance directory is mounted in the guest.";
    };
  };

  config = lib.mkIf cfg.enable {
    microvm.shares = [ {
      proto = "virtiofs";
      tag = "instance";
      source = "instance";
      inherit (cfg) mountPoint;
      socket = "instance.sock";
      readOnly = true;
    } ];

    systemd.services.microvm-instance-hostname = {
      description = "Set hostname from the MicroVM instance directory";
      wantedBy = [ "sysinit.target" ];
      before = [ "sysinit.target" "network-pre.target" ];
      wants = [ "network-pre.target" ];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = [ cfg.mountPoint ];
        ConditionPathExists = "${cfg.mountPoint}/hostname";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        read -r name < ${cfg.mountPoint}/hostname
        echo "$name" > /proc/sys/kernel/hostname
      '';
    };
  };
}
