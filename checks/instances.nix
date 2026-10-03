{
  self,
  nixpkgs,
  system,
  ...
}:

{
  instances = import (nixpkgs + "/nixos/tests/make-test-python.nix") (
    { lib, ... }:
    {
      name = "instances";

      nodes.host = {
        imports = [ self.nixosModules.host ];
        systemd.enableStrictShellChecks = true;

        boot.kernelModules = [ "kvm" ];
        virtualisation.qemu.options = [
          "-cpu"
          "kvm64,+svm,+vmx"
        ];
        virtualisation.diskSize = 8192;
        virtualisation.memorySize = 4096;

        microvm.templates.tmpl.config = {
          microvm = {
            hypervisor = "cloud-hypervisor";
            vcpu = 1;
            mem = 512;
            interfaces = [
              {
                type = "tap";
                id = "mvm-tmpl";
                mac = "02:00:00:00:00:00";
              }
            ];
            shares = [
              {
                proto = "virtiofs";
                tag = "ro-store";
                source = "/nix/store";
                mountPoint = "/nix/.ro-store";
                socket = "ro-store.sock";
              }
            ];
          };
          networking.hostName = "tmpl";
          system.stateVersion = lib.trivial.release;
        };

        specialisation.v2.configuration.microvm.templates.tmpl.config.environment.etc."base-version".text =
          "2";
      };

      testScript = /* python */ ''
        host.wait_for_unit("multi-user.target")
        host.succeed("test -L /var/lib/microvms/.templates/tmpl/current")
        host.succeed("mkdir -p /var/lib/microvms/pre && echo tmpl > /var/lib/microvms/pre/template && chown -R microvm:kvm /var/lib/microvms/pre")
        host.succeed("systemctl restart install-microvm-template-tmpl.service")
        host.succeed("test -L /var/lib/microvms/pre/current")
        old = host.succeed("readlink /var/lib/microvms/.templates/tmpl/current").strip()
        host.succeed("/run/current-system/specialisation/v2/bin/switch-to-configuration test")
        new = host.succeed("readlink /var/lib/microvms/.templates/tmpl/current").strip()
        assert old != new, "template runner did not change"
        assert host.succeed("readlink /var/lib/microvms/pre/current").strip() == new

        host.succeed("microvm -c inst1 -t tmpl")
        host.succeed("test -f /var/lib/microvms/inst1/template && grep -qx tmpl /var/lib/microvms/inst1/template")
        host.succeed("grep -q '^MICROVM_HOSTNAME=inst1$' /var/lib/microvms/inst1/instance.env")
        host.succeed("grep -Eq '^MICROVM_TAP_0=mvm-[0-9a-f]{8}$' /var/lib/microvms/inst1/instance.env")
        host.succeed("grep -Eq '^MICROVM_MAC_0=02(:[0-9a-f]{2}){5}$' /var/lib/microvms/inst1/instance.env")
        host.succeed("test -d /var/lib/microvms/inst1/instance")
        host.succeed("microvm -c inst2 -t tmpl -m 768 -v 2")
        host.succeed("grep -q '^MICROVM_MEM=768$' /var/lib/microvms/inst2/instance.env")
        host.succeed("grep -q '^MICROVM_VCPU=2$' /var/lib/microvms/inst2/instance.env")
        tap1 = host.succeed("grep MICROVM_TAP_0 /var/lib/microvms/inst1/instance.env")
        tap2 = host.succeed("grep MICROVM_TAP_0 /var/lib/microvms/inst2/instance.env")
        assert tap1 != tap2
        host.succeed("microvm -l | sed 's/\\x1b\\[[0-9;]*m//g' | grep -q 'inst1: template tmpl'")
        host.fail("microvm -c inst1 -t tmpl")

        runner = host.succeed("readlink /var/lib/microvms/.templates/tmpl/current").strip()
        host.succeed(f"grep -q MICROVM_VCPU {runner}/bin/microvm-run")
        host.succeed(f"grep -q MICROVM_MEM {runner}/bin/microvm-run")
        host.succeed("systemctl start microvm@inst1.service microvm@inst2.service")
        host.wait_for_unit("microvm@inst1.service")
        host.wait_for_unit("microvm@inst2.service")
        tap1 = host.succeed("sed -n 's/^MICROVM_TAP_0=//p' /var/lib/microvms/inst1/instance.env").strip()
        tap2 = host.succeed("sed -n 's/^MICROVM_TAP_0=//p' /var/lib/microvms/inst2/instance.env").strip()
        host.succeed(f"ip link show {tap1}")
        host.succeed(f"ip link show {tap2}")
        host.succeed("pgrep -f 'cloud-hypervisor.*boot=2' >/dev/null")
      '';

      meta.timeout = 1800;
    }
  ) {
    inherit system;
    pkgs = nixpkgs.legacyPackages.${system};
  };
}
