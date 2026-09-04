{
  description = "A very basic zig flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};
  in {
  packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "zofi";
        version = "0.0.1";

        src = self;
        #hardeningDisable = [ "fortify" ];

        nativeBuildInputs = [
          pkgs.zig
          pkgs.libX11
          pkgs.libX11.dev
          pkgs.xorgserver
          pkgs.libXft
          pkgs.libXrender

        ];

        # Keeps Zig's cache out of the source tree and writable during builds.
        preBuild = ''
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
          export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
        '';

        buildPhase = ''
          runHook preBuild
          zig build -Doptimize=ReleaseSafe
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p "$out/bin"
          install -Dm755 zig-out/bin/zofi "$out/bin/zofi"
          runHook postInstall
        '';

        meta = {
          description = "My Zig application";
          mainProgram = "zofi";
          platforms = pkgs.lib.platforms.linux;
        };
      };

      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/zofi";
      };
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        zig
        zls
        libX11
        libX11.dev
        xorgserver
        libXft
        libXrender
        fontconfig
        freetype  
        xinit
        st
        ripgrep
      ];
    };
  };
}
