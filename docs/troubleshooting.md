# Troubleshooting: symptom → cause

As of September 2026. Most rows are problems I hit on this install. Rows
marked *(not reproduced)* describe what a piece of config is there to
prevent; I haven't seen the failure myself. Error strings are quoted
verbatim where I have them, so you can search for them.

## LXC and devices

| Symptom | Cause | Fix |
|---|---|---|
| Docker won't start in the LXC *(not reproduced)* | `nesting` or `keyctl` not enabled | `features: keyctl=1,nesting=1`, see [lxc-proxmox.md](lxc-proxmox.md#nesting-and-keyctl) |
| Gluetun never connects; qBittorrent has no network at all *(not reproduced)* | `/dev/net/tun` not passed through to the unprivileged LXC | The two TUN lines in [lxc-proxmox.md](lxc-proxmox.md#tun-devnettun-needed-by-gluetun) |
| `/dev/dri` missing inside the LXC *(not reproduced)* | No device passthrough in the container config, or the wrong node name copied from a tutorial | `devN:` entry for the render node read from `ls -l /dev/dri` on the host; `scripts/check-igpu.sh <CTID>` on the host checks it |
| `/dev/dri/renderD128` shows as `nobody:nogroup` in the LXC | Old recipe (`lxc.cgroup2.devices.allow` + `/dev/dri` bind mount): the host's `render` group isn't mapped into an unprivileged LXC | Replace it with `dev0: /dev/dri/renderD128,gid=<PGID>`, see [lxc-proxmox.md](lxc-proxmox.md#igpu-the-fix-proxmox-device-passthrough) |
| `vainfo` in the container: `Failed to open the given device!` | The Jellyfin user isn't in the group that owns the render node | Same as above. With `gid=992` (the LXC's `render` group) the LinuxServer image did not add `abc` to it; `gid=<PGID>` works |
| Playback fails as soon as it has to transcode: "Playback failed due to a fatal player error", and the FFmpeg log ends with `No VA display found for device /dev/dri/renderD128.` / `Device creation failed: -22.` / `Error parsing global options: Invalid argument` | Same cause. Jellyfin doesn't fall back to software | Same fix |
| Hardware transcoding "tested" fine, but it fails later | The test was a direct play or direct stream: the FFmpeg log is `FFmpeg.DirectStream-*` or `FFmpeg.Remux-*` with `-codec:v:0 copy` | Test at the lowest quality and check the log says `h264_qsv` or `hevc_qsv` |
| Transcoding falls back to software after a Jellyfin upgrade | `encoding.xml` rejected at startup, settings reset to defaults | Set QSV again in Dashboard > Playback > Transcoding, see below |

## Jellyfin

| Symptom | Cause | Fix |
|---|---|---|
| `Error loading configuration file: /config/encoding.xml` followed by `Instance validation error: '' is not a valid value for EncoderPreset` | An empty field tolerated before 12.x is now invalid; Jellyfin starts without its encoding settings | Reconfigure transcoding in the UI and save, which rewrites the file |
| `Plugin installed: Open Subtitles 25.0.0.0` then `App needs to be restarted.` | Jellyfin replaced the plugin with a compatible build | Restart the container |
| Upgrade checklist says remove plugins, but `config/plugins` is empty | Plugins live in `config/data/plugins` | Look there |
| Server shows up under a new name in every client after `docker compose up -d` | Container hostname defaults to the container ID, which changes on recreation | Set the name in Dashboard > General, and `hostname:` in compose |
| Display glitches in the web UI right after upgrading to 12.x | Cached assets from the old version | Hard refresh (Ctrl+Shift+R) |
| Alternate versions of a film disappeared after upgrading to 12.x | Auto-resolved alternate versions are removed by the migration | Full library scan |
| `tail -15 file` in the Jellyfin container: `error: unexpected argument '-1' found` | The 12.1 LinuxServer image is based on Ubuntu 26.04, whose `tail` rejects the old `-15` form | `tail -n 15 file` |
| Old TV app or third-party client stops connecting after 12.0 | Legacy auth disabled even on existing servers (`DisableLegacyAuthorization` in the logs), `/emby/` and `/mediabrowser/` routes removed | Update the client; `EnableLegacyAuthorization=true` works on 12.x only, and goes away in 13 |
| Netflix-style CSS theme does nothing since 10.11 | The web UI was reworked, the theme's selectors no longer exist | No fix, the theme needs updating by its author |
| Script or `meta refresh` in the login message is stripped | The field is sanitised, links and formatting only | Working as intended |

## Seerr / Jellyseerr

| Symptom | Cause | Fix |
|---|---|---|
| Jellyseerr login fails with "something went wrong while trying to sign in", API returns 400 or 404 | Jellyseerr sends `X-Emby-Authorization`, Jellyfin 12 expects `Authorization` | Move to Seerr, see [migration-2026-09.md](migration-2026-09.md#2-jellyseerr-is-dead-long-live-seerr) |
| Seerr and the old Jellyseerr fighting over port 5055; Compose warns about orphan containers | The renamed service's old container is still running | `docker compose up -d --remove-orphans` |
| Seerr can't write its config *(not reproduced)* | Seerr runs as `node` (UID 1000) whatever PUID says | `chown -R 1000:1000 seerr/config` |

## Downloads and indexers

| Symptom | Cause | Fix |
|---|---|---|
| Download client test fails in Sonarr/Radarr/Prowlarr with host `qbittorrent`, with errors that don't look like DNS | qBittorrent uses Gluetun's network stack, so Docker DNS has no `qbittorrent` entry; some ISPs then resolve the name to an unrelated public server | Use `gluetun` as the host |
| Prowlarr indexer tests fail with misleading errors | ISP DNS hijacks failed lookups (SFR does) | `dns:` set to public resolvers on the prowlarr service |
| `port-sync` logs `[port-sync] update failed (qBittorrent not ready?), retrying` forever *(not reproduced)* | qBittorrent rejects the unauthenticated API call | Enable "Bypass authentication for clients on localhost" in qBittorrent |
| Torrents stuck at "no incoming connections" | Proton gave a new forwarded port on reconnect and qBittorrent still listens on the old one | Check that `port-sync` is running |
