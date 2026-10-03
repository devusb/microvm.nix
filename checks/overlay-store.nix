{
  self,
  nixpkgs,
  system,
  ...
}:

{
  overlay-store = import (nixpkgs + "/nixos/tests/make-test-python.nix") (
    { lib, pkgs, ... }:
    {
      name = "overlay-store";

      nodes.host = {
        imports = [ self.nixosModules.host ];
        microvm.host.startupTimeout = 30;

        boot.kernelModules = [ "kvm" ];
        virtualisation.qemu.options = [
          "-cpu"
          "kvm64,+svm,+vmx"
        ];
        virtualisation.diskSize = 8192;
        virtualisation.memorySize = 4096;

        nix.settings.experimental-features = [ "nix-command" ];
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

        systemd.services.binary-cache = {
          wantedBy = [ "multi-user.target" ];
          script = "mkdir -p /var/lib/cache && printf 'StoreDir: /nix/store\\n' > /var/lib/cache/nix-cache-info && cd /var/lib/cache && exec ${pkgs.python3}/bin/python3 -m http.server 8080 --bind 10.100.0.1";
          serviceConfig.Restart = "always";
        };

        microvm.vms.ov.config = {
          microvm = {
            hypervisor = "cloud-hypervisor";
            vcpu = 1;
            mem = 1024;
            socket = "control.socket";
            interfaces = [
              {
                type = "tap";
                id = "mvm-ov";
                mac = "02:00:00:00:00:01";
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
            overlayStore = {
              enable = true;
              upperSize = 2048;
              varSize = 256;
            };
          };
          networking.useNetworkd = true;
          networking.useDHCP = true;
          networking.usePredictableInterfaceNames = false;
          services.openssh.enable = true;
          services.openssh.settings.PermitRootLogin = "yes";
          users.users.root.password = "test";
          nix.settings = {
            substituters = lib.mkForce [ "http://10.100.0.1:8080" ];
            require-sigs = false;
            experimental-features = [ "nix-command" ];
          };
          system.stateVersion = lib.trivial.release;
        };
      };

      testScript = /* python */ ''
        def guest_ip():
            return host.succeed("awk '$4==\"ov\"{print $3}' /var/lib/dnsmasq/dnsmasq.leases").strip()

        def ssh(cmd):
            return host.succeed(f"sshpass -p test ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@{guest_ip()} '{cmd}'")

        def wait_guest():
            host.wait_for_unit("microvm@ov.service")
            host.wait_until_succeeds("grep -q ' ov ' /var/lib/dnsmasq/dnsmasq.leases", timeout=180)
            host.wait_until_succeeds(f"sshpass -p test ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@{guest_ip()} true", timeout=180)
            ssh("systemctl is-active microvm-verify-store.service")

        def restart_guest():
            host.succeed("systemctl stop microvm@ov.service")
            host.succeed("rm -f /var/lib/dnsmasq/dnsmasq.leases && systemctl restart dnsmasq")
            host.succeed("systemctl start microvm@ov.service")
            wait_guest()

        host.wait_for_unit("multi-user.target")
        wait_guest()

        with subtest("host paths are valid in the guest"):
            bash = host.succeed("readlink -f /run/current-system/sw/bin/bash").strip()
            ssh(f"nix path-info {bash}")

        with subtest("a guest path depending on a host path survives a restart"):
            hostonly = host.succeed("echo hostonly > /tmp/h && nix store add-file /tmp/h").strip()
            ssh(f"nix path-info {hostonly}")
            local = ssh("echo local > /root/f && nix store add-file /root/f").strip()
            import base64
            expr = 'derivation { name = "dep"; system = "x86_64-linux"; builder = "/bin/sh"; args = [ "-c" "echo ''${builtins.storePath "' + hostonly + '"} > $out" ]; }'
            ssh(f"echo {base64.b64encode(expr.encode()).decode()} | base64 -d > /root/dep.nix")
            built = ssh("nix build --impure --no-link --print-out-paths -f /root/dep.nix").strip()
            assert hostonly in ssh(f"nix-store -q --references {built}")
            restart_guest()
            ssh(f"nix path-info {local} {built} {hostonly}")
            ssh(f"cat {built}")
            ssh("nix-store --verify")

        with subtest("a host path added while the guest runs is visible"):
            late = host.succeed("echo late > /tmp/l && nix store add-file /tmp/l").strip()
            ssh(f"nix path-info {late}")

        with subtest("a host path deleted while the guest is stopped is repaired at boot"):
            host.succeed(f"nix copy --to file:///var/lib/cache {hostonly}")
            host.succeed("systemctl stop microvm@ov.service")
            host.succeed(f"nix-store --delete {hostonly}")
            host.fail(f"test -e {hostonly}")
            host.succeed("rm -f /var/lib/dnsmasq/dnsmasq.leases && systemctl restart dnsmasq")
            host.succeed("systemctl start microvm@ov.service")
            wait_guest()
            ssh(f"test -e {hostonly}")
            ssh(f"nix path-info {built}")
            ssh("nix-store --verify")
      '';

      meta.timeout = 1800;
    }
  ) {
    inherit system;
    pkgs = nixpkgs.legacyPackages.${system};
  };
}
