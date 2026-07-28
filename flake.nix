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

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              git
              gnumake
              jq
              treefmt.config.build.wrapper
            ];

            shellHook = ''
              if ! command -v swift >/dev/null 2>&1; then
                echo "warning: 'swift' not on PATH — install Xcode 16.x or the Swift.org 6.2 toolchain." >&2
              fi
            '';
          };
        };
    };
}
