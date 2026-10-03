# Imperative MicroVM management with the `microvm` command

Compartmentalizing services in an infrastructure landscape allows us to
conduct maintenance individually and without affecting unrelated
MicroVMs. The `microvm` command helps with that.

## Create a MicroVM

You can specify this MicroVM's source flake with `-f`. If omitted, the
tool will assume `git+file:///etc/nixos`. The source flakeref will be
kept in `/var/lib/microvms/*/flake` for future updating the MicroVM.

```bash
microvm -f git+https://... -c my-microvm
```

If `-f` points to a local flake, the path must be absolute. `create`
evaluates the flake from an internal temporary directory, so a
relative path (including `.`) will not resolve against your shell's
current working directory and the flake will not be found. Use
`-f $(pwd)` or a full path instead, e.g. `-f /path/to/flake`.

### Enabling MicroVM autostart

Extension of the host's systemd units must happen declaratively in the
host's NixOS configuration:

```nix
microvm.autostart = [
  "myvm1"
  "myvm2"
  "myvm3"
];
```

## Create an instance of a template

Templates declared in `microvm.templates` on the host can be
instantiated any number of times:

```bash
microvm -c alice -t workstation -m 4096 -v 2
```

| Flag | Meaning |
|---|---|
| `-t <template>` | Template to instantiate |
| `-m <MB>` | Memory, overriding the template's `microvm.mem` |
| `-v <n>` | vCPUs, overriding the template's `microvm.vcpu` |

The instance directory `/var/lib/microvms/<name>/` contains:

- `template`: the template name
- `current`: the template's runner
- `instance/`: an empty directory for per-instance files
- `instance.env`: values read by the runner at launch

| Key | Value |
|---|---|
| `MICROVM_HOSTNAME` | the instance name |
| `MICROVM_UUID` | a random UUID, passed to the VM as its SMBIOS UUID so each instance gets its own machine-id |
| `MICROVM_TAP_0` | `mvm-` followed by 8 hex digits derived from the name |
| `MICROVM_MAC_0` | `02:` followed by 5 bytes derived from the name |
| `MICROVM_MEM` | set by `-m` |
| `MICROVM_VCPU` | set by `-v` |

`microvm -u <name>` relinks `current` to the template's runner.

## Update a MicroVM

*Updating* does not refresh your packages but simply rebuilds the
MicroVM. Use `nix flake update` to get new package versions.

```bash
microvm -u my-microvm
```

Until ways have been found to safely transfer the profile into the
target /nix/store, and subsequently activate it, you must restart the
MicroVM for the update to take effect.

Use the `-R` flag to automatically restart if an update was built.

## List MicroVMs

Listing your MicroVMs is as trivial as `ls -1 /var/lib/microvms`

For more insight, the following command will read the current system
version of all MicroVMs and compare them to what the corresponding
flake evaluates. It is therefore quite slow to run, yet very useful
for an updatable VM overview.

```bash
microvm -l
```

If you want a faster overview of booted and current versions, run
this instead:

```bash
ls -l /var/lib/microvms/*/{current,booted}/share/microvm/system
```

## Removing MicroVMs

First, stop the MicroVM:

```bash
systemctl stop microvm@$NAME
```

If you don't use absolute filesystem paths for sockets, volumes, or
shares, all MicroVM state is kept under `/var/lib/microvms/$NAME/`.
The `microvm@.service` systemd service template depends on existence
of this directory.

```bash
rm -rf /var/lib/microvms/$NAME
```
