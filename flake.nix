{
  # DESCRIPTION
  #   Provides a podman devShell with isolated container storage via the
  #   podmanFlake flake-parts module defined in flake-module.nix.
  #
  #   The module options below map to the legacy environment variables for
  #   backward compatibility. With --impure, setting PODMAN_FLAKE_CONTAINERS_CONF,
  #   PODMAN_FLAKE_STORAGE_DRIVER, or PODMAN_FLAKE_NETNS_ISOLATE before
  #   'nix develop' still works. In pure evaluation mode the module defaults apply.

  description = "DevShell with isolated container storage and host system images as read-only store";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs = { flake-parts, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ./flake-module.nix ];

      # Export the module so other flakes can import it via:
      #   inputs.podman-subshell.flakeModules.default
      flake.flakeModules.default = ./flake-module.nix;

      # can't include darwin targets because podman on MacOS works completely differently (podman machines)
      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { config, lib, pkgs, ... }:
      let
        helpTextFile = pkgs.writeText "podman-flake-help.txt" ''
          podman-flake — DevShell with isolated container storage

          ENVIRONMENT VARIABLES

            Set these before entering the devShell (e.g. export VAR=value before
            running 'nix develop --impure'), or in a .envrc file with direnv.

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
        podmanFlake = {
          enable = true;

          # Map legacy environment variables to module options.
          # In pure evaluation (default) these are not set and module defaults apply.
          # With --impure the environment variables are read at eval time.
          containersConfDir = lib.mkIf (builtins.getEnv "PODMAN_FLAKE_CONTAINERS_CONF" != "")
            (builtins.getEnv "PODMAN_FLAKE_CONTAINERS_CONF");

          storageDriver = lib.mkIf (builtins.getEnv "PODMAN_FLAKE_STORAGE_DRIVER" != "")
            (builtins.getEnv "PODMAN_FLAKE_STORAGE_DRIVER");

          netnsIsolate = lib.mkIf (builtins.getEnv "PODMAN_FLAKE_NETNS_ISOLATE" != "")
            true;
        };

        apps.help = {
          type = "app";
          program = "${helpScript}/bin/podman-flake-help";
          meta.description = "Show environment variables and configuration options for the podman devShell";
        };
      };
    };
}
