# home-manager/ssh.nix — the shared ssh CLIENT config, identical on every
# machine (imported by both home.nix and home-server.nix).
#
# topology (as of 2026-10):
#
#   dollnet   the only tailscale node in the house (shared tailnet node,
#             giraffa-richter.ts.net) — so it is the jump host for everything
#             else in the building.
#   phobos    spark head. reachable on the house LAN (mdns) and jumps through
#             dollnet so the same entry works from anywhere.
#   deimos    spark worker. has NO house-LAN presence at all: it lives on the
#             point-to-point 192.168.100/101 fabrics phobos↔deimos, and its
#             avahi announcement is only visible from phobos. so it is a
#             two-hop jump: dollnet → phobos → deimos. the explicit
#             user@hop chain is deliberate — ProxyJump does not reliably
#             recurse through the jump host's own config.
#   luna      desktop. on the house LAN + its own tailnet node, but the entry
#             jumps through dollnet so it resolves from outside the house too
#             (the LAN name is mdns, which doesn't route).
#   hermes    framework laptop, roams; tailnet magicdns name only.
#   iris      macbook, mdns on whatever network it's on (unchanged).
#   promise   win11 arm64. tailnet node is `promise-1` (the old
#             promise.tail…name is stale); the ts route is often down, in
#             which case it is LAN-only and reached by IP.
#   window    windows box, usually off. mdns name window.local when up.
#
# every machine's pubkey is authorized on every other one — see
# ssh-pubkeys.nix (`mesh`) — so any host entry works from any machine with
# nothing but the default ~/.ssh/id_ed25519.
{ lib, ... }:
{
  programs.ssh = {
    enable = true;
    # upstream is dropping its implicit `Host *` defaults, so spell them out
    # and opt out of the built-ins. these are the values the old default
    # produced, so the generated config is unchanged.
    enableDefaultConfig = false;
    settings = {
      "*" = {
        addKeysToAgent = "no";
        compression = false;
        controlMaster = "no";
        controlPath = "~/.ssh/master-%r@%n:%p";
        controlPersist = "no";
        forwardAgent = false;
        hashKnownHosts = false;
        serverAliveCountMax = 3;
        serverAliveInterval = 0;
        userKnownHostsFile = "~/.ssh/known_hosts";
      };

      # ── the jump host. everything in the house goes through here. ──
      # cross-tailnet magicdns (…giraffa-richter.ts.net) does NOT resolve
      # reliably from our resolver, so use the tailnet IP: per-node, stable.
      dollnet = {
        hostname = "100.95.51.7";
        user = "ethernet";
      };

      # ── house, behind the jump ──
      phobos = {
        hostname = "phobos.local";
        user = "ethernet";
        proxyJump = "dollnet";
      };
      deimos = {
        hostname = "deimos.local";
        user = "ethernet";
        # two hops, explicit: dollnet → phobos → deimos. the intermediate hop
        # is fully-qualified on purpose: jump-hop hostnames are resolved by the
        # previous hop's resolver, and plain `phobos` has no search domain
        # there — only the mdns name, which dollnet gets from avahi
        # (ethernet-infra.nix) and phobos announces natively.
        proxyJump = "ethernet@dollnet,ethernet@phobos.local";
      };
      luna = {
        hostname = "luna.local";
        user = "ethie";
        proxyJump = "dollnet";
      };
      window = {
        hostname = "window.local";
        user = "laser";
        proxyJump = "dollnet";
      };

      # ── roamers / remote, direct ──
      hermes = {
        # tailnet magicdns; the box roams so no LAN name would be stable
        hostname = "hermes.tail5b83ba.ts.net";
        user = "ethie";
      };
      iris = {
        # dhcp moves it around; mdns is stable
        hostname = "iris.local";
        user = (import ../hosts.nix).iris.username;
      };
      promise = {
        # node is `promise-1` in the tailnet; promise.tail… is a stale name.
        # when the ts route is down this box is LAN-only — ssh the IP by hand.
        hostname = "promise-1.tail5b83ba.ts.net";
        user = "arilo";
      };

      # ── rented metal ──
      hgx = {
        hostname = "216.55.186.241";
        port = 22;
        user = "ari";
      };
    };
  };

  # the nix store on these boxes ends up owned nobody:nogroup, and openssh
  # refuses a config file not owned by the invoking user ("Bad owner or
  # permissions") — which also breaks git-over-ssh, since git shells out to
  # ssh. hm ships ~/.ssh/config as a symlink into the store, so thaw it into
  # a real user-owned file after linking. no-op when the link is already
  # gone (idempotent across switches).
  home.activation.thawSshConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    conf="$HOME/.ssh/config"
    if [ -L "$conf" ]; then
      target="$(readlink -f "$conf")"
      rm "$conf"
      cp "$target" "$conf"
      chmod 600 "$conf"
    fi
  '';
}
