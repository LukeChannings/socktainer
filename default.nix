let
  lockFile = builtins.fromJSON (builtins.readFile ./flake.lock);
  flake-compat-node = lockFile.nodes.${lockFile.nodes.root.inputs.flake-compat};
  flake-compat = fetchGit {
    inherit (flake-compat-node.locked) url rev;
  };

  flake = import flake-compat {
    src = ./.;
    copySourceTreeToStore = false;
    useBuiltinsFetchTree = true;
  };

  system = builtins.currentSystem;
in
flake.defaultNix
// {
  inherit (flake.defaultNix.packages.${system})
    socktainer
    ;
}
