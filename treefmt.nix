{ ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    # Nix
    nixfmt.enable = true;

    # Shell scripts (scripts/*.sh, pkginstaller/*.sh, etc.)
    shfmt.enable = true;

    # Swift is formatted via `make fmt` (swift-format with .swift-format
    # config). treefmt doesn't ship a swift-format module, and CI already
    # enforces the drift check, so we leave Swift out of treefmt.
  };

  settings.global.excludes = [
    ".build/**"
    ".swiftpm/**"
    "Package.resolved"
    ".agents/**"
    ".claude/**"
  ];
}
