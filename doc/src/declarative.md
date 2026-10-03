# Declarative MicroVMs

Provided your NixOS host [includes the host nixosModule](./host.md),
options are declared to build a MicroVM together with the host.
You can choose whether your MicroVMs should be managed in a fully-declarative
way, or whether your only want the initial deployment be declarative (with subsequent
imperative updates using the [microvm command](./microvm-command.md)).

microvm.nix distinguishes between fully-declarative configurations
and declarative deployment by allowing you to specify either
a full `config` or just a `flake` respectively.

## Fully declarative

You can create fully declarative VMs by directly defining their
nixos system configuration in-place. This is very similar to how
nixos-containers work if you are familiar with those.

```nix
# microvm refers to microvm.nixosModules
{ microvm, ... }: {
  imports = [ microvm.host ];
  microvm.vms = {
    my-microvm = {
      # The package set to use for the microvm. This also determines the microvm's architecture.
      # Defaults to the host system's package set if not given.
      pkgs = import nixpkgs { system = "x86_64-linux"; };

      # (Optional) A set of special arguments to be passed to the MicroVM's NixOS modules.
      #specialArgs = {};

      # The configuration for the MicroVM.
      # Multiple definitions will be merged as expected.
      config = {
        # It is highly recommended to share the host's nix-store
        # with the VMs to prevent building huge images.
        microvm.shares = [{
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }];

        # Any other configuration for your MicroVM
        # [...]
      };
    };
  };
}
```

## Declarative deployment

Why *deployed*? The per-MicroVM subdirectory under `/var/lib/microvms`
is only created if it did not exist before. This behavior is
intended to ensure existence of MicroVMs that are critical to
operation. To update them later you will have to use the [imperative microvm
command](./microvm-command.md).

```nix
microvm.vms = {
  my-microvm = {
    # Host build-time reference to where the MicroVM NixOS is defined
    # under nixosConfigurations
    flake = self;
    # Specify from where to let `microvm -u` update later on
    updateFlake = "git+file:///etc/nixos";
  };
};
```

Note that building MicroVMs with the host increases build time and
closure size of the host's system.

## Templates and instances

A template is a MicroVM configuration declared once on the host. It is
built into one runner that any number of instances share.

```nix
microvm.templates.workstation.config = {
  microvm.instance.enable = true;
  # ...
};
```

The host keeps the template runner at
`/var/lib/microvms/.templates/<template>/current`. Instances are created
imperatively with `microvm -c <name> -t <template>`.

On every host switch, `install-microvm-template-<template>.service`:

- relinks `current` of every instance whose `template` file names the
  template,
- restarts booted instances whose runner changed, unless
  `restartIfChanged = false`,
- starts instances that were never booted, unless `autostart = false`.

A switch that does not change the template restarts nothing.

The runner reads `instance.env` from the instance directory at launch.
Memory, vCPUs, tap names and MAC addresses in it override the
template's values. The cloud-hypervisor runner supports this.

With `microvm.instance.enable`, the instance's `instance/` directory is
shared into the guest at `/run/microvm/instance`. A `hostname` file in
it sets the guest's hostname at boot.
