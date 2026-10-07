{
  description = "Modern SQL and NoSQL database client for Neovim";
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
      pkgsFor = forAllSystems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [ fenix.overlays.default ];
        }
      );
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
          inherit (pkgs) lib;
          toolchain = pkgs.fenix.stable.withComponents [
            "cargo"
            "rustc"
            "rust-src"
            "rustfmt"
            "clippy"
          ];
          databasePath = lib.makeLibraryPath [
            pkgs.sqlite
            pkgs.duckdb
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
            SQLITE3_LIB_DIR = "${lib.getLib pkgs.sqlite}/lib";
            SQLITE3_INCLUDE_DIR = "${lib.getDev pkgs.sqlite}/include";
            DUCKDB_LIB_DIR = "${lib.getLib pkgs.duckdb}/lib";
            DUCKDB_INCLUDE_DIR = "${lib.getDev pkgs.duckdb}/include";
            # Dev shells link the system SQLite/DuckDB dynamically. Release
            # archives compile bundled sources instead (`just dist-build`).
            shellHook =
              lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
                export LD_LIBRARY_PATH="${databasePath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              ''
              + lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
                export DYLD_LIBRARY_PATH="${databasePath}''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
              '';
          };
        }
      );
    };
}
