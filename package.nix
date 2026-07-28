{
  lib,
  writeShellApplication,
  # The flake source tree, copied into the store. Passed by flake.nix so the
  # wrapper can resolve `--package-path` against a hermetic snapshot rather
  # than the caller's cwd.
  src,
}:

# socktainer depends on Apple's Container / Containerization Swift packages,
# which in turn require:
#   * the macOS 15 SDK (only shipped via Xcode, not nixpkgs),
#   * the Swift 6.2 toolchain (Xcode 16.x or the Swift.org installer),
#   * network access to resolve SwiftPM dependencies.
#
# None of that fits inside a Nix sandbox on Darwin, so we don't try. Instead
# this derivation produces a `socktainer` wrapper on PATH that delegates to
# the host's `swift run -c release` against the source tree captured in the
# store. SwiftPM's checkouts and build products live under $XDG_CACHE_HOME,
# giving incremental rebuilds without touching the read-only store.
#
# `nix build` succeeds without a Swift toolchain (only the wrapper is built);
# the toolchain is required at runtime when the user first invokes the CLI.

let
  # Build metadata mirrors the Makefile so `socktainer --version` and the API
  # version endpoints match a normal `make release` build. Users can override
  # these at invocation time (e.g. `BUILD_VERSION=1.2.3 socktainer ...`).
  buildVersion = "0.0.0-nix";
  buildGitCommit = "unknown";
  buildTime = "1970-01-01T00:00:00Z";
  dockerEngineApiMinVersion = "v1.32";
  dockerEngineApiMaxVersion = "v1.51";
in
writeShellApplication {
  name = "socktainer";

  # We deliberately don't pin `swift` here — it must come from the user's
  # Xcode or Swift.org toolchain. nixpkgs' Darwin Swift doesn't ship the
  # macOS 15 SDK, so it can't build this project even if it were on PATH.
  runtimeInputs = [ ];

  text = ''
    if ! command -v swift >/dev/null 2>&1; then
      echo "error: 'swift' not found on PATH." >&2
      echo "  install Xcode 16.x or the Swift.org 6.2 toolchain." >&2
      exit 127
    fi

    : "''${XDG_CACHE_HOME:=$HOME/.cache}"
    scratch_path="$XDG_CACHE_HOME/socktainer/build"
    mkdir -p "$scratch_path"

    # Build metadata — overridable per-invocation, defaulted for reproducibility.
    export BUILD_VERSION="''${BUILD_VERSION:-${buildVersion}}"
    export BUILD_GIT_COMMIT="''${BUILD_GIT_COMMIT:-${buildGitCommit}}"
    export BUILD_TIME="''${BUILD_TIME:-${buildTime}}"
    export DOCKER_ENGINE_API_MIN_VERSION="''${DOCKER_ENGINE_API_MIN_VERSION:-${dockerEngineApiMinVersion}}"
    export DOCKER_ENGINE_API_MAX_VERSION="''${DOCKER_ENGINE_API_MAX_VERSION:-${dockerEngineApiMaxVersion}}"

    exec swift run \
      --package-path ${src} \
      --scratch-path "$scratch_path" \
      -c release \
      socktainer "$@"
  '';

  meta = {
    description = "Docker-compatible REST API for Apple Containerization on macOS";
    homepage = "https://github.com/socktainer/socktainer";
    license = lib.licenses.asl20;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "socktainer";
  };
}
