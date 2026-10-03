{
  self,
  nixpkgs,
  system,
  ...
}:

{
  instances = import (nixpkgs + "/nixos/tests/make-test-python.nix") (
    { lib, pkgs, ... }:
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

        environment.systemPackages = [ pkgs.sshpass ];
        networking.firewall.trustedInterfaces = [ "vmbr0" ];
        systemd.network = {
          enable = true;
          netdevs."10-vmbr0".netdevConfig = {
            Name = "vmbr0";
            Kind = "bridge";
          };
          networks."10-vmbr0" = {
            matchConfig.Name = "vmbr0";
            address = [ "10.100.0.1/24" ];
            networkConfig.ConfigureWithoutCarrier = true;
          };
          networks."11-mvm" = {
            matchConfig.Name = "mvm-*";
            networkConfig.Bridge = "vmbr0";
          };
        };
        services.dnsmasq = {
          enable = true;
          resolveLocalQueries = false;
          settings = {
            interface = "vmbr0";
            bind-dynamic = true;
            dhcp-range = "10.100.0.10,10.100.0.250,12h";
          };
        };

        microvm.templates.tmpl.config = {
          microvm = {
            hypervisor = "cloud-hypervisor";
            vcpu = 1;
            mem = 512;
            socket = "control.socket";
            interfaces = [
              {
                type = "tap";
                id = "mvm-tmpl";
                mac = "02:00:00:00:00:00";
              }
            ];
            volumes = [
              {
                image = "home.img";
                mountPoint = "/home";
                size = 256;
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
          microvm.instance.enable = true;
          networking.hostName = "tmpl";
          networking.useNetworkd = true;
          networking.useDHCP = true;
          networking.usePredictableInterfaceNames = false;
          services.openssh.enable = true;
          services.openssh.settings.PermitRootLogin = "yes";
          users.users.root.password = "test";
          system.stateVersion = lib.trivial.release;
        };

        specialisation.v2.configuration.microvm.templates.tmpl.config = {
          environment.etc."base-version".text = "2";
          microvm.mem = lib.mkForce 640;
        };
      };

      testScript = /* python */ ''
        host.wait_for_unit("multi-user.target")
        host.succeed("test -L /var/lib/microvms/.templates/tmpl/current")
        host.succeed("mkdir -p /var/lib/microvms/pre/instance && echo tmpl > /var/lib/microvms/pre/template && chown -R microvm:kvm /var/lib/microvms/pre")
        host.succeed("systemctl restart install-microvm-template-tmpl.service")
        host.succeed("test -L /var/lib/microvms/pre/current")
        old = host.succeed("readlink /var/lib/microvms/.templates/tmpl/current").strip()
        host.succeed("/run/current-system/specialisation/v2/bin/switch-to-configuration test")
        new = host.succeed("readlink /var/lib/microvms/.templates/tmpl/current").strip()
        assert old != new, "template runner did not change"
        assert host.succeed("readlink /var/lib/microvms/pre/current").strip() == new
        host.succeed("/run/booted-system/bin/switch-to-configuration test")

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

        def guest_ip(name):
            return host.succeed(f"awk '$4==\"{name}\"{{print $3}}' /var/lib/dnsmasq/dnsmasq.leases | tail -1").strip()

        def ssh(name, cmd):
            return host.succeed(f"sshpass -p test ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@{guest_ip(name)} {cmd}")

        host.succeed("echo inst1 > /var/lib/microvms/inst1/instance/hostname")
        host.succeed("systemctl restart microvm@inst1.service")
        host.wait_for_unit("microvm@inst1.service")
        host.wait_until_succeeds("grep -q ' inst1 ' /var/lib/dnsmasq/dnsmasq.leases", timeout=180)
        host.wait_until_succeeds(f"sshpass -p test ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@{guest_ip('inst1')} true", timeout=180)
        assert ssh("inst1", "hostname").strip() == "inst1"
        ssh("inst1", "findmnt /run/microvm/instance")
        ssh("inst1", "findmnt -n -o SOURCE /home | grep -q /dev/vd")

        ssh("inst1", "'echo keep > /home/keep'")
        def started(name):
            return host.succeed(f"systemctl show -p ActiveEnterTimestampMonotonic microvm@{name}.service").strip()
        t1_before = started("inst1")
        t2_before = started("inst2")
        host.succeed("/run/current-system/bin/switch-to-configuration test")
        assert started("inst1") == t1_before, "no-op switch restarted inst1"
        assert started("inst2") == t2_before, "no-op switch restarted inst2"
        host.succeed("/run/booted-system/specialisation/v2/bin/switch-to-configuration test")
        host.wait_until_succeeds(f"[ \"$(systemctl show -p ActiveEnterTimestampMonotonic microvm@inst1.service)\" != '{t1_before}' ]", timeout=300)
        host.wait_until_succeeds(f"[ \"$(systemctl show -p ActiveEnterTimestampMonotonic microvm@inst2.service)\" != '{t2_before}' ]", timeout=300)
        host.wait_for_unit("microvm@inst1.service")
        host.wait_until_succeeds("grep -q ' inst1 ' /var/lib/dnsmasq/dnsmasq.leases", timeout=180)
        host.wait_until_succeeds(f"sshpass -p test ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@{guest_ip('inst1')} true", timeout=180)
        assert ssh("inst1", "cat /etc/base-version").strip() == "2"
        assert ssh("inst1", "cat /home/keep").strip() == "keep"
        host.succeed("pgrep -af cloud-hypervisor | grep -q 'size=640M'")
        host.succeed("pgrep -af cloud-hypervisor | grep -q 'size=768M'")
        host.succeed("microvm -c inst3 -t tmpl")
        host.succeed("test \"$(readlink /var/lib/microvms/inst3/current)\" = \"$(readlink /var/lib/microvms/.templates/tmpl/current)\"")
      '';

      meta.timeout = 1800;
    }
  ) {
    inherit system;
    pkgs = nixpkgs.legacyPackages.${system};
  };
}
