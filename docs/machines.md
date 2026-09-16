# Machines

## Installing on another Mac  (install.sh)
    # on the SOURCE machine (this one):
    rsync -avz -e ssh --exclude 'log/*' --exclude '*.bak-*' ~/Downloads/YTLive/ USER@HOST:Downloads/YTLive/
    # on the TARGET machine:
    cd ~/Downloads/YTLive && ./install.sh          # installs, does not start
    # grant Full Disk Access to /bin/zsh, then:
    ./install.sh --start
install.sh installs ffmpeg/ffprobe + yt-dlp into ~/.local/bin, writes the LaunchAgents
with that user's home, rebuilds the playlist, and probes Full Disk Access. It refuses to
start until FDA is granted. Only ONE machine may push to a given YouTube key at a time.
It produces no bundle or archive: the rsync above is the transfer, and `git clone` is the
other way to reproduce a checkout.

## Who can ssh into the streamer  (star, verified 2026-09-16)
Every machine below holds a key in `user@ternak-macbook:~/.ssh/authorized_keys`. Each was
verified by running `ssh <machine> 'ssh user@100.75.83.5 hostname'` **from that machine**,
not by inspecting the file:

    node1@node1               key comment node1@Node1.local      (this checkout's machine)
    node2@node2               key comment node2@Node2.local
    node3@node3               key comment node3@Node3.local
    node4@node4               key comment node4@deltasona
    andreborchert@macbook-ab  key comment andre@pummelchen-mac
    claude-code@Maria-MacBook, ytlive                            (pre-existing, left in place)

This is a **star, not a mesh**: those five machines can reach the streamer, and the streamer
cannot reach them. `bin/ssh_mesh.sh` builds a *full* mesh instead — do not run it with these
hosts unless you genuinely want node1..node4 to ssh into each other too.

**Blast radius.** These keys are unrestricted. A shell on any one of those five machines is
anything-as-`user` on the box that controls the YouTube channel: it can read the stream key out
of `ps` and the OAuth refresh token out of `conf/yt_oauth.json`. Password authentication is also
still enabled on the streamer, so the account is additionally guarded only by its password. See
**T-23** in the wiki tracker.

## Machines / SSH mesh  (2026-09-05)
Full key mesh verified, all 6 directions:
    user@ternak-macbook      100.75.83.5     Intel, macOS 12   (the streamer)
    maria@macbook-maria      100.80.66.66    arm64, macOS 26   (copy of YTLive in ~/Downloads/YTLive, NOT installed/started)
    andreborchert@macbook-ab 100.101.16.45   ("MacBook AB")
Re-verify or add a machine:  bin/ssh_mesh.sh maria@macbook-maria andreborchert@macbook-ab
Sync the folder again:       rsync -az --stats -e ssh --exclude 'log/*' --exclude '*.bak-*' --exclude conf/playlist.txt ~/Downloads/YTLive/ maria@macbook-maria:Downloads/YTLive/
(macOS ships rsync 2.6.9: use --stats, not --info.)

## SSH keys between the Macs
The streamer MacBook (Tailscale `ternak-macbook`, the machine README and AGENTS describe)
has ~/.ssh/id_ed25519 (no passphrase, for unattended rsync); its public key is also in
conf/ternak-macbook.pub. First-time install of that key on another Mac needs that Mac's
password once:   ssh-copy-id USER@macbook-maria   (or macbook-ab)

## Tailscale
Installer downloaded to ~/Downloads/Tailscale-1.102.3-macos.pkg (signed by Tailscale Inc.,
notarized, declares min macOS 11.0 so Monterey is fine). Install + sign-in are yours to do.
Do NOT tick "Use as exit node" and do not select an exit node.
