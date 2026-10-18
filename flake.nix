{
  description = "socktainer — Docker-compatible REST API for Apple Containerization on macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-compat = {
      url = "git+https://git.lix.systems/lix-project/flake-compat";
      flake = false;
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # macOS on Apple Silicon only — socktainer wraps Apple's Containerization
      # framework, which requires macOS 15+ on arm64.
      systems = [ "aarch64-darwin" ];

      flake = {
        # Consumers can pull socktainer into their own nixpkgs instance via
        # `overlays.default`. The overlay adds a `socktainer` attribute built
        # from this flake's source tree.
        overlays.default = final: _prev: {
          socktainer = final.callPackage ./package.nix { src = inputs.self; };
        };
      };

      perSystem =
        { pkgs, ... }:
        let
          treefmt = inputs.treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

          socktainer = pkgs.callPackage ./package.nix { src = inputs.self; };
        in
        {
          packages = {
            default = socktainer;
            inherit socktainer;
          };

          apps.default = {
            type = "app";
            program = "${socktainer}/bin/socktainer";
          };

          formatter = treefmt.config.build.wrapper;

          checks.formatting = treefmt.config.build.check inputs.self;

          # mkShellNoCC: the Swift toolchain and macOS SDK come from Xcode, not
          # nixpkgs. A plain mkShell would pull in the Darwin stdenv, whose
          # apple-sdk hook points DEVELOPER_DIR/SDKROOT at nixpkgs' (older) SDK
          # and puts xcbuild's xcrun shim on PATH.
          devShells.default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              git
              gnumake
              jq
              treefmt.config.build.wrapper
            ];

            # Use Xcode's toolchain for this shell only (DEVELOPER_DIR is read
            # by the /usr/bin/swift and xcrun shims), without touching the
            # system-wide `xcode-select`. The CommandLineTools driver doesn't
            # search the plugins/testing directory, so swift-testing macros
            # (#expect, @Test) fail to expand and `make test` breaks there.
            #
            # Precedence: a DEVELOPER_DIR you already exported (unless it is a
            # Nix store or CommandLineTools path), then the `xcode-select`
            # choice if it is an Xcode, then /Applications/Xcode.app.
            shellHook = ''
              socktainer_is_xcode() {
                case "$1" in
                  "" | /nix/store/* | */CommandLineTools | */CommandLineTools/) return 1 ;;
                  *) [ -x "$1/usr/bin/xcodebuild" ] ;;
                esac
              }

              socktainer_dev_dir=""
              if socktainer_is_xcode "''${DEVELOPER_DIR:-}"; then
                socktainer_dev_dir="$DEVELOPER_DIR"
              elif socktainer_is_xcode "$(/usr/bin/xcode-select -p 2>/dev/null)"; then
                socktainer_dev_dir="$(/usr/bin/xcode-select -p)"
              elif socktainer_is_xcode /Applications/Xcode.app/Contents/Developer; then
                socktainer_dev_dir=/Applications/Xcode.app/Contents/Developer
              fi

              if [ -n "$socktainer_dev_dir" ]; then
                export DEVELOPER_DIR="$socktainer_dev_dir"
              else
                unset DEVELOPER_DIR
                echo "warning: no Xcode found; using CommandLineTools. 'make test' will fail to expand" \
                  "swift-testing macros. Install Xcode or export DEVELOPER_DIR=<Xcode>/Contents/Developer." >&2
              fi
              unset socktainer_dev_dir
              unset -f socktainer_is_xcode

              if ! command -v swift >/dev/null 2>&1; then
                echo "warning: 'swift' not on PATH — install Xcode." >&2
              fi
            '';
          };
        };
    };
}
