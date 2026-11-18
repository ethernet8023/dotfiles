# Rekordbox on window: SMB setup

Bellona serves two shares over SMB, LAN-only:

- `\\192.168.2.59\music` — read-only music library
- `\\192.168.2.59\rekordbox` — read-write Rekordbox database
- `\\192.168.2.59\vault` — read-write markdown vault

The account is `ethernet`. Its SMB password is the `password=` line of the
agenix secret `bellona-smb`. Read it on luna with:

```
agenix -d ~/dotfiles/secrets/bellona-smb.age
```

(It is the same value the CIFS mounts on luna/hermes/iris use.)

## One-time setup on window

1. Join the house LAN. window has no tailnet node, so SMB only works on the
   house LAN; Rekordbox will not reach the DB from anywhere else.
2. Map the shares. In an elevated `cmd.exe`:

```
net use R: \\192.168.2.59\rekordbox /user:ethernet * /persistent:yes
net use M: \\192.168.2.59\music /user:ethernet * /persistent:yes
```

`*` prompts for the password once; Windows Credential Manager stores it.

3. Close Rekordbox completely.
4. Move the existing database folder to the share (or start fresh):

```
move "%APPDATA%\Pioneer\rekordbox" "R:\rekordbox"
```

5. Point Rekordbox at it with a directory link. A junction is preferred but
   needs a local target; a directory symlink works with a UNC target and needs
   admin or Developer Mode:

```
mklink /D "%APPDATA%\Pioneer\rekordbox" "R:\rekordbox"
```

If `mklink` refuses, use the UNC path directly:

```
mklink /D "%APPDATA%\Pioneer\rekordbox" "\\192.168.2.59\rekordbox\rekordbox"
```

6. Launch Rekordbox and confirm the collection loads. Add tracks from `M:`.

## Rules that keep it from corrupting

- Exactly one machine may have the Rekordbox library open at a time. Do not run
  Rekordbox on two machines, and do not leave it open on window while another
  session mounts the share.
- The DB is SQLite over SMB. If the share drops mid-write, close Rekordbox and
  restore from bellona's nightly `sqlite3 .backup` in `tank/rekordbox`.
- Bellona snapshots `tank` hourly/daily via sanoid; those are the fallback.
- For gigs, export to USB. Do not rely on wifi mid-set.
- `music` is read-only; Rekordbox can read it but cannot write tags back. Tag
  in beets on bellona, or copy a track locally if you need to edit it.

## Mounting on iris (darwin)

iris gets the same shares from the same box, but not over the LAN address: the
macbook is usually somewhere else on the tailnet. smbd binds `lo enp191s0`
only, so the darwin launchd agent (`darwin/all-darwin-configuration.nix`) does
one of two things at login:

- on the house LAN it mounts `//ethernet@192.168.2.59/<share>` directly;
- otherwise it opens `ssh -L 4445:127.0.0.1:445 ethernet@100.95.51.7` and
  mounts `//ethernet:<pw>@127.0.0.1:4445/<share>`, because `mount_smbfs` does
  accept a port in the server part of the URL and bellona's smbd is listening
  on loopback.

Mountpoints are `~/Volumes/bellona-music`, `~/Volumes/bellona-rekordbox` and
`~/Volumes/bellona-vault` -- `/Volumes` is root-owned, so a user agent cannot
create anything there. The credential comes from the agenix secret
`bellona-smb`; no `~/.nsmbrc` is required for the tunnel path.

A rekordbox library on iris is a *copy* of `master.db`, not a live mount: the
DB is SQLite and the tunnel is high-latency, so `~/Library/Pioneer/rekordbox`
stays local and tracks get relinked to `~/Volumes/bellona-music`.

## If the share is not reachable

- `ping 192.168.2.59`, then `net use` to see whether the mapping is in a
  disconnected state; `net use R: /delete` and re-map.
- Check bellona: `systemctl status samba-smbd`, `smbclient -L //192.168.2.59 -U ethernet`.
- SMB is firewalled to the LAN and to `enp191s0` only; it is not exposed to the
  internet.
