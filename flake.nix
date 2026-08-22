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
    fido2-hid-bridge = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:arilotter/fido2-hid-bridge-flake";
    };
    flakegen.url = "github:jorsn/flakegen";
    fw-inputmodule = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:caffineehacker/nix?dir=flakes/inputmodule-rs";
    };
    hermes-agent.url = "github:NousResearch/hermes-agent";
    home-manager = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nix-community/home-manager";
    };
    hypr-contrib = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:hyprwm/contrib";
    };
    nix-darwin = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nix-darwin/nix-darwin";
    };
    nixcord = {
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-nixcord.follows = "nixpkgs";
      };
      url = "github:4evy/nixcord";
    };
    nixos-hardware = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:NixOS/nixos-hardware";
    };
    nixpkgs.url = "github:nixos/nixpkgs/master";
    noctalia = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:noctalia-dev/noctalia";
    };
    noctalia-appmenu = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:yolo-labz/noctalia-appmenu";
    };
    nur = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nix-community/NUR";
    };
    stylix = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nix-community/stylix";
    };
    vscode-ext = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nix-community/nix-vscode-extensions";
    };
    vscode-server.url = "github:nix-community/nixos-vscode-server";
  };
  nixConfig.extra-deprecated-features = [ "broken-string-escape" ];
  outputs = inputs: inputs.flakegen ./flake.in.nix inputs;
}