# Persistent overlay store

`microvm.overlayStore.enable` gives a guest a writable Nix store that
survives restarts and shares every path of the host's store.

```nix
microvm.shares = [ {
  proto = "virtiofs";
  tag = "ro-store";
  source = "/nix/store";
  mountPoint = "/nix/.ro-store";
} ];
microvm.overlayStore.enable = true;
```

| Layer | Location in the guest | Source |
|---|---|---|
| Lower store | `/nix/.ro-store` | host `/nix/store`, read-only |
| Lower database | `/nix/.ro-var` | host `/nix/var`, read-only |
| Upper store | `/nix/.rw-store` | volume `nix-store-overlay.img` |
| Guest database and profiles | `/nix/var` | volume `nix-var.img` |

The guest's nix-daemon opens the store as `local-overlay://`. Every
client uses the daemon through `NIX_REMOTE=daemon`. The
`local-overlay-store` and `read-only-local-store` experimental features
are enabled. Lix is not supported.

At boot, `microvm-verify-store.service` runs `nix-store --verify --repair`
before user sessions start. It removes database entries for missing paths
that nothing references, and substitutes missing paths that are still
referenced.

## Host garbage collection

Host store paths that a guest's upper layer references are not GC roots
on the host. Collect garbage on the host only while every guest using the
overlay store is stopped. Paths removed by the collection are substituted
by each guest's verify unit at its next boot. Paths with no substitute,
such as locally built ones, are lost.
