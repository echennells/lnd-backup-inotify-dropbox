{
  description = "LND Channel Backup System with inotify and Dropbox";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        # Import package definition
        lnd-backup = pkgs.callPackage ./nix/package.nix {
          inherit pkgs;
        };
        
        # Import setup scripts
        setupScripts = import ./nix/setup-scripts.nix {
          inherit pkgs lnd-backup;
        };
        
      in {
        packages = {
          default = lnd-backup;
          lnd-backup = lnd-backup;
          setup = setupScripts.setup;
          install = setupScripts.install;
        };
        
        # Development shell
        devShells.default = import ./nix/dev-shell.nix {
          inherit pkgs;
        };
        
        # Apps for easy execution
        apps = {
          setup = flake-utils.lib.mkApp {
            drv = setupScripts.setup;
          };
          install = flake-utils.lib.mkApp {
            drv = setupScripts.install;
          };
        };
        
        # NixOS module
        nixosModules.default = import ./nix/nixos-module.nix;
      }
    );
}