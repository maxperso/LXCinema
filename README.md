# LXCinema

A self-hosted media stack (Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr,
qBittorrent behind a VPN, Seerr) running in Docker inside an **unprivileged
LXC container on Proxmox**, with the Intel iGPU passed through for
QuickSync hardware transcoding.

## Why another media stack repo

There are dozens of them, and the good ones are years ahead of this one. If
all you want is a `docker-compose.yml` to copy, any of them will do; the
compose file here is unremarkable.

What this repo documents is the part the others mostly skip, because they
assume a VM or bare metal: getting Docker to run in an unprivileged LXC, and
getting the iGPU and the TUN device through to the containers that need
them. That lives in [docs/lxc-proxmox.md](docs/lxc-proxmox.md).

One finding in particular: the iGPU recipe most guides give (cgroup allow
lines plus a bind mount of `/dev/dri`) makes the GPU *visible* in an
unprivileged LXC but not *usable*. Everything looks right, direct play
works, and the first real transcode fails. This setup ran like that for a
while before I noticed. The guide shows how to tell, and the fix.

The other thing worth reading is the upgrade I did in September 2026:
Jellyfin 10.10.7 to 12.1, and Jellyseerr to Seerr, at the same time. Both
break authentication for older clients and Jellyfin's database migration is
one-way. Most tutorials online predate this and will leave you on an
outdated version. The full account, including what I got wrong, is in
[docs/migration-2026-09.md](docs/migration-2026-09.md).

## Documentation

| Document | What's in it |
|---|---|
| [docs/lxc-proxmox.md](docs/lxc-proxmox.md) | The LXC config (nesting, keyctl, iGPU and TUN passthrough), why the usual iGPU recipe fails, and how to confirm transcoding really is hardware |
| [docs/migration-2026-09.md](docs/migration-2026-09.md) | Jellyfin 10.10.7 → 12.1 and Jellyseerr → Seerr, as it happened on 24 September 2026 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom → cause table, with the exact error strings |
| [scripts/check-igpu.sh](scripts/check-igpu.sh) | Checks the iGPU layer by layer, from the Proxmox host to a real QSV encode in the container |

## Quick start

Set up the LXC first ([docs/lxc-proxmox.md](docs/lxc-proxmox.md)). Without
nesting and keyctl Docker will not start, and without the TUN device
Gluetun will not connect.

```bash
git clone https://github.com/maxperso/LXCinema.git media-stack
cd media-stack
cp .env.example .env
$EDITOR .env          # Proton WireGuard key, paths, UID/GID
docker compose up -d
```

| Service | Port | Role |
|---|---|---|
| Jellyfin | 8096 | Playback |
| Seerr | 5055 | Media requests |
| qBittorrent | 8080 | Torrent client, behind the VPN |
| Sonarr | 8989 | TV shows |
| Radarr | 7878 | Movies |
| Prowlarr | 9696 | Indexers |
| Bazarr | 6767 | Subtitles |

## Image tags

| Service | Tag | Why |
|---|---|---|
| jellyfin | exact version (`12.1ubu2604-ls50`) | Every upgrade runs a database migration you can't roll back without a backup. This is the one service where an accidental pull can cost data. |
| seerr | `v3` (major-version alias) | Picks up security fixes without jumping a major version. The project fixed three CVEs in February 2026. |
| everything else | `latest` | Clean migrations, cheap to roll back. |

The risk with `latest` isn't automatic updates: Docker never pulls anything
unless you run `docker compose pull`. The risk is that a pull meant for one
service moves every `latest` service at once, and when something breaks you
can't tell which one did it. Pull one service at a time:

```bash
docker compose pull sonarr && docker compose up -d sonarr
```

LinuxServer tags don't follow upstream numbering. `12.1ubu2604-ls50` means
Jellyfin 12.1, built on Ubuntu 26.04, LinuxServer build 50. The `ubu` part
is the base image inside the container and has nothing to do with the host
distribution (Debian here). To list available tags:

```bash
curl -s 'https://hub.docker.com/v2/repositories/linuxserver/jellyfin/tags?page_size=100&name=12.1' \
  | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -v 'amd64\|arm64'
```

## Things to know before running this

### Never publish your config directories

The `*/config` directories hold API keys, passwords and, worst of all, your
indexer passkeys, which identify you personally on a private tracker.

Keep the folder you publish separate from the one you run. Don't
`git init` in your production directory. The `.gitignore` here is a backup
plan, not the plan. A secret pushed to GitHub is compromised within
seconds, since bots scan the public feed for exactly that; rewriting
history doesn't help, you have to revoke it.

### Back up Jellyfin before upgrading

Stop the container first: a SQLite database copied mid-write may not be
usable. Run this **before** changing the tag in the compose file, so the
archive is named after the version it restores to. An archive is only
useful with that exact version; once the next migration has run, it can't
be applied to the new one.

```bash
docker compose stop jellyfin
JF_TAG=$(docker compose config --images | grep jellyfin | cut -d: -f2)
tar czf ~/jellyfin-config-$JF_TAG-$(date +%F).tar.gz -C jellyfin config
```

### qBittorrent has no network identity of its own

It runs with `network_mode: service:gluetun`, so its ports are published by
the `gluetun` service. In Sonarr, Radarr and Prowlarr, the download client
host is **`gluetun`, not `qbittorrent`**. Docker's DNS has no entry for a
container without its own network stack, and on some ISPs the unresolved
name leaks to public DNS and quietly resolves to some unrelated server. The
connection test then fails with errors that don't look like DNS at all.

### Proton's forwarded port changes on every reconnect

The `port-sync` service pushes the current port into qBittorrent. Without
it, torrents sit at "no incoming connections" with no obvious reason.

[port-sync/sync-port.sh](port-sync/sync-port.sh) talks to the WebUI API
without credentials. It shares Gluetun's network namespace, so its requests
come from localhost: enable **Bypass authentication for clients on
localhost** in qBittorrent (Options > WebUI), or every update fails.

That's also why the compose file publishes no torrent port. Don't forward
6881 on your home router to "fix" connectivity: peers would reach the
client on your real IP, which defeats the VPN.

## Known limitations

This runs on a closed home network, reachable from outside only through
WireGuard. It is not a security reference:

- no network segmentation, no VLANs
- the Proxmox firewall is enabled on the container's interface
  (`firewall=1`) but no rules are defined
- root SSH with password auth on the LAN containers
- a single NVMe disk holds everything, media included, so there is no
  3-2-1 backup

Written down so nobody copies this onto an exposed machine thinking it's
good practice.

## License

MIT, see [LICENSE](LICENSE).
