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
      '';

      meta.timeout = 1800;
    }
  ) {
    inherit system;
    pkgs = nixpkgs.legacyPackages.${system};
  };
}
