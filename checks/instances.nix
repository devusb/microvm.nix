{
  self,
  nixpkgs,
  system,
  ...
}:

let
  mkTest =
    name: testScript:
    import (nixpkgs + "/nixos/tests/make-test-python.nix") (
      { lib, pkgs, ... }:
      {
        inherit name;

        nodes.host = {
          imports = [ self.nixosModules.host ];
          microvm.host.startupTimeout = 30;
          systemd.enableStrictShellChecks = true;

          boot.kernelModules = [ "kvm" ];
          virtualisation.qemu.options = [
            "-cpu"
            "host"
          ];
          virtualisation.cores = 4;
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
              vcpu = 2;
              mem = 512;
              socket = "control.socket";
              instance.enable = true;
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
            networking.hostName = "tmpl";
            networking.useNetworkd = true;
            networking.useDHCP = false;
            networking.usePredictableInterfaceNames = false;
            systemd.network.networks."10-eth0" = {
              matchConfig.Name = "eth0";
              networkConfig.DHCP = "ipv4";
              dhcpV4Config.ClientIdentifier = "mac";
            };
            services.openssh.enable = true;
            services.openssh.settings.PermitRootLogin = "yes";
            users.users.root.password = "test";
            documentation.enable = false;
            services.timesyncd.enable = false;
            services.logrotate.enable = false;
            services.fstrim.enable = false;
            system.stateVersion = lib.trivial.release;
          };

          specialisation.v2.configuration.microvm.templates.tmpl.config = {
            environment.etc."base-version".text = "2";
            microvm.mem = lib.mkForce 640;
          };
        };

        testScript = ''
          def guest_ip(name):
              return host.succeed(f"awk '$4==\"{name}\"{{print $3}}' /var/lib/dnsmasq/dnsmasq.leases | tail -1").strip()

          def ssh(name, cmd):
              return host.succeed(f"sshpass -p test ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@{guest_ip(name)} {cmd}")

          def wait_ssh(name):
              host.wait_until_succeeds(f"grep -q ' {name} ' /var/lib/dnsmasq/dnsmasq.leases", timeout=180)
              host.wait_until_succeeds(f"sshpass -p test ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@{guest_ip(name)} true", timeout=180)

          def create(name, flags=""):
              host.succeed(f"microvm -c {name} -t tmpl {flags}")
              host.succeed(f"echo {name} > /var/lib/microvms/{name}/instance/hostname")

          def started(name):
              return host.succeed(f"systemctl show -p ActiveEnterTimestampMonotonic microvm@{name}.service").strip()

          host.wait_for_unit("multi-user.target")
        '' + testScript;

        meta.timeout = 1200;
      }
    ) {
      inherit system;
      pkgs = nixpkgs.legacyPackages.${system};
    };
in
{
  instances = mkTest "instances" /* python */ ''
    create("inst1")
    host.succeed("test -f /var/lib/microvms/inst1/template && grep -qx tmpl /var/lib/microvms/inst1/template")
    host.succeed("grep -q '^MICROVM_HOSTNAME=inst1$' /var/lib/microvms/inst1/instance.env")
    host.succeed("grep -Eq '^MICROVM_TAP_0=mvm-[0-9a-f]{8}$' /var/lib/microvms/inst1/instance.env")
    host.succeed("grep -Eq '^MICROVM_MAC_0=02(:[0-9a-f]{2}){5}$' /var/lib/microvms/inst1/instance.env")
    host.succeed("grep -Eq '^MICROVM_UUID=[0-9a-f-]{36}$' /var/lib/microvms/inst1/instance.env")
    create("inst2", "-m 768 -v 2")
    host.succeed("grep -q '^MICROVM_MEM=768$' /var/lib/microvms/inst2/instance.env")
    host.succeed("grep -q '^MICROVM_VCPU=2$' /var/lib/microvms/inst2/instance.env")
    tap1 = host.succeed("sed -n 's/^MICROVM_TAP_0=//p' /var/lib/microvms/inst1/instance.env").strip()
    tap2 = host.succeed("sed -n 's/^MICROVM_TAP_0=//p' /var/lib/microvms/inst2/instance.env").strip()
    assert tap1 != tap2
    host.succeed("microvm -l | sed 's/\\x1b\\[[0-9;]*m//g' | grep -q 'inst1: template tmpl'")
    host.fail("microvm -c inst1 -t tmpl")

    host.succeed("systemctl start microvm@inst1.service microvm@inst2.service")
    host.wait_for_unit("microvm@inst1.service")
    host.wait_for_unit("microvm@inst2.service")
    host.succeed(f"ip link show {tap1}")
    host.succeed(f"ip link show {tap2}")
    host.succeed("pgrep -af cloud-hypervisor | grep -q 'boot=2'")
    host.succeed("pgrep -af cloud-hypervisor | grep -q 'size=768M'")
    host.succeed("pgrep -af cloud-hypervisor | grep -q 'size=512M'")

    wait_ssh("inst1")
    wait_ssh("inst2")
    assert ssh("inst1", "hostname").strip() == "inst1"
    ssh("inst1", "findmnt /run/microvm/instance")
    host.fail(f"sshpass -p test ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@{guest_ip('inst1')} touch /run/microvm/instance/x")
    ssh("inst1", "findmnt -n -o SOURCE /home | grep -q /dev/vd")
    assert ssh("inst1", "cat /etc/machine-id") != ssh("inst2", "cat /etc/machine-id"), "instances share a machine-id"
    assert guest_ip("inst1") != guest_ip("inst2"), "instances share a DHCP lease"

    create("inst3", "-v 1")
    host.succeed("systemctl start microvm@inst3.service")
    wait_ssh("inst3")
    assert ssh("inst3", "nproc").strip() == "1"
  '';

  instances-restart = mkTest "instances-restart" /* python */ ''
    host.succeed("test -L /var/lib/microvms/.templates/tmpl/current")
    create("inst1")
    create("inst2", "-m 768")
    host.succeed("systemctl start microvm@inst1.service microvm@inst2.service")
    wait_ssh("inst1")
    wait_ssh("inst2")
    ssh("inst1", "'echo keep > /home/keep'")

    t1 = started("inst1")
    t2 = started("inst2")
    host.succeed("/run/current-system/bin/switch-to-configuration test")
    assert started("inst1") == t1, "no-op switch restarted inst1"
    assert started("inst2") == t2, "no-op switch restarted inst2"

    old = host.succeed("readlink /var/lib/microvms/.templates/tmpl/current").strip()
    host.succeed("/run/booted-system/specialisation/v2/bin/switch-to-configuration test")
    new = host.succeed("readlink /var/lib/microvms/.templates/tmpl/current").strip()
    assert old != new, "template runner did not change"
    assert host.succeed("readlink /var/lib/microvms/inst1/current").strip() == new
    host.wait_until_succeeds(f"[ \"$(systemctl show -p ActiveEnterTimestampMonotonic microvm@inst1.service)\" != '{t1}' ]", timeout=300)
    host.wait_until_succeeds(f"[ \"$(systemctl show -p ActiveEnterTimestampMonotonic microvm@inst2.service)\" != '{t2}' ]", timeout=300)
    wait_ssh("inst1")
    assert ssh("inst1", "cat /etc/base-version").strip() == "2"
    assert ssh("inst1", "cat /home/keep").strip() == "keep"
    host.succeed("pgrep -af cloud-hypervisor | grep -q 'size=640M'")
    host.succeed("pgrep -af cloud-hypervisor | grep -q 'size=768M'")

    create("inst3")
    host.succeed("test \"$(readlink /var/lib/microvms/inst3/current)\" = \"$(readlink /var/lib/microvms/.templates/tmpl/current)\"")

    host.succeed("systemctl stop microvm@inst1.service")
    host.succeed("ln -sfn \"$(readlink /var/lib/microvms/inst1/current)\" /var/lib/microvms/inst1/booted")
    host.succeed("systemctl restart install-microvm-template-tmpl.service")
    host.wait_for_unit("microvm@inst1.service")
  '';
}
