{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    mattware = {
      url = "github:mattrobenolt/nixpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      mattware,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ mattware.overlays.default ];
          };
        in
        {
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              zig_0_16
              zls_0_16
              ziglint
              zigdoc
              just
              uv
              goperf
              pv
              # The bench/ fleet harness (bench/README.md): opentofu reads the
              # shared fleet stack's outputs; go builds the klauspost competitor
              # driver; cmake configures the zlib-ng competitor build.
              opentofu
              go
              cmake
            ];
            env = {
              UV_PYTHON = "${pkgs.python314}/bin/python3";
              UV_PYTHON_DOWNLOADS = "never";
            };
          };
        };
    };
}
