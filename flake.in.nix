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
      # phone as NFC reader + virtual FIDO key. feat/linux until it merges to main.
      tapbridge = followsNixpkgs "github:ethernet8023/tapbridge/feat/linux";
      fw-inputmodule = followsNixpkgs "github:caffineehacker/nix?dir=flakes/inputmodule-rs";
      # nixvim = followsNixpkgs "github:nix-community/nixvim";
      # The base16 scheme library, used directly by home-manager/schemes.nix.
      # No followsNixpkgs: base16.nix takes no nixpkgs input.
      base16.url = "github:SenchoPens/base16.nix";
      # catppuccin's prebuilt Stylus export, a rolling release asset. Pinned by
      # hash in flake.lock; updating these two inputs pulls whatever upstream
      # has published since:
      #   nix flake update catppuccin-userstyles-export catppuccin-userstyles-lib
      # Consumed by home-manager/catppuccin-userstyles.nix.
      catppuccin-userstyles-export = {
        url = "file+https://github.com/catppuccin/userstyles/releases/download/all-userstyles-export/import.json";
        flake = false;
      };
      # The less library every one of those styles @imports.
      catppuccin-userstyles-lib = {
        url = "file+https://userstyles.catppuccin.com/lib/std/v1.less";
        flake = false;
      };
      nixcord = followsNixpkgs "github:4evy/nixcord";
      # NOT followsNixpkgs: hermes-agent builds a uv2nix python set against the
      # nixpkgs it pins and tests with, so overriding that input breaks the
      # build. It therefore brings its own nixpkgs -- see the exemption in
      # checks.checkNixpkgsVersions below.
      hermes-agent.url = "github:NousResearch/hermes-agent/780d5a3313d7e1f64c0a0f3ec6b644d50f156e90";
      vscode-server.url = "github:nix-community/nixos-vscode-server";
      noctalia = followsNixpkgs "github:noctalia-dev/noctalia";
      noctalia-appmenu = followsNixpkgs "github:yolo-labz/noctalia-appmenu";
      yazi-plugins = followsNixpkgs "github:lordkekz/nix-yazi-plugins";
    };

  outputs =
    {
      nur,
      nixpkgs,
      home-manager,
      agenix,
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
        inputs.tapbridge.nixosModules.default
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
        inputs.tapbridge.darwinModules.default
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

      # importable by other flakes. these are plain module paths -- no nixpkgs
      # of mine leaks through them, so a consumer evaluates them against their
      # own.
      #
      # there is deliberately no hermes-agent module here: consumers import
      # upstream's `homeManagerModules.default` from
      # github:NousResearch/hermes-agent directly.
      #
      # `server` expects home.username / home.homeDirectory from the consumer,
      # since identity.nix only applies to my own hosts.
      homeModules = {
        server = ./home-manager/home-server.nix;

        # Generates a Hermes skin from the active base16 scheme and selects
        # it. Import alongside upstream's `homeManagerModules.default`; inert
        # unless services.hermes-agent is enabled.
        hermes-agent-skin = ./home-manager/hermes-agent-skin.nix;
      };

      # NixOS modules importable by other flakes. same principle as homeModules:
      # plain module paths, no nixpkgs of mine leaks through.
      nixosModules = {
        # everything ethernet on bellona (dahlia's box): the user account plus
        # the ENTIRE home-manager stack, with home-manager itself dragged in
        # from OUR pin so her flake stays two inputs light. see
        # nixos/bellona-ether.nix for the split of duties.
        bellona =
          { pkgs, ... }:
          {
            imports = [
              inputs.home-manager.nixosModules.home-manager
              ./nixos/bellona-ether.nix
            ];
            home-manager.extraSpecialArgs.hermes-agent-package =
              inputs.hermes-agent.packages.x86_64-linux.default;

            # hm-level modules for ethernet's user config: hermes-agent declares
            # services.hermes-agent; agenix decrypts the shared gateway token
            # (home.age, see bellona-ether.nix).
            home-manager.sharedModules = [
              inputs.hermes-agent.homeManagerModules.default
              inputs.agenix.homeManagerModules.default
            ];
          };
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
        #     ];
        #   }
        # );

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
