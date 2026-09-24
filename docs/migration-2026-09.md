# Jellyfin 12 and Jellyseerr → Seerr: field report

Done on 24 September 2026. Starting point: Jellyfin 10.10.7 and
Jellyseerr 2.x, in an unprivileged LXC on Proxmox.

This is what actually happened, in order, wrong assumptions included.
Version details describe the projects as of that date and will age.

## 1. Where it started: Jellyseerr login broken

### Symptom

Signing in to Jellyseerr with a Jellyfin account failed. The UI showed a
generic "something went wrong while trying to sign in", and the API
returned 400 or 404. My workaround at the time had been to hold Jellyfin
back on an older version.

### Cause

Jellyfin is phasing out its legacy authentication. The schedule announced
by the project:

| Version | Legacy authentication |
|---|---|
| 10.10.x | on |
| 10.11.x | on by default, opt-out flag for developers |
| 12.0 (formerly 10.12) | **off by default**, can be re-enabled with `EnableLegacyAuthorization=true` |
| 13 (upcoming) | removed, no workaround |

Jellyseerr sent an `X-Emby-Authorization` header where Jellyfin now
expects `Authorization`.

So this was neither a Jellyseerr bug nor a Jellyfin bug but an announced
deprecation. Any third-party client that hasn't been updated is affected,
not just Jellyseerr.

### Version numbering trap

Jellyfin dropped the leading `10.` from its version numbers. After `10.11.x`
comes `12.x`; there is no `10.12`. Check any script, monitoring probe or
container tag that parses the version string before upgrading.

## 2. Jellyseerr is dead, long live Seerr

The Jellyseerr and Overseerr teams merged in **February 2026** to form
**Seerr**: one codebase, one repository, same maintainers. The
`fallenbagel/jellyseerr` image is a dead end.

The main reason to move is security. Seerr v3.1.0 fixes three CVEs,
including one that let an authenticated user read another user's profile,
notification tokens included. Jellyseerr will never get those fixes.
Seerr also sends the modern auth header, so it works with Jellyfin 12. On
top of that come TVDB metadata aligned with Sonarr, a DNS cache,
region/collection blocklists and ntfy notifications.

### What changes

| | Jellyseerr | Seerr |
|---|---|---|
| Image | `fallenbagel/jellyseerr` | `ghcr.io/seerr-team/seerr` |
| User | root | `node` (UID 1000) |
| Init process | included | **none**, so `init: true` is required |

### What I did

I copied the config instead of reusing it in place, so the old directory
stays untouched as an instant rollback.

```bash
docker compose stop jellyseerr
cp -a jellyseerr seerr
chown -R 1000:1000 seerr/config
```

Then replaced the service block in the compose file and removed the old
container:

```bash
docker compose up -d --remove-orphans
```

Without `--remove-orphans` the old `jellyseerr` container keeps running and
fights the new one for port 5055. Compose does warn about orphan
containers, but it's easy to miss.

### Result

Seerr migrated the data on first start and applied two settings
migrations (`0007_migrate_arr_tags`, `0008_migrate_blacklist_to_blocklist`).
Users, requests and *arr connections all came through.

The `v3` tag pulled **3.4.1**.

**Verified here:** Seerr authenticates against Jellyfin **10.10.7**. The
log shows `Found matching Jellyfin user; updating user with Jellyfin`,
which confirms the existing user was matched rather than recreated.

## 3. Jellyfin upgrade: 10.10.7 → 10.11.11 → 12.1

### Why two steps

The official docs allow going straight from 10.10.7 to 12.0. Stopping at
10.11.11 was my choice, not a requirement. 10.11.0 rewrote the library
database, so a direct jump runs two sets of migrations back to back on a
database in the old schema, and if it fails you can't tell which set broke
it. The intermediate step also let me check that playback positions had
survived before going further.

The cost is two maintenance windows instead of one.

### Checked before starting

- [ ] Starting version is at least 10.10.7 (anything older fails to upgrade)
- [ ] **No two accounts differ only by letter case**, or the 12.0 migration
      fails
- [ ] Third-party plugins removed (10.11 plugins don't load on 12 until
      their authors rebuild them)
- [ ] Enough free disk space
- [ ] Cold backup of the config directory (container stopped)

**My mistake:** I looked for plugins in `config/plugins`, which was empty.
They live in **`config/data/plugins`**. An Open Subtitles plugin was
installed there and I missed it.

### How it went

**10.10.7 → 10.11.11**: no issues.

**10.11.11 → 12.1**: the migration took **8 seconds** on a 621-item
library, 18 schema migrations followed by 15 data migrations. Jellyfin
backs up `jellyfin.db` on its own before starting.

It also ran some cleanup on its own: merging artists and people that were
duplicates by case, deleting orphaned extras, recomputing normalised
names, and a full path check.

### Two problems

#### `encoding.xml` rejected

```
[ERR] Error loading configuration file: /config/encoding.xml
Instance validation error: '' is not a valid value for EncoderPreset
```

An empty field in the encoding config, previously tolerated, is now
invalid. Jellyfin started **without its encoding settings**, falling back
to defaults. That file is where the QuickSync hardware acceleration
settings live.

Fix: go to Dashboard > Playback > Transcoding, set hardware acceleration
back to QSV with the render device, and save. Saving from the UI rewrites
the file cleanly.

ffmpeg 8.1.2 in the 12.1 image does list `h264_qsv`, `hevc_qsv` and the
`qsv` hardware type, so QSV support is there on the container side.

After reconfiguring I played something, it worked, and I ticked hardware
transcoding off as verified. That was wrong. The FFmpeg log for that
playback was a `DirectStream` with `-codec:v:0 copy`: the browser decoded
the HEVC itself and nothing was transcoded. When I later forced a real
transcode, it failed, and not because of the upgrade. The GPU had never
been usable from this unprivileged LXC; the `encoding.xml` problem was
sitting on top of an older one. The whole story and the fix are in
[lxc-proxmox.md](lxc-proxmox.md#igpu-the-usual-recipe-looks-right-and-doesnt-work).

Lesson: a playback test only counts if the FFmpeg log says the video was
transcoded.

#### Plugin updated, restart required

```
Plugin installed: Open Subtitles 25.0.0.0
App needs to be restarted.
```

Jellyfin swapped the plugin for a compatible version by itself, but the
new version only loads after a restart.

### The risk that didn't happen

One user reported that after upgrading to 12.0, some of their unwatched
series had been **marked as watched**, seemingly at random, with no way to
undo it from the UI.

What I knew at the time of writing: the report exists, from one user, and
there's no rollback from the UI. What I didn't know: how often it happens,
why, or whether 12.1 fixes it. I found nothing matching in the 12.1 release
notes, but the list I read was partial.

Unknown probability, probably low, irreversible outcome. That's a risk you
cover with a backup rather than try to predict.

Practical tip: before upgrading, write down where you are on two or three
series. It gives you something to compare against right after restart,
instead of wondering three days later whether you'd seen an episode.

It didn't happen on this install.

### Checks after the upgrade, in this order

1. **Hard-refresh the browser** (Ctrl+Shift+R). Cached assets are the most
   common cause of display glitches after this upgrade.
2. Watched status on the series you noted down.
3. **Full library scan.** Not optional: auto-resolved alternate versions
   are removed during the migration and only come back with a scan.
4. Resume positions.
5. Hardware transcoding, with a real transcode: lowest quality in the
   player, then check the newest `FFmpeg.Transcode-*.log` shows
   `h264_qsv` or `hevc_qsv`, not `copy`.
6. Seerr: sign-in and logs.

## 4. What 12.0 breaks besides authentication

- The old `/emby/` and `/mediabrowser/` routes are **gone**.
- Legacy auth is turned off **on existing servers too**, not just new
  installs (migration `DisableLegacyAuthorization`, visible in the logs).
- Old third-party clients stop working. A TV app that hasn't been updated
  in years is a likely candidate.
- Plugins built for 10.11 don't load.

## 5. Other things learned along the way

**The Jellyfin server name changed every time the container was
recreated.** Docker gives a container a hostname derived from its ID by
default, and Jellyfin uses it when nothing else is set, so every
`up -d` showed up as a new name in all clients. Set the name in
Dashboard > General (stored in `system.xml`, survives recreation), and add
`hostname:` to the compose service as well.

**The Netflix-style avatar grid is built in.** These aren't profiles in the
Netflix sense but real users, each with their own permissions and
password. The login screen switches to the grid as soon as at least one
user is visible. The checkbox is phrased in the negative, "hide this user
from login screens", so checked means hidden. One-click login would mean
removing passwords, which is only defensible on a closed local network.

**Community Netflix-style CSS themes are broken since 10.11.** The web UI
was reworked and most of the selectors they target no longer exist.
Tutorials you'll find online target older versions. The custom CSS field
itself still works (Dashboard > Branding).

The login message field is **sanitised**: links and formatting pass, but
scripts, `onerror` attributes and `meta refresh` are stripped. Several
tutorials suggest otherwise.
