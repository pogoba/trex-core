{
  description = "Cisco TRex realistic traffic generator, built from source (bundled DPDK 25.07)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      trex = pkgs.callPackage ./nix/trex.nix { };
    in
    {
      packages.${system} = {
        default = trex;
        trex = trex;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${trex}/bin/t-rex-64";
        };
        console = {
          type = "app";
          program = "${trex}/bin/trex-console";
        };
      };

      # Toolchain for building TRex in-tree the upstream way:
      #   nix develop
      #   cd linux_dpdk && ./b configure && ./b build
      # Note: the in-tree build needs the same source fixes as the package; apply
      # them with `git apply nix/nixos-build.patch` (or just use `nix build`).
      devShells.${system}.default = pkgs.mkShell {
        hardeningDisable = [ "all" ];
        packages = with pkgs; [
          python312
          zlib
          glibc.bin # ldd
          gnumake
          binutils
          patchelf
          pciutils
          kmod
        ];
        shellHook = ''
          echo "TRex dev shell. Build with:"
          echo "  git apply nix/nixos-build.patch   # one-time: modern-toolchain fixes"
          echo "  cd linux_dpdk && python3 waf-2.0.21 configure --no-mlx=all --no-bnxt && python3 waf-2.0.21 build -j\$(nproc)"
        '';
      };
    };
}
