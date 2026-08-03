# plain data, not a module: per-host identity facts. importable from anywhere
# (nixos modules, darwin modules, home-manager modules) without going through
# the module system -- home-manager can't read the host's `config.me` without
# recursing, since it's evaluated inside it.
#
# identity.nix turns these into the `me.*` options; this is just the values.
rec {
  linux = {
    username = "ethie";
  };

  # /home/ethie here, which is what identity.nix defaults to
  luna = linux;

  # not yet migrated off the old homedir; everything under it is real
  hermes = linux // {
    homeDirectory = "/home/ari";
  };
  sol = hermes;
  casey = hermes;

  # macbook: different login name, and darwin homes live under /Users
  iris = {
    username = "ethernet";
    homeDirectory = "/Users/ethernet";
  };
}
