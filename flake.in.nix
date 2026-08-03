{
  description = "ethie's nice lil nix config :3";

  nixConfig = {
    extra-deprecated-features = [ "broken-string-escape" ];
  };

  inputs =
    let
      followsNixpkgs = url: {
        inherit url;
        inputs.nixpkgs.follows = "nixpkgs";
      };
    in
    {
      nixpkgs.url = "github:nixos/nixpkgs/master";
      nixos-hardware = followsNixpkgs "github:NixOS/nixos-hardware";

      nur = followsNixpkgs "github:nix-community/NUR";
      agenix = followsNixpkgs "github:ryantm/agenix";
      home-manager = followsNixpkgs "github:nix-community/home-manager";
      nix-darwin = followsNixpkgs "github:nix-darwin/nix-darwin";
      hypr-contrib = followsNixpkgs "github:hyprwm/contrib";
      vscode-ext = followsNixpkgs "github:nix-community/nix-vscode-extensions";
      # beepy = followsNixpkgs "github:arilotter/nixos-beepy";
      fido2-hid-bridge = followsNixpkgs "github:arilotter/fido2-hid-bridge-flake";
      fw-inputmodule = followsNixpkgs "github:caffineehacker/nix?dir=flakes/inputmodule-rs";
      # nixvim = followsNixpkgs "github:nix-community/nixvim";
      lix = {
        url = "https://git.lix.systems/lix-project/lix/archive/main.tar.gz";
        flake = false;
      };
      lix-module = {
        url = "https://git.lix.systems/lix-project/nixos-module/archive/main.tar.gz";
        inputs.lix.follows = "lix";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      catppuccin = followsNixpkgs "github:catppuccin/nix";
      vscode-server = followsNixpkgs "github:nix-community/nixos-vscode-server";
    };

  outputs =
    {
      self,
      nur,
      nixpkgs,
      home-manager,
      agenix,
      fido2-hid-bridge,
      lix-module,
      catppuccin,
      ...
    }@inputs:
    let
      sys = {
        specialArgs = {
          inherit inputs;
        };
      };

      base-modules = [
        lix-module.nixosModules.default
        agenix.nixosModules.default
        nur.modules.nixos.default
        fido2-hid-bridge.nixosModules.default
        home-manager.nixosModules.home-manager
        { home-manager.extraSpecialArgs = { inherit inputs; }; }
        ./nixos/all-systems-configuration.nix
      ];
      tty-modules = base-modules ++ [
        {
          home-manager.users.ethie = {
            imports = [
              ./home-manager/home.nix
              ./home-manager/home-linux.nix
            ];
          };
        }
      ];
      graphical-modules = base-modules ++ [
        catppuccin.nixosModules.catppuccin
        ./nixos/graphical-configuration.nix
        {
          # home-graphical.nix pulls in home.nix itself
          home-manager.users.ethie = {
            imports = [
              ./home-manager/home-graphical.nix
              ./home-manager/home-linux.nix
            ];
          };
        }
      ];
      darwin-modules = [
        agenix.darwinModules.default
        home-manager.darwinModules.home-manager
        {
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "hm-backup";
        }
        ./darwin/all-darwin-configuration.nix
      ];
    in
    rec {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt;

      darwinConfigurations = {
        # macbook air m1
        # `just switch` on iris itself; can't cross-build darwin from linux.
        "iris" = inputs.nix-darwin.lib.darwinSystem {
          specialArgs = { inherit inputs; };
          modules = darwin-modules ++ [
            ./darwin/iris/configuration.nix
            {
              home-manager.users.ethernet = {
                imports = [
                  ./home-manager/home.nix
                  ./home-manager/home-darwin.nix
                ];
              };
            }
          ];
        };
      };

      nixosConfigurations = {
        # desktop ~
        "luna" = nixpkgs.lib.nixosSystem (
          sys
          // {
            modules = graphical-modules ++ [
              ./nixos/luna/hardware-configuration.nix
              ./nixos/luna/configuration.nix
              ./nixos/mount-sol-samba-share.nix
            ];
          }
        );

        # framework laptop
        "hermes" = nixpkgs.lib.nixosSystem (
          sys
          // {
            modules = graphical-modules ++ [
              inputs.nixos-hardware.nixosModules.framework-16-7040-amd
              ./nixos/hermes/hardware-configuration.nix
              ./nixos/hermes/configuration.nix
              ./nixos/mount-sol-samba-share.nix
            ];
          }
        );

        # kronos = saturn = cuz it rings ;)
        # sd image: `nix build '.#kronos-sd'`
        # from another pc: `NIX_SSHOPTS="-t" nixos-rebuild boot --flake .#kronos -L --target-host ethie@kronos.local --use-remote-sudo`
        # "kronos" = nixpkgs.lib.nixosSystem (
        #   sys
        #   // {
        #     modules = tty-modules ++ [
        #       inputs.beepy.nixosModule
        #       ./nixos/kronos/hardware-configuration.nix
        #       ./nixos/kronos/configuration.nix
        #       ./nixos/mount-sol-samba-share.nix
        #     ];
        #   }
        # );

        # server = sol
        # locally: `sudo nixos-rebuild switch --flake .`
        # from `another pc: `NIX_SSHOPTS="-t" nixos-rebuild switch --flake .#sol -L --target-host ethie@sol.local --use-remote-sudo`
        "sol" = nixpkgs.lib.nixosSystem (
          sys
          // {
            modules = tty-modules ++ [
              inputs.nixos-hardware.nixosModules.hardkernel-odroid-h3
              ./nixos/sol/hardware-configuration.nix
              ./nixos/sol/configuration.nix
            ];
          }
        );
        "casey" = nixpkgs.lib.nixosSystem (
          sys
          // {
            modules = tty-modules ++ [
              inputs.nixos-hardware.nixosModules.hardkernel-odroid-h3
              ./nixos/casey/hardware-configuration.nix
              ./nixos/casey/configuration.nix
            ];
          }
        );

        # AMD + big vram server
        # nixos/hecate/hardware-configuration.nix was never committed, so this
        # can't evaluate -- it takes `nix flake check` down with it. generate
        # that file on the box (nixos-generate-config) and uncomment.
        # "hecate" = nixpkgs.lib.nixosSystem (
        #   sys
        #   // {
        #     modules = graphical-modules ++ [
        #       # todo: hardware quirks
        #       ./nixos/hecate/hardware-configuration.nix
        #       ./nixos/hecate/configuration.nix
        #       ./nixos/mount-sol-samba-share.nix
        #     ];
        #   }
        # );
      };
      # re-enable alongside the "kronos" nixosConfiguration above
      # kronos-sd = nixosConfigurations.kronos.config.system.build.sdImage;

      checks.x86_64-linux.checkNixpkgsVersions =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        pkgs.runCommand "check-nixpkgs-versions" { } ''
          if grep -q "nixpkgs_2" ${self}/flake.lock; then
            echo "Error: Found nixpkgs_2 in flake.lock"
            echo "You should add followsNixpkgs to the input that uses nixpkgs_2."
            exit 1
          fi
          touch $out
        '';
    };

}
