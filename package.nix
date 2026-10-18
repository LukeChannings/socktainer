{
  lib,
  stdenvNoCC,
  # The flake source tree, copied into the store. Passed by flake.nix.
  src,
}:

# socktainer depends on Apple's Container / Containerization Swift packages,
# which in turn require:
#   * the macOS 15 SDK (only shipped via Xcode, not nixpkgs),
#   * the Swift 6.2 toolchain (Xcode 16.x or the Swift.org installer),
#   * network access to resolve SwiftPM dependencies.
#
# None of that fits inside a Nix sandbox on Darwin, so this derivation opts
# out of the sandbox (`__noChroot = true`) and shells out to the host's
# `xcrun swift build -c release`. That requires the caller's nix.conf to
# allow relaxed sandboxing, which is the default for `nix-darwin` and most
# manual Darwin installs.
#
# The resulting Mach-O binary links only against /usr/lib/* and the system
# Swift stdlib in /usr/lib/swift — no /nix/store runtime deps, no PATH
# lookups. That is what makes it safe to run under launchd, which strips
# PATH down to /usr/bin:/bin:/usr/sbin:/sbin. (The previous `writeShell-
# Application` wrapper exec'd `swift run`, which exits 127 under launchd
# because `swift` isn't on the launchd PATH — the socket never binds and
# every Docker client `.start()` hangs on a dead socket. See issue #NNN.)

let
  # Build metadata mirrors the Makefile so `socktainer --version` and the API
  # version endpoints match a normal `make release` build. Callers can pass
  # `BUILD_VERSION=... nix build` etc. to override.
  buildVersion = "0.0.0-nix";
  buildGitCommit = "unknown";
  buildTime = "1970-01-01T00:00:00Z";
  # Bare numbers, no "v" prefix: Docker clients parse these (docker-py's
  # negotiation fails on "v1.51"). Keep in sync with the Makefile.
  dockerEngineApiMinVersion = "1.32";
  dockerEngineApiMaxVersion = "1.51";
in
stdenvNoCC.mkDerivation {
  pname = "socktainer";
  version = buildVersion;

  inherit src;

  # Break out of the Nix sandbox so we can reach the host Xcode toolchain,
  # the macOS 15 SDK, and the network (SwiftPM resolves dependencies during
  # `swift build`). Requires `sandbox = relaxed` (or `false`) in nix.conf.
  __noChroot = true;

  # We hand-roll the whole build. No configure, no autotools patching, no
  # stdenv fixups on the produced Mach-O.
  dontConfigure = true;
  dontPatch = true;
  dontFixup = true;

  # SwiftPM's default cache/config/security dirs live under $HOME/Library.
  # Nix's build user is `_nixbld*` whose passwd entry points at /var/empty,
  # and Foundation on Darwin resolves the user's home via `getpwuid()` —
  # NOT `$HOME`. So we cannot just re-export HOME; we have to (a) set
  # `CFFIXED_USER_HOME`, which Foundation honors, and (b) hand SwiftPM
  # explicit `--cache-path` / `--config-path` / `--security-path` so its
  # own resolver stops probing the passwd-derived home directory.
  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR/home"
    export CFFIXED_USER_HOME="$HOME"
    export XDG_CACHE_HOME="$HOME/Library/Caches"
    mkdir -p \
      "$HOME/Library/Caches/org.swift.swiftpm" \
      "$HOME/Library/org.swift.swiftpm/configuration" \
      "$HOME/Library/org.swift.swiftpm/security"

    export BUILD_VERSION="''${BUILD_VERSION:-${buildVersion}}"
    export BUILD_GIT_COMMIT="''${BUILD_GIT_COMMIT:-${buildGitCommit}}"
    export BUILD_TIME="''${BUILD_TIME:-${buildTime}}"
    export DOCKER_ENGINE_API_MIN_VERSION="''${DOCKER_ENGINE_API_MIN_VERSION:-${dockerEngineApiMinVersion}}"
    export DOCKER_ENGINE_API_MAX_VERSION="''${DOCKER_ENGINE_API_MAX_VERSION:-${dockerEngineApiMaxVersion}}"

    # Nix strips PATH to /nix/store/... — but SwiftPM shells out to bare
    # `git` (and other host tools) during dependency resolution. Without
    # /usr/bin on PATH those spawns fail with empty stderr and SwiftPM
    # reports a bare "Failed to clone repository <url>:" with no cause.
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

    if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
      echo "error: xcrun cannot find 'swift'." >&2
      echo "  install Xcode 16.x or the Swift.org 6.2 toolchain and select it" >&2
      echo "  with 'xcode-select -s /Applications/Xcode.app'." >&2
      exit 127
    fi

    swift_args=(
      -c release
      --scratch-path "$TMPDIR/spm-scratch"
      --cache-path "$HOME/Library/Caches/org.swift.swiftpm"
      --config-path "$HOME/Library/org.swift.swiftpm/configuration"
      --security-path "$HOME/Library/org.swift.swiftpm/security"
    )

    /usr/bin/xcrun swift build "''${swift_args[@]}"

    # Stash the release bin path for installPhase. `--show-bin-path` prints
    # the triple-qualified release directory (e.g. .../arm64-apple-macosx/
    # release) which is where the binary actually lives.
    /usr/bin/xcrun swift build "''${swift_args[@]}" --show-bin-path \
      > "$TMPDIR/swift-bin-path"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    bin_path="$(cat "$TMPDIR/swift-bin-path")"
    binary="$bin_path/socktainer"
    if [ ! -x "$binary" ]; then
      echo "error: expected socktainer binary at $binary but did not find it" >&2
      ls -la "$bin_path" >&2 || true
      exit 1
    fi

    mkdir -p "$out/bin"
    cp "$binary" "$out/bin/socktainer"
    chmod +x "$out/bin/socktainer"

    # Sanity check: launchd-safe means no /nix/store runtime deps. If a
    # future dependency drags one in we want to fail the build loudly rather
    # than ship a binary that dies under launchd.
    #
    # `otool -L` prints the binary's own path on the first line, so skip it
    # and only inspect the actual dylib list (tab-indented rows).
    if /usr/bin/otool -L "$out/bin/socktainer" | tail -n +2 | grep -q '/nix/store'; then
      echo "error: built binary has /nix/store runtime dependencies:" >&2
      /usr/bin/otool -L "$out/bin/socktainer" | tail -n +2 | grep '/nix/store' >&2
      exit 1
    fi

    runHook postInstall
  '';

  meta = {
    description = "Docker-compatible REST API for Apple Containerization on macOS";
    homepage = "https://github.com/socktainer/socktainer";
    license = lib.licenses.asl20;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "socktainer";
  };
}
