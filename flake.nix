{
  # DESCRIPTION
  #   Defines a single (default) nix devShell that provides a fixed set of
  #   podman + skopeo + buildah tools with isolated container storage.
  #   Host configuration is inherited where possible, with the flake's own
  #   graphroot for local image cache defaulting to the current project folder.

  description = "DevShell with isolated container storage and host system images as read-only store";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      # can't include darwin targets because podman on MacOS works completely differently (podman machines)
      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { pkgs, ... }:
      let

        # Default minimal containers.conf when no settings exist at all (no host config, and no nixpkgs config).
        # Safe fallbacks for unknown environments.
        # The cgroup_manager gets replaced if we detect that systemd is in use on the host.
        # The runroot and graphroot will always get dynamically set to subfolders of the PODMAN_FLAKE_CONF.
        defaultContainersConf = pkgs.writeText "default-containers.conf" ''
          [engine]
          events_logger = "file"
          cgroup_manager = "cgroupfs"
          image_copy_tmp_dir = "/tmp"
        '';

        # Default minimal storage.conf when no settings exist at all (no host config, and no nixpkgs config).
        # Safe fallbacks for unknown environments.
        # If we use this file, and don't change the driver from overlay, the overlay will use fuse-overlayfs
        # which requires additional dynamically populated settings.
        defaultStorageConf = pkgs.writeText "default-storage.conf" ''
          [storage]
          driver = "overlay"
          transient_store = true
        '';

        helpTextFile = pkgs.writeText "podman-flake-help.txt" ''
          podman-flake — DevShell with isolated container storage

          ENVIRONMENT VARIABLES

            Set these before entering the devShell (e.g. export VAR=value before
            running 'nix develop'), or in a .envrc file with direnv.

            PODMAN_FLAKE_CONTAINERS_CONF  (default: .podman-flake)
                The directory under which all generated configs and default
                storage live. Relative paths are resolved from the working
                directory. Should only be shared among flakes with the same
                PODMAN_FLAKE_STORAGE_DRIVER and roughly similar podman version.

            PODMAN_FLAKE_STORAGE_DRIVER  (default: host driver, or 'overlay')
                The podman storage driver to use. Supported values: overlay, vfs.
                Defaults to the current host environment's driver, or falls back
                to 'overlay' if no host configuration is found.

            PODMAN_FLAKE_NETNS_ISOLATE  (default: unset)
                If non-blank, isolate the rootless network namespace from the host
                by using a separate runroot directory. Without this, podman named
                networks can conflict with all other non-isolated podman named
                networks on the system.
                Even with this set, explicit subnets must still be globally unique
                since routing shares the kernel network stack.

          GENERATED FILES

            The configuration directory contains the following files, generated on
            first entry from host settings or safe defaults. On subsequent entries,
            only Nix store paths are updated — manual edits are preserved.

              storage.conf      Storage driver, paths, and overlay settings
              containers.conf   Engine, runtime, and network configuration
              registries.conf   Container image registry configuration
              policy.json       Container image signature verification policy

            Storage and state directories:

              storage/          Local container image and layer storage (graphroot)
              storage-run/      Isolated runtime state (when NETNS_ISOLATE is set)
              networks/         Named network configuration files
        '';

        helpScript = pkgs.writeShellScriptBin "podman-flake-help" ''
          ${pkgs.coreutils}/bin/cat ${helpTextFile}
        '';

      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            podman
            buildah
            skopeo
            # have to include these explicitly because they're "optional" backend tools for podman/buildah
            crun
            conmon
            passt
            fuse-overlayfs
            # networking backend — must match podman version so we have to provide our own.
            netavark
            aardvark-dns
            # dasel for TOML config file manipulation, jq for JSON operations. yq-go can't handle podman TOML config files.
            dasel
            jq
          ];
          
          shellHook = ''
            ########################
            # Populate configuration directory
            #
            # This function runs in a subshell to avoid polluting the devShell
            # environment with temporary variables. It takes a single argument:
            # the directory to use for all generated configs and default storage.

            _podman_flake_populate_conf_dir() (
                local conf_dir="$1"

                ########################
                # Helper functions (local to this subshell — cannot leak into the
                # devShell environment because the entire function body is a subshell)

                # Discover host config layers for a given config filename.
                # Populates the nameref array and user-conf path variable.
                # Args: 
                #   1: <layers_array_nameref> for the array to populate with the merge-ordered list of existing host config files.
                #   2: <user_conf_nameref> for the name of the user host config file, if any
                #   3: <filename> the file name we're looking for in these folders
                #   4: <user_conf_path> the user config path. This can be set by an environment variable, or XDG, or just a default path, you tell me.
                _discover_host_layers() {
                    local -n _layers="$1"
                    local -n _user_conf="$2"
                    local filename="$3"
                    local user_conf_path="$4"

                    _layers=()
                    _user_conf=""

                    [[ -f "/usr/share/containers/$filename" ]] && _layers+=("/usr/share/containers/$filename")
                    [[ -f "/etc/containers/$filename" ]] && _layers+=("/etc/containers/$filename")

                    if [[ -f "$user_conf_path" ]]; then
                        _user_conf="$user_conf_path"
                        _layers+=("$user_conf_path")
                    fi
                }

                # Select initial config file from available sources (user → vendor/admin → nixpkg → default).
                # Args:
                #   1: <output_file> absolute path  of the file to populate
                #   2: <host_user_conf> path to the host user config file if any
                #   3: <host_layers_count> number of host config files found (including user config)
                #   4: <nixpkg_conf> directory of the nixpkg-shipped config file, if any
                #   5: <fallback_conf> 
                _select_initial_conf() {
                    local output="$1"
                    local host_user="$2"
                    local layers_count="$3"
                    local nixpkg="$4"
                    local fallback="$5"

                    if [[ -n "$host_user" && -f "$host_user" ]]; then
                        cp "$host_user" "$output"
                    elif (( layers_count > 0 )); then
                        printf "" > "$output"
                    elif [[ -f "$nixpkg" ]]; then
                        cp "$nixpkg" "$output"
                    else
                        cp "$fallback" "$output"
                    fi
                }

                # Build a JSON array string of helper binary dirs from the provided list of package paths.
                # Each package path has '/bin' appended to it.
                # Args:
                #   *: the nix pkg paths for the helper binaries. I.e. the ''${pkgs.xxx}
                # Ooutput:
                #   JSON array string to stdout.
                _build_helpers_json() {
                    local pkg_list=("$@")
                
                    local result="["
                    local sep=""
                    local pkg
                    for pkg in "''${pkg_list[@]}"; do
                        result+="''${sep}\"''${pkg}/bin\""
                        sep=","
                    done
                    result+="]"
                    echo "$result"
                }

                # Set runtime tool paths in a containers.conf file (always needed for nix version match).
                # Args: 
                #   1: <conf_file>
                _set_runtime_tools() {
                    local conf_file="$1"
                    dasel put -f "$conf_file" -r toml -w toml -t string -v "crun" '.engine.runtime'
                    dasel put -f "$conf_file" -r toml -w toml -t json -v "[\"${pkgs.conmon}/bin/conmon\"]" '.engine.conmon_path'
                    dasel put -f "$conf_file" -r toml -w toml -t json -v "[\"${pkgs.crun}/bin/crun\"]" '.engine.runtimes.crun'
                }

                # Copy a config file from the first directory that contains it.
                # Args: 
                #   1: <output_path> absolute path of the file to create
                #   2: <filename> name of the file we're looking for to copy (e.g., "storage.conf")
                #   3-*: <search_dirs...> list of directories to search for it in.
                _copy_first_available() {
                    local output="$1" 
                    local filename="$2"
                    shift 2
                    
                    local dir
                    for dir in "$@"; do
                        if [[ -f "$dir/$filename" ]]; then
                            cp "$dir/$filename" "$output"
                            return 0
                        fi
                    done
                    return 1
                }

                ########################
                # Host config file detection
                #
                # The containers/storage and containers/common libraries merge config files
                # in this order (each layer overrides fields set in previous layers):
                #   1. Compiled-in defaults (hardcoded in the library — not in any file)
                #   2. /usr/share/containers/*.conf (vendor/distro defaults)
                #   3. /etc/containers/*.conf (admin overrides)
                #   4. User config (env var location or XDG default)
                #
                # Any of these paths may or may not exist. We must merge all that do exist,
                # not just pick the highest-priority one.
                #
                # We build arrays containing only files that actually exist, in merge order.
                # This makes the merge loops trivial (they naturally skip on empty arrays)
                # and eliminates the need for separate "does host config exist?" flags.

                # Respect XDG base directories for default per-user config locations
                local xdg_config_home="''${XDG_CONFIG_HOME:-$HOME/.config}"

                # storage.conf layers (in merge order: vendor → admin → user)
                # The full layer list is used to merge and read effective host settings.
                # The user config path is tracked separately because the nix-provided podman
                # still reads vendor/admin configs directly from /usr/share/ and /etc/ —
                # our generated file only needs to carry the user layer + our overrides.
                local host_user_storage_conf
                local host_storage_conf_layers
                _discover_host_layers host_storage_conf_layers host_user_storage_conf "storage.conf" \
                    "''${CONTAINERS_STORAGE_CONF:-$xdg_config_home/containers/storage.conf}"

                # containers.conf layers (same approach)
                local host_user_containers_conf
                local host_containers_conf_layers
                _discover_host_layers host_containers_conf_layers host_user_containers_conf "containers.conf" \
                    "''${CONTAINERS_CONF:-$xdg_config_home/containers/containers.conf}"

                ########################
                # Build merged host storage config
                #
                # Merge all existing host config layers in priority order to produce the
                # effective host configuration. This matches how containers/storage itself
                # would resolve settings across all config files.
                # If no host layers exist, the file remains empty — downstream reads will
                # simply get empty/default values, which is handled naturally.

                local merged_host_storage_conf="$conf_dir/.host-storage-merged.conf"
                rm -f "$merged_host_storage_conf"
                touch "$merged_host_storage_conf"
                local layer
                local json_base json_layer
                for layer in "''${host_storage_conf_layers[@]}"; do
                    # Deep merge: higher-priority layer's values override, unset fields preserved
                    json_base=$(dasel -f "$merged_host_storage_conf" -r toml -w json '.' 2>/dev/null || echo '{}')
                    json_layer=$(dasel -f "$layer" -r toml -w json '.' 2>/dev/null || echo '{}')
                    jq          -n \
                                --argjson a "$json_base" \
                                --argjson b "$json_layer" \
                                '$a * $b' \
                            | dasel -r json -w toml > "$merged_host_storage_conf.tmp" \
                        && mv "$merged_host_storage_conf.tmp" "$merged_host_storage_conf"
                done
                # clean up any leftover tmp file
                rm -f "$merged_host_storage_conf.tmp"

                ########################
                # Host settings
                #
                # Read effective host values from the merged config (empty values if no host
                # config existed). We cannot use `podman info` here because the shellHook
                # runs after Nix has already prepended its own podman to PATH. Additionally,
                # not all values we need are even available from `podman info`.

                # Convert merged config to JSON once for efficient querying
                local merged_json
                merged_json=$(dasel -f "$merged_host_storage_conf" -r toml -w json '.' 2>/dev/null || echo '{}')

                local host_driver
                host_driver=$(echo "$merged_json" | jq -r '.storage.driver // ""')
                local host_graphroot
                host_graphroot=$(echo "$merged_json" | jq -r '.storage.graphroot // ""')
                local host_additional_stores
                host_additional_stores=$(echo "$merged_json" | jq '.storage.options.additionalimagestores // []')
                local host_runroot
                host_runroot=$(echo "$merged_json" | jq -r '.storage.runroot // ""')

                # If graphroot wasn't explicitly set in any config file, use the standard rootless default
                if [[ -z "$host_graphroot" ]]; then
                    host_graphroot="''${XDG_DATA_HOME:-$HOME/.local/share}/containers/storage"
                fi

                # Build our additionalimagestores JSON array
                local additional_stores_json="[]"

                # Add host graphroot first (highest priority) if it exists on disk so we can still access it as a read-only store.
                if [[ -d "$host_graphroot" ]]; then
                    additional_stores_json=$(echo "$additional_stores_json" | jq --arg g "$host_graphroot" '. + [$g]')
                fi

                # Add host's existing additionalimagestores in their original order
                if [[ "$host_additional_stores" != "null" && "$host_additional_stores" != "[]" ]]; then
                    additional_stores_json=$(echo "$additional_stores_json" | jq --argjson s "$host_additional_stores" '. + $s')
                fi

                # done parsing settings from it, so remove it
                rm -f "$merged_host_storage_conf"

                ########################
                # Storage settings

                # Determine which storage driver to use. Default to 'overlay' if not specified and no host driver.
                local storage_driver="''${PODMAN_FLAKE_STORAGE_DRIVER:-''${host_driver:-overlay}}"

                # Map driver name to storage.conf driver name and validate
                case "$storage_driver" in
                    overlayfs|overlay)
                        storage_driver="overlay"
                        ;;
                    vfs)
                        storage_driver="vfs"
                        ;;
                    *)
                        echo "Warning: Unknown storage driver '$storage_driver', defaulting to overlay" >&2
                        storage_driver="overlay"
                        ;;
                esac

                # Storage location is always 'storage' under the conf directory
                local storage_path="$conf_dir/storage"

                ########################
                # Generate storage.conf
                #
                # The nix-provided podman still reads vendor (/usr/share/) and admin (/etc/)
                # configs directly. Our generated file replaces the user config layer, so:
                #   1. User config exists → copy it as starting point
                #   2. No user config, but vendor/admin exist → start empty (podman already
                #      reads those layers directly; we only add our required overrides)
                #   3. No host config at all, nixpkg has one → copy as starting point
                #   4. Nothing at all → use our built-in default
                #
                # If a config file already exists in the conf dir (from a prior run, possibly
                # with user modifications), we preserve it and only update:
                #   - Nix store paths (always replace with current nixpkg versions)
                #   - Storage driver (only if PODMAN_FLAKE_STORAGE_DRIVER is explicitly set)
                #   - Runroot (if PODMAN_FLAKE_NETNS_ISOLATE is set, or host specifies one)

                local storage_conf="$conf_dir/storage.conf"

                if [[ -f "$storage_conf" ]]; then
                    # === EXISTING FILE: preserve user modifications, apply targeted updates ===

                    # Storage driver: only update if explicitly overridden via env var
                    if [[ -n "''${PODMAN_FLAKE_STORAGE_DRIVER:-}" ]]; then
                        dasel put -f "$storage_conf" -r toml -w toml -t string -v "$storage_driver" '.storage.driver'
                    fi

                    # Runroot handling
                    local runroot
                    if [[ -n "''${PODMAN_FLAKE_NETNS_ISOLATE:-}" ]]; then
                        # Force isolated runroot for separate rootless-netns
                        runroot="''${storage_path}-run"
                        mkdir -p "$runroot"
                        dasel put -f "$storage_conf" -r toml -w toml -t string -v "$runroot" '.storage.runroot'
                    elif [[ -n "$host_runroot" ]]; then
                        # Host specifies a runroot — use it for shared netns
                        dasel put -f "$storage_conf" -r toml -w toml -t string -v "$host_runroot" '.storage.runroot'
                        echo "WARNING: Shared netns, named networks must not conflict. Set PODMAN_FLAKE_NETNS_ISOLATE=1 to isolate the runroot and avoid this." >&2
                    fi

                    # Nixpkg path: fuse-overlayfs mount_program — only replace if already a nix store path
                    local existing_mount_program
                    existing_mount_program=$(dasel -f "$storage_conf" -r toml -w json '.storage.options.overlay.mount_program' 2>/dev/null | jq -r '.' 2>/dev/null || echo "")
                    if [[ "$existing_mount_program" == /nix/store/* ]]; then
                        dasel put -f "$storage_conf" -r toml -w toml -t string -v "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs" '.storage.options.overlay.mount_program'
                    fi

                else
                    # === FRESH FILE: create and fully configure ===

                    _select_initial_conf "$storage_conf" "$host_user_storage_conf" \
                        "''${#host_storage_conf_layers[@]}" \
                        "${pkgs.podman}/share/containers/storage.conf" \
                        "${defaultStorageConf}"

                    # Apply required storage overrides
                    dasel put -f "$storage_conf" -r toml -w toml -t string -v "$storage_driver" '.storage.driver'
                    dasel put -f "$storage_conf" -r toml -w toml -t string -v "$storage_path" '.storage.graphroot'
                    mkdir -p "$storage_path"

                    # Runroot handling — controlled by PODMAN_FLAKE_NETNS_ISOLATE
                    local existing_runroot
                    existing_runroot=$(dasel -f "$storage_conf" -r toml -w json '.storage.runroot' 2>/dev/null | jq -r '.' 2>/dev/null || echo "")
                    local runroot
                    if [[ -n "''${PODMAN_FLAKE_NETNS_ISOLATE:-}" ]] || [[ -z "$existing_runroot" ]]; then
                        # Force isolated runroot for separate rootless-netns
                        runroot="''${storage_path}-run"
                        mkdir -p "$runroot"
                        dasel put -f "$storage_conf" -r toml -w toml -t string -v "$runroot" '.storage.runroot'
                    else
                        # Using host's runroot — shared netns
                        echo "WARNING: Shared netns, named networks must not conflict. Set PODMAN_FLAKE_NETNS_ISOLATE=1 to isolate the runroot and avoid this." >&2
                    fi

                    dasel put -f "$storage_conf" -r toml -w toml -t string -v "$storage_path" '.storage.imagestore'
                    dasel put -f "$storage_conf" -r toml -w toml -t string -v "$storage_path" '.storage.rootless_storage_path'
                    dasel put -f "$storage_conf" -r toml -w toml -t json -v "$additional_stores_json" '.storage.options.additionalimagestores'

                    # If we're using overlay driver, and the host also was, keep all the host settings.
                    # If the host wasn't using overlay, or we have no host config, we need to wipe and fully
                    # configure all overlay settings to use our fuse-overlayfs.

                    local own_overlay=false
                    if [[ "$storage_driver" == "overlay" ]]; then
                        case "$host_driver" in
                            overlay|overlayfs)
                                # Host already runs overlay (kernel or fuse) — trust its config
                                own_overlay=false
                                ;;
                            *)
                                # Host doesn't have overlay — we introduce it via fuse-overlayfs
                                own_overlay=true
                                ;;
                        esac
                    fi

                    if [[ "$own_overlay" == "true" ]]; then
                        # Wipe all existing overlay options — they may be kernel-overlay-specific
                        # (e.g., metacopy=on, volatile, userxattr) which are incompatible with fuse-overlayfs
                        dasel delete -f "$storage_conf" -r toml -w toml '.storage.options.overlay' 2>/dev/null || true
                        # Set fuse-overlayfs as mount program
                        dasel put -f "$storage_conf" -r toml -w toml -t string -v "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs" '.storage.options.overlay.mount_program'
                        # Set default fuse-overlayfs-compatible mount options
                        dasel put -f "$storage_conf" -r toml -w toml -t string -v "nodev" '.storage.options.overlay.mountopt'
                    fi
                fi

                ########################
                # Generate containers.conf
                #
                # Same approach as storage.conf — preserve existing file if present.
                # If a config file already exists in the conf dir (from a prior run, possibly
                # with user modifications), we preserve it and only update nix store paths.

                # Helper binary packages provided by this flake. Each entry is the nix store
                # path for the package (without /bin). The /bin suffix, package name, and
                # regex pattern are all derived from this single definition.
                local flake_helper_pkgs=("${pkgs.passt}" "${pkgs.netavark}" "${pkgs.aardvark-dns}")

                local containers_conf="$conf_dir/containers.conf"

                if [[ -f "$containers_conf" ]]; then
                    # === EXISTING FILE: preserve user modifications, update nixpkg paths ===

                    # Tools provided by this flake — always update nix store paths
                    _set_runtime_tools "$containers_conf"

                    # helper_binaries_dir — smart replacement of nix store paths.
                    # The existing array may contain: nix store paths from a prior run, host paths,
                    # and manual user additions. For each nixpkg we provide, remove the old nix
                    # store entry for the same package (if any), then prepend all our paths at
                    # the front so they take priority (first-match-wins, like PATH).
                    local current_helpers
                    current_helpers=$(dasel -f "$containers_conf" -r toml -w json '.engine.helper_binaries_dir' 2>/dev/null || echo '[]')

                    local pkg store_basename name_ver name pattern
                    for pkg in "''${flake_helper_pkgs[@]}"; do
                        # Extract package name from nix store path: /nix/store/<32-char-hash>-<name>-<version>
                        store_basename="''${pkg##*/}"
                        name_ver="''${store_basename:33}"
                        name="''${name_ver%%-[0-9]*}"
                        pattern="/nix/store/[a-z0-9]{32}-''${name}-"
                        # Remove any existing entry for this package (old nix store path from prior run)
                        current_helpers=$(echo "$current_helpers" | jq --arg p "$pattern" '[.[] | select(test($p) | not)]')
                    done

                    # Prepend all our helper paths at once, in defined order (first-match-wins)
                    local helpers_json
                    helpers_json=$(_build_helpers_json "''${flake_helper_pkgs[@]}")
                    local merged_helpers
                    merged_helpers=$(jq -n --argjson new "$helpers_json" --argjson cur "$current_helpers" '$new + $cur')
                    dasel put -f "$containers_conf" -r toml -w toml -t json -v "$merged_helpers" '.engine.helper_binaries_dir'

                else
                    # === FRESH FILE: create and fully configure ===

                    _select_initial_conf "$containers_conf" "$host_user_containers_conf" \
                        "''${#host_containers_conf_layers[@]}" \
                        "${pkgs.podman}/share/containers/containers.conf" \
                        "${defaultContainersConf}"

                    # When no host settings exist at all (no vendor, admin, or user configs),
                    # detect if we need systemd cgroup manager. If any host config exists,
                    # it already handles this correctly.
                    if (( ''${#host_containers_conf_layers[@]} == 0 )); then
                        if [[ -d /run/systemd/system ]] && systemctl --user status >/dev/null 2>&1; then
                            dasel put -f "$containers_conf" -r toml -w toml -t string -v "systemd" '.engine.cgroup_manager'
                        fi
                    fi

                    # Tools provided by this flake — must always be updated to ensure version match.
                    _set_runtime_tools "$containers_conf"

                    # helper_binaries_dir — prepend our paths so flake versions are found first
                    # (first-match-wins, like PATH). Covers pasta, netavark, aardvark-dns.
                    local helpers_json
                    helpers_json=$(_build_helpers_json "''${flake_helper_pkgs[@]}")
                    current_helpers=$(dasel -f "$containers_conf" -r toml -w json '.engine.helper_binaries_dir' 2>/dev/null || echo '[]')
                    local merged_helpers
                    merged_helpers=$(jq -n --argjson new "$helpers_json" --argjson cur "$current_helpers" '$new + $cur')
                    dasel put -f "$containers_conf" -r toml -w toml -t json -v "$merged_helpers" '.engine.helper_binaries_dir'

                    # Network configuration — always isolated per flake instance.
                    # Named network configs go in here and have to be unique for each netavark.
                    # WARNING: Creating these networks populates the runroot netns, so all interfaces named in these files
                    #          must be unique per runroot. The PODMAN_FLAKE_NETNS_ISOLATE=1 can ensure a unique runroot.
                    local net_dir="$conf_dir/networks"
                    mkdir -p "$net_dir"
                    dasel put -f "$containers_conf" -r toml -w toml -t string -v "$net_dir" '.network.network_config_dir'
                fi

                ########################
                # Registries and policy

                # Look for registries.conf and policy.json in the standard container config
                # directories (user → admin → vendor), matching the same priority order.
                # If none are found, fall back to the nixpkg-shipped versions.

                # registries.conf — only create if not already present
                if [[ ! -f "$conf_dir/registries.conf" ]]; then
                    _copy_first_available "$conf_dir/registries.conf" "registries.conf" \
                        "$xdg_config_home/containers" "/etc/containers" "/usr/share/containers" \
                        "${pkgs.podman}/share/containers"
                fi

                # policy.json — only create if not already present
                if [[ ! -f "$conf_dir/policy.json" ]]; then
                    _copy_first_available "$conf_dir/policy.json" "policy.json" \
                        "$xdg_config_home/containers" "/etc/containers" "/usr/share/containers" \
                        "${pkgs.podman}/share/containers"
                fi
            )

            ########################
            # Configuration directory

            _conf_dir="''${PODMAN_FLAKE_CONTAINERS_CONF:-.podman-flake}"
            # Convert to absolute path if relative
            if [[ "$_conf_dir" != /* ]]; then
                _conf_dir="$PWD/$_conf_dir"
            fi
            mkdir -p "$_conf_dir"

            # Populate the configuration directory
            _podman_flake_populate_conf_dir "$_conf_dir"
            unset -f _podman_flake_populate_conf_dir

            ########################
            # Export environment
            #
            # Point container tools to our custom configs.
            export CONTAINERS_STORAGE_CONF="$_conf_dir/storage.conf"
            export CONTAINERS_CONF="$_conf_dir/containers.conf"
            unset _conf_dir

            # Shell function to display help — available throughout the devShell session
            podman-flake-help() {
              cat ${helpTextFile}
            }

            echo "hint: Run 'podman-flake-help' for configuration options."
          '';
        };

        apps.help = {
          type = "app";
          program = "${helpScript}/bin/podman-flake-help";
          meta.description = "Show environment variables and configuration options for the podman devShell";
        };
      };
    };
}
