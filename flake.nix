{
  description = "Query your database from your favorite editor";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, fenix, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # Development shells only: releases build with plain cargo (and `cross`
      # for Linux), so nothing here ever ships to users.
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ fenix.overlays.default ];
          };
          inherit (pkgs) lib;
          toolchain = pkgs.fenix.stable.withComponents [
            "cargo"
            "rustc"
            "rust-src"
            "rustfmt"
            "clippy"
          ];
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              toolchain
              just
              stylua
              selene
              lua-language-server
              neovim
              pkg-config
              sqlite
              duckdb
              git
            ];
            DUCKDB_LIB_DIR = "${lib.getLib pkgs.duckdb}/lib";
            DUCKDB_INCLUDE_DIR = "${lib.getDev pkgs.duckdb}/include";
            # Cargo-built binaries (tests, engine subprocesses) link this
            # library dynamically but carry no RUNPATH for it, and Nix leaves
            # LD_LIBRARY_PATH empty in the shell: without this, they fail to start.
            shellHook =
              lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
                export LD_LIBRARY_PATH="${lib.getLib pkgs.duckdb}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              ''
              + lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
                export DYLD_LIBRARY_PATH="${lib.getLib pkgs.duckdb}/lib''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
              '';
          };
        }
      );
    };
}
