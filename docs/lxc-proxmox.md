# Docker in an unprivileged LXC, with iGPU and TUN passthrough

As of September 2026, on Proxmox with a Debian 13 container.

This is the part most media stack guides skip. They assume a VM or bare
metal, and the few that cover LXC usually run it privileged. It's also where
this setup was quietly broken for a while: the usual iGPU recipe makes the
GPU visible in an unprivileged container without making it usable.

## Why an LXC and not a VM

A container shares the host kernel. That means no virtualisation overhead,
near-instant start, memory that is only used when needed, and above all
access to the integrated GPU without PCI passthrough. On a VM, the iGPU
would need VFIO and would be taken away from the host entirely.

The cost is weaker isolation than a VM, plus some explicit configuration
before Docker will run in an unprivileged container.

On a single small machine with one iGPU to share, the LXC is the reasonable
trade-off. On hardware dedicated to media, a VM would be cleaner.

## The machine

- Lenovo ThinkCentre M720q: i5-8500T (UHD Graphics 630), 16 GB RAM,
  one 256 GB NVMe
- Proxmox host, container 111 running Debian 13, unprivileged
- The container gets 4 cores, 6 GB RAM, 512 MB swap and a 90 GB root
  filesystem on `local-lvm`, and starts on boot
- Everything runs in one Docker Compose project inside that container

Running the whole stack in one LXC goes against the usual "one service per
container" advice. The services share paths and qBittorrent shares
Gluetun's network, so splitting them would cost more than it gains.

## The container config

This is `/etc/pve/lxc/111.conf` from the host, as it runs now. Use it as a
template, not something to paste: the device path and group depend on your
setup.

```
arch: amd64
cores: 4
dev0: /dev/dri/renderD128,gid=1000
features: keyctl=1,nesting=1
hostname: media-stack
memory: 6144
net0: name=eth0,bridge=vmbr0,firewall=1,gw=192.168.1.1,,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-111-disk-0,size=90G
swap: 512
tags: video
unprivileged: 1
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net dev/net none bind,create=dir
```

The `net0` line is redacted: I removed `hwaddr` and `ip`, which is why
there's a double comma. It's not a syntax error in the original.

The Proxmox firewall is enabled on the interface (`firewall=1`), but I
haven't defined any rules.

The `tags: video` line is only a label in the Proxmox UI. It does nothing
for device access.

### Nesting and keyctl

`features: keyctl=1,nesting=1`. Docker needs nesting to create its own
namespaces, and without keyctl some Docker operations fail with unhelpful
errors. Both can be set in the web UI under Options > Features.

### iGPU: the usual recipe looks right and doesn't work

Until 24 September 2026 this container used the recipe you'll find in most
guides: allow the devices in the cgroup, bind-mount `/dev/dri`.

```
lxc.cgroup2.devices.allow: c 226:1 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
```

Everything looked fine. The devices showed up in the LXC and in the
Jellyfin container, Jellyfin's startup log listed `h264_qsv` and
`hevc_qsv`, QSV was selected in the transcoding settings, and playback
worked. I believed hardware transcoding worked, and wrote so in an early
draft of this page.

It didn't. Here is what each layer actually saw:

| Where | `renderD128` | Who can open it |
|---|---|---|
| Proxmox host | `root:render`, `crw-rw----` | root and the host's `render` group |
| LXC | `nobody:nogroup` (65534), `crw-rw----` | nobody |
| Jellyfin container | `nobody:nogroup`, `crw-rw----` | nobody |
| Jellyfin process | runs as uid 1000, groups `100 1000` | |

An unprivileged LXC maps its UIDs and GIDs 0-65535 onto a range on the
host (100000 and up by default). The host's `render` group is outside that
range, so inside the container the kernel shows it as the overflow ID,
65534. The cgroup lines only allow the device; they don't change who owns
it. With mode `660` and an owner nobody inside can be, nothing can open it.

`vainfo`, run as the Jellyfin user, said so directly:

```
Trying display: drm
Failed to open the given device!
```

And the first playback that really needed a transcode failed. The web
client said "Playback failed due to a fatal player error" (I saw the
French UI, this is the English wording), and the FFmpeg log said:

```
[VAAPI @ 0x578653af2fc0] No VA display found for device /dev/dri/renderD128.
Device creation failed: -22.
Failed to set value 'vaapi=va:/dev/dri/renderD128,driver=iHD' for option 'init_hw_device': Invalid argument
Error parsing global options: Invalid argument
```

Jellyfin did not fall back to software. It just failed.

Why I didn't notice for so long: every playback until then had been direct
play or direct stream. Modern browsers decode HEVC themselves (Firefox did,
on my machine), so Jellyfin only copied the video (`-codec:v:0 copy` in the
FFmpeg log) and never touched the GPU. My "verification" was one of those.

### iGPU: the fix, Proxmox device passthrough

Proxmox can create a device node inside the container with the owner you
choose (`devN:` entries, added in Proxmox VE 8.1; this host runs 9.2.6).
It replaces the three lines above:

```
dev0: /dev/dri/renderD128,gid=<PGID>
```

Or from the host shell, container stopped:

```bash
pct set <CTID> -dev0 /dev/dri/renderD128,gid=1000
```

The web UI has the same thing under Resources > Add > Device Passthrough.

QSV only needs the render node, so `card*` doesn't have to be passed at all.
Check the render node's name with `ls -l /dev/dri` on the host; it's usually
`renderD128`, but read it rather than assume it, the way the card number
turned out to be `card1` here when most tutorials say `card0`.

**Why `gid=1000` and not the `render` group.** I tried `gid=992` first,
the `render` group inside the LXC. The device then showed up as
`root:render` in the LXC, but inside the Jellyfin container the user `abc`
still wasn't in group 992, so still no access. The LinuxServer image
printed nothing about `/dev/dri` at startup and didn't add `abc` to the
device's group. I haven't dug into why. Giving the device to the group
`abc` is already in, 1000 (the stack's `PGID`), works without depending on
the image doing anything. The trade-off: inside the LXC, the GPU belongs to
the media user's group rather than `render`. Only Jellyfin mounts
`/dev/dri`, so the other services still can't reach it.

Not tried: `group_add` in the compose file. I expect it wouldn't help,
because the image starts as root and then switches to `abc` with
`s6-setuidgid`, which should recompute the groups from `/etc/group` and
drop the ones Docker added. That is an assumption.

After the fix:

| Where | `renderD128` |
|---|---|
| LXC | `root`, group 1000, `crw-rw----` |
| Jellyfin container | `root:abc`, `crw-rw----` |

`vainfo` reports `Intel iHD driver for Intel(R) Gen Graphics - 26.2.4`,
test encodes with `h264_qsv` and `hevc_qsv` succeed, and the playback that
failed now plays.

### TUN: `/dev/net/tun`, needed by Gluetun

The last two lines of the config pass through the TUN device (character
device 10:200):

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net dev/net none bind,create=dir
```

Gluetun creates its WireGuard interface on `/dev/net/tun`. An unprivileged
LXC doesn't have that device, so without these two lines the VPN never
comes up and qBittorrent, which only has Gluetun's network, is left with
no connectivity at all. I haven't seen this mentioned in other *arr stack
guides, probably because on a VM or bare metal the device is just there.

The compose file then hands it to Gluetun with
`devices: - /dev/net/tun:/dev/net/tun`.

The old-style recipe is fine here, unlike for the GPU. `/dev/net/tun` shows
up as `nobody:nogroup` in the LXC too, but its mode is `crw-rw-rw-`, so the
owner doesn't matter.

### UID mapping

An unprivileged LXC shifts UIDs: UID 1000 inside the container is 101000 on
the host. That's invisible as long as everything stays inside the LXC, and
this config needs no `lxc.idmap` lines. It's the first thing to suspect when
something from the host shows up as `nobody:nogroup`, as the GPU did above.

## Checking it end to end

[scripts/check-igpu.sh](../scripts/check-igpu.sh) does this layer by layer.
Run it on the host with the container ID, then inside the LXC. By hand:

1. In the LXC, `ls -l /dev/dri`. The render node must be there and **not**
   owned by `nobody:nogroup`. If it's missing or unmapped, fix
   `/etc/pve/lxc/<CTID>.conf`; Docker has nothing to do with it yet.
2. The compose file passes `/dev/dri` to Jellyfin:
   ```yaml
       devices:
         - /dev/dri:/dev/dri
   ```
3. In Jellyfin, Dashboard > Playback > Transcoding: hardware acceleration
   set to **QSV**, render device filled in.
4. Force a real transcode: in the player, pick the **lowest** quality. A
   higher one may still be above the file's bitrate and get copied.
5. Look at the newest file in Jellyfin's log directory (`/config/log` in the
   container). It must be an `FFmpeg.Transcode-*.log` whose command line
   has `-codec:v:0 h264_qsv` (or `hevc_qsv`). `FFmpeg.DirectStream-*` or
   `FFmpeg.Remux-*`, or `-codec:v:0 copy`, means the video wasn't
   transcoded, and the test proved nothing.

Jellyfin's startup log lists the codecs its ffmpeg supports. Seeing
`h264_qsv` there proves the build has QSV support. It says nothing about
whether the container can open the device, as this setup demonstrated.

Verified on this setup, Jellyfin 12.1, 24 September 2026: the script passes
every step, and a playback forced to the lowest quality, which failed
before the fix, plays.

## Upgrades can silently reset the encoding settings

When I moved to Jellyfin 12.1, `encoding.xml` was rejected at startup
because an empty field had become invalid. Jellyfin carried on with default
settings, which means no hardware acceleration, and nothing in the UI said
so. Details in [migration-2026-09.md](migration-2026-09.md).

Re-check transcoding after every Jellyfin version bump.

## What this setup doesn't do

- no network segmentation, no VLANs
- Proxmox firewall enabled on the interface but no rules defined
- root SSH with password auth on the LAN containers
- no 3-2-1 backup, everything is on one disk

Fine on a closed home network. Don't reproduce it as is on anything
exposed.
