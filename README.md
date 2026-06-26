# podman-subshell-flake

A Nix flake for creating devShells with podman, skopeo, buildah, and related containers storage tools, and isolated container storage. 
Designed for use by projects that need container tools, can't rely on the host to necessarily have them, and want to avoid cross-contamination between projects/workspaces. 

Host image storage, if present, is implicitly shared as read-only that can be masked by the isolated image storage.  
Podman networks can either be shared with the host or isolated as well.  
Multiple devShell instances for the same project share the same tools, configuration, and storage/isolation settings.

This flake can be used in two ways:

1. **As a standalone flake** — use it directly for its `devShells.default` and built-in `help` application, with configuration via environment variables.
2. **As a flake-parts module** — import the `podmanFlake` [flake-parts](https://flake.parts/) module into your own flake-parts project and configure it with Nix options with external visiblity mapped however you'd like.

Both methods produce the same devShell, which includes **podman**, **buildah**, **skopeo**, and all required runtime tooling. A `shellHook` generates isolated configuration files in a local directory on entry, seeded from host settings where available, and configures the environment to use that local directory for all the container tools.

## Quick Start

### Standalone Flake

Add `podman-subshell-flake` as an input and merge its `devShells` and `apps` into your own outputs. No flake-parts dependency is needed:

```/dev/null/flake.nix#L1-42
{
  description = "My project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    podman-subshell.url = "github:mtalexan/podman-subshell-flake";
  };

  outputs = { self, nixpkgs, podman-subshell, ... }:
  let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    forEachSystem = nixpkgs.lib.genAttrs systems;
  in {
    packages = forEachSystem (system: {
      # ... your packages
    });

    devShells = forEachSystem (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      podmanShell = podman-subshell.devShells.${system}.default;
    in {
      # Extend the podman devShell with your own packages and hooks
      default = pkgs.mkShell {
        inputsFrom = [ podmanShell ];
        packages = [
          # ... your additional packages
        ];
        shellHook = ''
          # The podman shellHook runs first via inputsFrom.
          # Add your own setup here.
        '';
      };
    });

    apps = forEachSystem (system: {
      # Optionally re-export (or replace with your own) help text
      help = podman-subshell.apps.${system}.help;
    });
  };
}
```

Then run `nix develop --impure` to enter the shell. Run `nix run .#help` for a summary of available environment variables.

### Flake-Parts Module

Import the module alongside your other flake-parts modules and set options under `podmanFlake`:

```/dev/null/flake.nix#L1-36
{
  description = "A project using flake-parts with isolated Podman";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    podman-subshell = {
      url = "github:mtalexan/podman-subshell-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ... your other inputs
  };

  outputs = {flake-parts, podman-subshell, ...}@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        podman-subshell.flakeModules.default
        # ... your other flakeModules
      ];

      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { config, pkgs, ... }: {
        # the config options for the podmanFlake
        podmanFlake = {
          enable = true;
          containersConfDir = ".my-podman";
          storageDriver = "overlay";
          netnsIsolate = true;
        };

        # ... your other perSystem config
      };
    };
}
```

Then run `nix develop` to enter the shell.  See [flake.nix](./flake.nix) for an example of how to map environment variables to module options (which requires using `nix develop --impure` to enter the shell).

---

## Using as a Standalone Flake

When used as a standalone flake, configuration is done through environment variables set before entering the devShell (requires `nix develop --impure`). In pure evaluation mode the defaults apply.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PODMAN_FLAKE_CONTAINERS_CONF` | `.podman-flake` | Directory for generated configs and storage. Relative paths resolve from the working directory. |
| `PODMAN_FLAKE_STORAGE_DRIVER` | Host driver, or `overlay` | Storage driver to use. Supported values: `overlay`, `vfs`. |
| `PODMAN_FLAKE_NETNS_ISOLATE` | unset | Any non-blank value isolates the rootless network namespace via a separate runroot directory. |

Example:

```/dev/null/example.sh#L1-3
export PODMAN_FLAKE_CONTAINERS_CONF=".my-podman"
export PODMAN_FLAKE_NETNS_ISOLATE=1
nix develop --impure
```

### Help Application

The flake provides a `help` app (`nix run .#help`) that prints a summary of environment variables, generated files, and their purposes. You can re-export this as-is, replace it with your own text, or extend it to cover project-specific details.

---

## Using as a Flake-Parts Module

When imported as a flake-parts module, configuration is done through Nix options under `perSystem.podmanFlake`. The module produces a `devShells.default` when imported.

### Module Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `podmanFlake.enable` | `bool` | `true` | Whether to enable the podmanFlake module. When `false`, no devShell or configuration is produced and is intended as an easy way to temporarily "comment out" the module. |
| `podmanFlake.containersConfDir` | `str` | `".podman-flake"` | Directory for generated configs and storage. Relative paths resolve from the working directory. |
| `podmanFlake.storageDriver` | `null` or `"overlay"` or `"vfs"` | `null` | Storage driver. When `null`, uses the host's driver or falls back to `"overlay"`. |
| `podmanFlake.netnsIsolate` | `bool` | `false` | Isolate the rootless network namespace from the host via a separate runroot directory. |

### Mapping Environment Variables to Module Options

If you want to support environment-variable overrides alongside the module options (e.g. for `--impure` workflows or direnv), see the `perSystem` block in [`flake.nix`](./flake.nix) for an example of how to map `PODMAN_FLAKE_*` variables to `podmanFlake.*` options using `lib.mkIf` and `builtins.getEnv`.

---

## How It Works

On each devShell entry, a `shellHook` populates the configuration directory, set via `PODMAN_FLAKE_CONTAINERS_CONF` / `podmanFlake.containersConfDir`, with isolated Podman configuration. On the first entry the files are created from scratch; on subsequent entries only Nix store paths are updated — manual edits you've made are preserved.  Tools that must be provided by the devShell however are always updated in the file.

The devShell exports `CONTAINERS_STORAGE_CONF` and `CONTAINERS_CONF` environment variables pointing into the configuration directory, which is what makes podman, buildah, and skopeo always look for when called and will use instead of their hardcoded defaults.

### Host Configuration Discovery

Podman's own libraries merge configuration in this order, where each layer overrides fields from the previous:

1. Compiled-in defaults (hardcoded, not in any file)
2. `/usr/share/containers/*.conf` (vendor/distro defaults)
3. `/etc/containers/*.conf` (admin overrides)
4. User config (`$XDG_CONFIG_HOME/containers/*.conf`, or as set by `$CONTAINERS_STORAGE_CONF` / `$CONTAINERS_CONF`)

The devShell follows this same layered hierarchy when discovering host settings. It merges all discovered layers of the host's `storage.conf` into a single view to extract the effective host storage driver, graphroot, additional image stores, and runroot. Similarly, it inspects the host `containers.conf` layers for engine and network configuration.  

If no host configuration exists, default values are supplied that are robust across the majority of system configurations.

### storage.conf

On first creation:

1. **Initial template** — the file is seeded from the first available source: the user's `storage.conf`, any host vendor/admin layer, the Nix-packaged podman default, or a minimal built-in fallback.
2. **Storage driver** — set to the value of `PODMAN_FLAKE_STORAGE_DRIVER` / `podmanFlake.storageDriver`. When not specified, the host's driver is used, falling back to `overlay`.
3. **Graphroot** — pointed at `<conf_dir>/storage/`, a local directory for this devShell's container images and layers.
4. **Additional image stores** — the host's graphroot (if it exists on disk) and any additional stores from the host configuration are added as read-only image stores. This means images already pulled on the host are available inside the devShell without re-downloading.
5. **Runroot** — when `PODMAN_FLAKE_NETNS_ISOLATE` is non-blank / `podmanFlake.netnsIsolate` is `true`, the runroot is set to `<conf_dir>/storage-run/`, isolating the rootless network namespace. Without isolation, the host's runroot is used and a warning is emitted noting that named networks may conflict.
6. **Overlay driver** — when the storage driver is `overlay` and the host was *not* already using overlay (i.e. the host uses `vfs` or has no configuration), `fuse-overlayfs` from the devShell's Nix packages is configured as the `mount_program`. When the host is already using overlay, its existing overlay/fuse-overlayfs setup is used verbatim.

On subsequent entries, only targeted updates are applied: the storage driver is updated if explicitly set, Nix store paths (like the `fuse-overlayfs` binary) are refreshed, and runroot isolation settings are reapplied. All other fields are left as-is.

### containers.conf

On first creation:

1. **Initial template** — seeded from the user's `containers.conf`, a host vendor/admin layer, the Nix-packaged default, or a minimal fallback that sets `events_logger`, `cgroup_manager`, and `image_copy_tmp_dir`.
2. **Cgroup manager** — when no host configuration exists, the script auto-detects whether systemd is running and sets `cgroup_manager` to `"systemd"` if so, falling back to `"cgroupfs"` otherwise.
3. **Runtime tools** — `crun` and `conmon` paths are set to the Nix store binaries from the devShell.
4. **Helper binaries** — the `helper_binaries_dir` list is populated with Nix store paths for `passt`, `netavark`, and `aardvark-dns`, merged with any existing entries.
5. **Network config directory** — pointed at `<conf_dir>/networks/` for named network configuration files.

On subsequent entries, runtime tool paths and helper binary directories are updated to current Nix store paths, replacing any stale `/nix/store/...` entries while preserving non-Nix paths you may have added.

### registries.conf and policy.json

These files are created only on first entry and never modified afterward. Each is copied from the first available source in this order:

1. `$XDG_CONFIG_HOME/containers/`
2. `/etc/containers/`
3. `/usr/share/containers/`
4. The Nix-packaged podman share directory

---

## Generated Files Summary

| Path | Purpose |
|------|---------|
| `storage.conf` | Storage driver, graphroot, overlay settings, additional image stores |
| `containers.conf` | Engine, runtime tools, helper binaries, network configuration |
| `registries.conf` | Container image registry search configuration |
| `policy.json` | Image signature verification policy |
| `storage/` | Local container image and layer storage (graphroot) |
| `storage-run/` | Isolated runtime state (only when network namespace isolation is enabled) |
| `networks/` | Named network configuration files |

## Platform Support

Linux only: `x86_64-linux` and `aarch64-linux`.

macOS is not supported because Podman on macOS uses a fundamentally different architecture (Podman machines / VMs).

## License

See [LICENSE](./LICENSE).
