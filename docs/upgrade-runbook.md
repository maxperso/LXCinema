# Upgrade runbook

The checklist I follow to move Jellyfin to a new version. It's distilled
from [migration-2026-09.md](migration-2026-09.md); read that for the
reasoning and what went wrong. Written in September 2026, when the current
version was 12.1.

Jellyfin is the only service here that needs a procedure. Its upgrades run
database migrations that can't be undone without a backup. For the others,
pull one service at a time so that if something breaks you know what did:

```bash
docker compose pull sonarr && docker compose up -d sonarr
```

## Before

- [ ] Read the release notes for every version between yours and the
      target: <https://github.com/jellyfin/jellyfin/releases>. Look for
      minimum starting versions, removed features, and client breakage.
- [ ] Check which third-party plugins are installed. They are in
      `jellyfin/config/data/plugins`, **not** `config/plugins`. A major
      version usually means they won't load until rebuilt.
- [ ] Going to 12.x: make sure no two accounts differ only by case.
- [ ] Enough free disk space for the archive, plus the copy of
      `jellyfin.db` Jellyfin makes before migrating.
- [ ] Write down the watched state and resume position of two or three
      series, so you have something to compare against afterwards.

## Back up

Stop the container, then archive the config under the **current** tag,
before touching the compose file:

```bash
docker compose stop jellyfin
JF_TAG=$(docker compose config --images | grep jellyfin | cut -d: -f2)
tar czf ~/jellyfin-config-$JF_TAG-$(date +%F).tar.gz -C jellyfin config
ls -lh ~/jellyfin-config-$JF_TAG-*.tar.gz
```

Remember this setup has no 3-2-1 backup: the archive sits on the same disk
as the data. Copy it off the machine if you care about disk failure during
the upgrade.

## Upgrade

Find the exact LinuxServer tag for the target version:

```bash
curl -s 'https://hub.docker.com/v2/repositories/linuxserver/jellyfin/tags?page_size=100&name=12.1' \
  | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -v 'amd64\|arm64'
```

Change the `image:` line of the jellyfin service in `docker-compose.yml`,
then:

```bash
docker compose pull jellyfin
docker compose up -d jellyfin
docker compose logs -f jellyfin
```

Watch the log until the web UI comes up. Migrations are listed one by one.
Any `[ERR]` line deserves a look, especially `Error loading configuration
file`: a rejected config file means Jellyfin started with defaults for that
section, without saying so in the UI.

For a jump across several major versions, consider stopping at the last
minor release in between. It's slower but tells you which step broke.

## After, in this order

1. Hard-refresh the browser (Ctrl+Shift+R).
2. Watched state on the series you noted.
3. Full library scan. Needed after 12.x, since alternate versions are
   removed during the migration and only come back with a scan.
4. Resume positions.
5. Transcoding. Check Dashboard > Playback > Transcoding is still on QSV
   with a render device, then play something at the **lowest** quality and
   run `scripts/check-igpu.sh` in the LXC. Its log step must show a
   `FFmpeg.Transcode-*` file with `h264_qsv` or `hevc_qsv`. A
   `DirectStream` or `copy` means nothing was transcoded and the test
   proves nothing.
6. Seerr sign-in, and the clients people actually use (TV apps first).
7. Restart once if the log said `App needs to be restarted.` after a
   plugin update.

Keep the archive until you're satisfied. It only restores to the version
it was taken from.

## Rolling back

Not tested on this install; this is the procedure the backup is designed
for.

```bash
docker compose stop jellyfin
mv jellyfin/config jellyfin/config.failed-$(date +%F)
tar xzf ~/jellyfin-config-<old tag>-<date>.tar.gz -C jellyfin
# put the old tag back in docker-compose.yml
docker compose up -d jellyfin
```

Anything watched or changed since the upgrade is lost.
