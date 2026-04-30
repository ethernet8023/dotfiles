# Do not modify! This file is generated.
# One exception: If you use a different template than "flake.in.nix" set
#                its relative path through the first argument to inputs.flakegen.

{
  description = "ethie's nice lil nix config :3";
  inputs = {
    agenix = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:ryantm/agenix";
    };
    beepy = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:arilotter/nixos-beepy";
    };
    catppuccin = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:catppuccin/nix";
    };
    fido2-hid-bridge = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:arilotter/fido2-hid-bridge-flake";
    };
    flakegen.url = "github:jorsn/flakegen";
    fw-inputmodule = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:caffineehacker/nix?dir=flakes/inputmodule-rs";
    };
    home-manager = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nix-community/home-manager";
    };
    hypr-contrib = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:hyprwm/contrib";
    };
    lix = {
      flake = false;
      url = "https://git.lix.systems/lix-project/lix/archive/main.tar.gz";
    };
    lix-module = {
      inputs = {
        lix.follows = "lix";
        nixpkgs.follows = "nixpkgs";
      };
      url = "https://git.lix.systems/lix-project/nixos-module/archive/main.tar.gz";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nixpkgs.url = "github:nixos/nixpkgs/master";
    nixvim = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nix-community/nixvim";
    };
    nur = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nix-community/NUR";
    };
    vscode-ext = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nix-community/nix-vscode-extensions";
    };
    vscode-server = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nix-community/nixos-vscode-server";
    };
  };
  nixConfig = {
    extra-deprecated-features = [ "broken-string-escape" ];
    extra-substituters = [ "https://cache.garnix.io" ];
    extra-trusted-public-keys = [ "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=" ];
  };
  outputs = inputs: inputs.flakegen ./flake.in.nix inputs;
}