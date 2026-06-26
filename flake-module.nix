# A flake-parts module.
# Provides options under 'podmanFlake', and a devShells.default.
# 
# The devShell includes the packages needed for podman, buildah, and skopeo,
# and a shellHook that generates isolated containers_storage and podman settings
# in a local folder, largely duplicated from the host environment where/if possible.
# See the nix options for settings that affect where the isolated settings are kept,
# and configuration tweaks.

{ lib, flake-parts-lib, ... }:
let
  inherit (lib) mkOption types optionalString;
  inherit (flake-parts-lib) mkPerSystemOption;
in
{
  options.perSystem = mkPerSystemOption ({ config, pkgs, lib, ... }:
  let
    cfg = config.podmanFlake;
  in
  {
    options.podmanFlake = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to enable the podmanFlake module. When false, no devShell
          or configuration is produced by this module.
        '';
      };

      containersConfDir = mkOption {
        type = types.str;
        default = ".podman-flake";
        description = ''
          Directory under which all generated configs and default storage live.
          Relative paths are resolved from the working directory at devShell
          entry time. Should only be shared among flakes with the same
          storageDriver and roughly similar podman version.

          The following files are generated on first entry from host settings
          or safe defaults. On subsequent entries, only Nix store paths are
          updated — manual edits are preserved.

            storage.conf      Storage driver, paths, and overlay settings
            containers.conf   Engine, runtime, and network configuration
            registries.conf   Container image registry configuration
            policy.json       Container image signature verification policy

          Storage and state directories:

            storage/          Local container image and layer storage (graphroot)
            storage-run/      Isolated runtime state (when netnsIsolate is true)
            networks/         Named network configuration files
        '';
      };

      storageDriver = mkOption {
        type = types.nullOr (types.enum [ "overlay" "vfs" ]);
        default = null;
        description = ''
          The podman storage driver to use. When null, defaults to the host
          environment's driver, or falls back to "overlay" if no host
          configuration is found.
          When set to "overlay", implicity or explicitly, the host configuration
          is checked to see if it was also set to "overlay". If there is a host configuration
          and it is set to "overlay", fuse-overlayfs from the devmShell is not used
          and the overlayfs or fuse-overlayfs driver from the host configuration is used
          verbatim instead.

          WARNING: The "safe" option here is vfs because it requires no kernel or fuse overlay driver,
                   but the performance is significantly worse than overlayfs. The nix-provided fuse-overlayfs
                   is used as a backup solution that is still performant.
        '';
      };

      netnsIsolate = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Isolate the rootless network namespace from the host by using a
          separate runroot directory. Without this, podman named networks share a
          namespace with the default runroot and can conflict with networks from
          the host or other unisolated devShells.
          
          WARNING: 'podman container ls' and 'podman network ls' commands from separate
                    runroots are unaware of each other.
          WARNING: Even with this enabled, explicit subnets must still be globally
                   unique since kernel routing tables are always globally shared.
        '';
      };

    };

    config = lib.mkIf cfg.enable (
    let
      # Create a script that will do the heavy lifting, so that when we run it the variables and functions
      # we use for implementation don't polluate the final shellHook environment.
      populateScript = pkgs.writeShellScriptBin "podman-flake-populate-conf" ''
        export PATH="${pkgs.dasel}/bin:${pkgs.jq}/bin:${pkgs.coreutils}/bin:$PATH"

        CONMON_BIN="${pkgs.conmon}/bin/conmon"
        CRUN_BIN="${pkgs.crun}/bin/crun"
        FUSE_OVERLAYFS_BIN="${pkgs.fuse-overlayfs}/bin/fuse-overlayfs"
        PASST_PKG="${pkgs.passt}"
        NETAVARK_PKG="${pkgs.netavark}"
        AARDVARK_DNS_PKG="${pkgs.aardvark-dns}"
        PODMAN_SHARE="${pkgs.podman}/share/containers"

        conf_dir=""
        storage_driver_arg=""
        netns_isolate=false

        while [[ $# -gt 0 ]]; do
            case "$1" in
                --conf-dir)
                    conf_dir="$2"
                    shift 2
                    ;;
                --storage-driver)
                    storage_driver_arg="$2"
                    shift 2
                    ;;
                --netns-isolate)
                    netns_isolate=true
                    shift
                    ;;
                *)
                    echo "Unknown argument: $1" >&2
                    exit 1
                    ;;
            esac
        done

        if [[ -z "$conf_dir" ]]; then
            echo "Error: --conf-dir is required" >&2
            exit 1
        fi

        ########################
        # Helper functions

        # Discover host config layers for a given config filename.
        # Populates the nameref array and user-conf path variable.
        # Args:
        #   1: <layers_array_nameref>
        #   2: <user_conf_nameref>
        #   3: <filename>
        #   4: <user_conf_path>
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

        # Build a JSON array string of helper binary dirs from the provided
        # list of package paths. Each package path has '/bin' appended.
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

        # Set runtime tool paths in a containers.conf file.
        _set_runtime_tools() {
            local conf_file="$1"
            dasel put -f "$conf_file" -r toml -w toml -t string -v "crun" '.engine.runtime'
            dasel put -f "$conf_file" -r toml -w toml -t json -v "[\"$CONMON_BIN\"]" '.engine.conmon_path'
            dasel put -f "$conf_file" -r toml -w toml -t json -v "[\"$CRUN_BIN\"]" '.engine.runtimes.crun'
        }

        # Copy a config file from the first directory that contains it.
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
        # The containers/storage and containers/common libraries merge config
        # files in this order (each layer overrides fields set in previous):
        #   1. Compiled-in defaults (hardcoded — not in any file)
        #   2. /usr/share/containers/*.conf (vendor/distro defaults)
        #   3. /etc/containers/*.conf (admin overrides)
        #   4. User config (env var location or XDG default)

        xdg_config_home="''${XDG_CONFIG_HOME:-$HOME/.config}"

        # storage.conf layers
        host_user_storage_conf=""
        host_storage_conf_layers=()
        _discover_host_layers host_storage_conf_layers host_user_storage_conf "storage.conf" \
            "''${CONTAINERS_STORAGE_CONF:-$xdg_config_home/containers/storage.conf}"

        # containers.conf layers
        host_user_containers_conf=""
        host_containers_conf_layers=()
        _discover_host_layers host_containers_conf_layers host_user_containers_conf "containers.conf" \
            "''${CONTAINERS_CONF:-$xdg_config_home/containers/containers.conf}"

        ########################
        # Build merged host storage config

        merged_host_storage_conf="$conf_dir/.host-storage-merged.conf"
        rm -f "$merged_host_storage_conf"
        touch "$merged_host_storage_conf"
        for layer in "''${host_storage_conf_layers[@]}"; do
            json_base=$(dasel -f "$merged_host_storage_conf" -r toml -w json '.' 2>/dev/null || echo '{}')
            json_layer=$(dasel -f "$layer" -r toml -w json '.' 2>/dev/null || echo '{}')
            jq      -n \
                    --argjson a "$json_base" \
                    --argjson b "$json_layer" \
                    '$a * $b' \
                | dasel -r json -w toml > "$merged_host_storage_conf.tmp" \
              && mv "$merged_host_storage_conf.tmp" "$merged_host_storage_conf"
        done
        rm -f "$merged_host_storage_conf.tmp"

        ########################
        # Host settings

        merged_json=$(dasel -f "$merged_host_storage_conf" -r toml -w json '.' 2>/dev/null || echo '{}')

        host_driver=$(echo "$merged_json" | jq -r '.storage.driver // ""')
        host_graphroot=$(echo "$merged_json" | jq -r '.storage.graphroot // ""')
        host_additional_stores=$(echo "$merged_json" | jq '.storage.options.additionalimagestores // []')
        host_runroot=$(echo "$merged_json" | jq -r '.storage.runroot // ""')

        if [[ -z "$host_graphroot" ]]; then
            host_graphroot="''${XDG_DATA_HOME:-$HOME/.local/share}/containers/storage"
        fi

        additional_stores_json="[]"

        if [[ -d "$host_graphroot" ]]; then
            additional_stores_json=$(echo "$additional_stores_json" | jq --arg g "$host_graphroot" '. + [$g]')
        fi

        if [[ "$host_additional_stores" != "null" && "$host_additional_stores" != "[]" ]]; then
            additional_stores_json=$(echo "$additional_stores_json" | jq --argjson s "$host_additional_stores" '. + $s')
        fi

        rm -f "$merged_host_storage_conf"

        ########################
        # Storage settings

        storage_driver="''${storage_driver_arg:-''${host_driver:-overlay}}"

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

        storage_path="$conf_dir/storage"

        ########################
        # Generate storage.conf

        storage_conf="$conf_dir/storage.conf"

        if [[ -f "$storage_conf" ]]; then
            # === EXISTING FILE: preserve user modifications, apply targeted updates ===

            if [[ -n "$storage_driver_arg" ]]; then
                dasel put -f "$storage_conf" -r toml -w toml -t string -v "$storage_driver" '.storage.driver'
            fi

            if [[ "$netns_isolate" == "true" ]]; then
                runroot="''${storage_path}-run"
                mkdir -p "$runroot"
                dasel put -f "$storage_conf" -r toml -w toml -t string -v "$runroot" '.storage.runroot'
            elif [[ -n "$host_runroot" ]]; then
                dasel put -f "$storage_conf" -r toml -w toml -t string -v "$host_runroot" '.storage.runroot'
                echo "WARNING: Shared netns, named networks must not conflict. Set podmanFlake.netnsIsolate = true to isolate." >&2
            fi

            existing_mount_program=$(dasel -f "$storage_conf" -r toml -w json '.storage.options.overlay.mount_program' 2>/dev/null | jq -r '.' 2>/dev/null || echo "")
            if [[ "$existing_mount_program" == /nix/store/* ]]; then
                dasel put -f "$storage_conf" -r toml -w toml -t string -v "$FUSE_OVERLAYFS_BIN" '.storage.options.overlay.mount_program'
            fi

        else
            # === FRESH FILE: create and fully configure ===

            # Select initial config from available sources (user > vendor/admin > nixpkg > default)
            if [[ -n "$host_user_storage_conf" && -f "$host_user_storage_conf" ]]; then
                cp "$host_user_storage_conf" "$storage_conf"
            elif (( ''${#host_storage_conf_layers[@]} > 0 )); then
                printf "" > "$storage_conf"
            elif [[ -f "$PODMAN_SHARE/storage.conf" ]]; then
                cp "$PODMAN_SHARE/storage.conf" "$storage_conf"
            else
                cat > "$storage_conf" <<'DEFAULT_STORAGE_CONF'
        [storage]
        driver = "overlay"
        transient_store = true
        DEFAULT_STORAGE_CONF
            fi

            dasel put -f "$storage_conf" -r toml -w toml -t string -v "$storage_driver" '.storage.driver'
            dasel put -f "$storage_conf" -r toml -w toml -t string -v "$storage_path" '.storage.graphroot'
            mkdir -p "$storage_path"

            # Runroot handling
            existing_runroot=$(dasel -f "$storage_conf" -r toml -w json '.storage.runroot' 2>/dev/null | jq -r '.' 2>/dev/null || echo "")
            if [[ "$netns_isolate" == "true" ]] || [[ -z "$existing_runroot" ]]; then
                runroot="''${storage_path}-run"
                mkdir -p "$runroot"
                dasel put -f "$storage_conf" -r toml -w toml -t string -v "$runroot" '.storage.runroot'
            else
                echo "WARNING: Shared netns, named networks must not conflict. Set podmanFlake.netnsIsolate = true to isolate." >&2
            fi

            dasel put -f "$storage_conf" -r toml -w toml -t string -v "$storage_path" '.storage.imagestore'
            dasel put -f "$storage_conf" -r toml -w toml -t string -v "$storage_path" '.storage.rootless_storage_path'
            dasel put -f "$storage_conf" -r toml -w toml -t json -v "$additional_stores_json" '.storage.options.additionalimagestores'

            own_overlay=false
            if [[ "$storage_driver" == "overlay" ]]; then
                case "$host_driver" in
                    overlay|overlayfs)
                        own_overlay=false
                        ;;
                    *)
                        own_overlay=true
                        ;;
                esac
            fi

            if [[ "$own_overlay" == "true" ]]; then
                dasel delete -f "$storage_conf" -r toml -w toml '.storage.options.overlay' 2>/dev/null || true
                dasel put -f "$storage_conf" -r toml -w toml -t string -v "$FUSE_OVERLAYFS_BIN" '.storage.options.overlay.mount_program'
                dasel put -f "$storage_conf" -r toml -w toml -t string -v "nodev" '.storage.options.overlay.mountopt'
            fi
        fi

        ########################
        # Generate containers.conf

        flake_helper_pkgs=("$PASST_PKG" "$NETAVARK_PKG" "$AARDVARK_DNS_PKG")

        containers_conf="$conf_dir/containers.conf"

        if [[ -f "$containers_conf" ]]; then
            # === EXISTING FILE: preserve user modifications, update nixpkg paths ===

            _set_runtime_tools "$containers_conf"

            current_helpers=$(dasel -f "$containers_conf" -r toml -w json '.engine.helper_binaries_dir' 2>/dev/null || echo '[]')

            for pkg in "''${flake_helper_pkgs[@]}"; do
                store_basename="''${pkg##*/}"
                name_ver="''${store_basename:33}"
                name="''${name_ver%%-[0-9]*}"
                pattern="/nix/store/[a-z0-9]{32}-''${name}-"
                current_helpers=$(echo "$current_helpers" | jq --arg p "$pattern" '[.[] | select(test($p) | not)]')
            done

            helpers_json=$(_build_helpers_json "''${flake_helper_pkgs[@]}")
            merged_helpers=$(jq -n --argjson new "$helpers_json" --argjson cur "$current_helpers" '$new + $cur')
            dasel put -f "$containers_conf" -r toml -w toml -t json -v "$merged_helpers" '.engine.helper_binaries_dir'

        else
            # === FRESH FILE: create and fully configure ===

            # Select initial config from available sources (user > vendor/admin > nixpkg > default)
            if [[ -n "$host_user_containers_conf" && -f "$host_user_containers_conf" ]]; then
                cp "$host_user_containers_conf" "$containers_conf"
            elif (( ''${#host_containers_conf_layers[@]} > 0 )); then
                printf "" > "$containers_conf"
            elif [[ -f "$PODMAN_SHARE/containers.conf" ]]; then
                cp "$PODMAN_SHARE/containers.conf" "$containers_conf"
            else
                cat > "$containers_conf" <<'DEFAULT_CONTAINERS_CONF'
        [engine]
        events_logger = "file"
        cgroup_manager = "cgroupfs"
        image_copy_tmp_dir = "/tmp"
        DEFAULT_CONTAINERS_CONF
            fi

            if (( ''${#host_containers_conf_layers[@]} == 0 )); then
                if [[ -d /run/systemd/system ]] && systemctl --user status >/dev/null 2>&1; then
                    dasel put -f "$containers_conf" -r toml -w toml -t string -v "systemd" '.engine.cgroup_manager'
                fi
            fi

            _set_runtime_tools "$containers_conf"

            helpers_json=$(_build_helpers_json "''${flake_helper_pkgs[@]}")
            current_helpers=$(dasel -f "$containers_conf" -r toml -w json '.engine.helper_binaries_dir' 2>/dev/null || echo '[]')
            merged_helpers=$(jq -n --argjson new "$helpers_json" --argjson cur "$current_helpers" '$new + $cur')
            dasel put -f "$containers_conf" -r toml -w toml -t json -v "$merged_helpers" '.engine.helper_binaries_dir'

            net_dir="$conf_dir/networks"
            mkdir -p "$net_dir"
            dasel put -f "$containers_conf" -r toml -w toml -t string -v "$net_dir" '.network.network_config_dir'
        fi

        ########################
        # Registries and policy

        if [[ ! -f "$conf_dir/registries.conf" ]]; then
            _copy_first_available "$conf_dir/registries.conf" "registries.conf" \
                "$xdg_config_home/containers" "/etc/containers" "/usr/share/containers" \
                "$PODMAN_SHARE"
        fi

        if [[ ! -f "$conf_dir/policy.json" ]]; then
            _copy_first_available "$conf_dir/policy.json" "policy.json" \
                "$xdg_config_home/containers" "/etc/containers" "/usr/share/containers" \
                "$PODMAN_SHARE"
        fi
      '';
    in {
      devShells.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          podman
          buildah
          skopeo
          # Need to be explicit, because these are "optional" backend tools. Podman tools
          # auto-discover which of these or other alts are present and use them.
          # But for real podman functionality, you always want these. 
          crun
          conmon
          passt
          # May not be used, but we don't know until we're setting up the environment in the shellHook.
          fuse-overlayfs
          # networking backend, must match with the podman version
          netavark
          aardvark-dns
          # yq-go can't handle the complicated TOML of podman and containers_storage config, so use dasel and jq that can.
          dasel
          jq
          # realpath is used in the shellHook to canonicalize paths
          coreutils
        ];

        shellHook =  
        let
          storageDriverArgs = optionalString (cfg.storageDriver != null) ''--storage-driver "${cfg.storageDriver}"'';
          netnsIsolateArg = optionalString cfg.netnsIsolate "--netns-isolate";
        in ''
          # Canonicalize to absolute path without resolving symlinks. Don't require existence, we may have to create one or more of the folders.
          _conf_dir="$(realpath -m --no-symlinks "${cfg.containersConfDir}")"
          mkdir -p "$_conf_dir"

          ${populateScript}/bin/podman-flake-populate-conf --conf-dir "$_conf_dir" ${storageDriverArgs} ${netnsIsolateArg}

          # What actually makes the podman-related tools use our isolated configuration, storage, etc.
          export CONTAINERS_STORAGE_CONF="$_conf_dir/storage.conf"
          export CONTAINERS_CONF="$_conf_dir/containers.conf"

          # remove the temporary to avoid polluting the resulting shell
          unset _conf_dir
        '';
      };
    };
    );
  });
}
