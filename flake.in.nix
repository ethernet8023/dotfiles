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
      stylix = followsNixpkgs "github:nix-community/stylix";
      # nixcord takes TWO nixpkgs: `nixpkgs` for the module and a separately
      # pinned `nixpkgs-nixcord` it builds vencord/vesktop from. followsNixpkgs
      # only redirects the first, so the second is set explicitly -- otherwise
      # it silently adds a whole extra nixpkgs to the closure.
      nixcord = {
        url = "github:4evy/nixcord";
        inputs.nixpkgs.follows = "nixpkgs";
        inputs.nixpkgs-nixcord.follows = "nixpkgs";
      };
      # NOT followsNixpkgs: hermes-agent builds a uv2nix python set against the
      # nixpkgs it pins and tests with, so overriding that input breaks the
      # build. It therefore brings its own nixpkgs -- see the exemption in
      # checks.checkNixpkgsVersions below.
      hermes-agent.url = "github:NousResearch/hermes-agent";
      vscode-server.url = "github:nix-community/nixos-vscode-server";
      noctalia = followsNixpkgs "github:noctalia-dev/noctalia";
    };

  outputs =
    {
      self,
      nur,
      nixpkgs,
      home-manager,
      agenix,
      fido2-hid-bridge,
      stylix,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      sys = {
        specialArgs = {
          inherit inputs;
        };
      };

      base-modules = [
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
        stylix.nixosModules.stylix
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
    {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt;

      # importable by other flakes (e.g. dollnet, which isn't mine and only
      # wants my home config for the `ethernet` user). these are plain module
      # paths -- no nixpkgs of mine leaks through them, so a consumer evaluates
      # them against their own.
      #
      # `dollnet` is the whole config for ethernet@dollnet and bundles its own
      # imports, so her flake needs exactly one entry. it wants
      # `hermes-agent-package` in extraSpecialArgs -- see the comment at the top
      # of home-manager/hosts/dollnet.nix for why the package is injected rather
      # than pinned here.
      #
      # the hermes-agent module itself is no longer carried here: upstream ships
      # `homeManagerModules.default` now, which absorbed everything this repo's
      # port had except the backend hostname/interface wait. consumers import it
      # from github:NousResearch/hermes-agent directly.
      #
      # `server` expects home.username / home.homeDirectory from the consumer,
      # since identity.nix only applies to my own hosts.
      homeModules = {
        dollnet = ./home-manager/hosts/dollnet.nix;
        server = ./home-manager/home-server.nix;

        # Stylix target for hermes-agent: generates a Hermes skin from the
        # active base16 scheme and selects it. Import alongside upstream's
        # `homeManagerModules.default` and stylix's own home module; it is inert
        # unless both stylix and services.hermes-agent are enabled.
        stylix-hermes-agent = ./home-manager/stylix-hermes-agent.nix;
      };

      # NixOS modules importable by other flakes. same principle as homeModules:
      # plain module paths, no nixpkgs of mine leaks through.
      nixosModules = {
        dollnet-infra = ./nixos/dollnet/ethernet-infra.nix;
      };

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

      # Every input should follow the one nixpkgs, so the closure holds a single
      # copy. hermes-agent is the deliberate exception: it evaluates a uv2nix
      # python set against the nixpkgs it pins and tests against, and pointing
      # that at nixpkgs-master breaks the build.
      #
      # Checking node names (`nixpkgs_2`) is not reliable -- nix numbers them by
      # discovery order, so adding an input can renumber the existing ones and
      # move the name onto an innocent node. Count the distinct nixpkgs *repos*
      # instead and name the allowed second one.
      checks.x86_64-linux.checkNixpkgsVersions =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          lock = builtins.fromJSON (builtins.readFile ./flake.lock);

          # Nodes that are a full nixpkgs checkout (not nixpkgs.lib).
          nixpkgsNodes = lib.filterAttrs (
            _: node:
            let
              l = node.locked or { };
            in
            (l.repo or "") == "nixpkgs"
          ) lock.nodes;

          # Which input of the root node each nixpkgs node is reachable from.
          owners = lib.mapAttrsToList (
            name: _:
            let
              viaRoot = lib.filterAttrs (_: v: v == name) (lock.nodes.root.inputs or { });
              viaOther = lib.concatMap (
                n: lib.optional (lib.any (v: v == name) (lib.attrValues (lock.nodes.${n}.inputs or { }))) n
              ) (builtins.attrNames lock.nodes);
            in
            if viaRoot != { } then "root" else lib.head (viaOther ++ [ "?" ])
          ) nixpkgsNodes;

          allowed = [
            "root"
            "hermes-agent"
          ];
          unexpected = lib.subtractLists allowed owners;
        in
        pkgs.runCommand "check-nixpkgs-versions" { } (
          if unexpected == [ ] then
            "touch $out"
          else
            ''
              echo "Error: these inputs pull in their own nixpkgs:"
              ${lib.concatMapStringsSep "\n" (o: ''echo "  - ${o}"'') unexpected}
              echo "Add followsNixpkgs to them, or allow them in checkNixpkgsVersions."
              exit 1
            ''
        );
    };

}
