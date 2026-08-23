{
  description = "gitsite — follow a git ref, rebuild on change, serve what is in git";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.just
            # runner.sh parses gitsite.toml with tomllib. Declared here so the
            # tests run in every environment rather than only where a python
            # happens to be installed — the failure mode that made hat's
            # pre-push hook unusable in the code-server pod.
            pkgs.python3
            pkgs.shellcheck
            pkgs.git
            pkgs.git-lfs
          ];

          shellHook = ''
            echo "gitsite development environment loaded"
          '';
        };
      }
    );
}
