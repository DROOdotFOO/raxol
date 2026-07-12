# flake-compat shim: real definitions live in flake.nix (devShells.default).
# Lets `nix-shell` work without flakes enabled; the flake-compat pin is read
# from flake.lock so it stays in sync with `nix flake lock`.
(import (
  let
    lock = builtins.fromJSON (builtins.readFile ./flake.lock);
    node = lock.nodes.flake-compat.locked;
  in
  fetchTarball {
    url = "https://github.com/edolstra/flake-compat/archive/${node.rev}.tar.gz";
    sha256 = node.narHash;
  }
) { src = ./.; }).shellNix
