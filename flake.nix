{
  description = "illogical native terminal service";
  inputs.ghostty.url = "github:ghostty-org/ghostty/27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c";
  inputs.nixpkgs.follows = "ghostty/nixpkgs";
  outputs = { self, nixpkgs, ghostty }: let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    each = nixpkgs.lib.genAttrs systems;
  in {
    packages = each (system: let pkgs = nixpkgs.legacyPackages.${system}; in rec {
      illogical = pkgs.callPackage ./deploy/nixos/package.nix {
        libghostty-vt = ghostty.packages.${system}.libghostty-vt.overrideAttrs (previous: {
          patches = (previous.patches or []) ++ [
            ./patches/ghostty-image-budget.patch
            ./patches/ghostty-image-count.patch
            ./patches/ghostty-static-images.patch
          ];
        });
      };
      login-helper = pkgs.callPackage ./deploy/nixos/login-helper.nix {};
      default = illogical;
    });
    nixosModules.default = import ./deploy/nixos/module.nix;
    checks = each (system: {
      linux-login = import ./deploy/nixos/vm-test.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        package = self.packages.${system}.illogical;
      };
    });
  };
}
