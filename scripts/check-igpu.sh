#!/usr/bin/env bash
# Checks the iGPU passthrough one layer at a time, from the Proxmox host down
# to a real QuickSync encode inside the Jellyfin container. Stops at the first
# layer that fails, since everything below it would fail for the same reason,
# except the permission check, which only warns: the encode is the real test.
#
# On the Proxmox host:  ./check-igpu.sh [CTID]
#   Prints the lxc.conf lines this hardware calls for. With a CTID, also
#   checks /etc/pve/lxc/<CTID>.conf for them and flags the old cgroup/bind
#   mount recipe, which leaves the GPU unusable in an unprivileged LXC.
#
# Inside the LXC:       ./check-igpu.sh
#   Checks the devices in the LXC, in the container, the container user's
#   access to the render node, then encodes a few seconds of test video with
#   h264_qsv. Only that last step proves transcoding really is hardware.
#
# Environment overrides: JF_CONTAINER (default jellyfin), JF_USER (default
# abc, the LinuxServer image user), FFMPEG_DIR (default /usr/lib/jellyfin-ffmpeg),
# PGID (default 1000, the group the render node should belong to).

set -u
shopt -s nullglob

JF_CONTAINER=${JF_CONTAINER:-jellyfin}
JF_USER=${JF_USER:-abc}
FFMPEG_DIR=${FFMPEG_DIR:-/usr/lib/jellyfin-ffmpeg}
PGID=${PGID:-1000}

ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; exit 1; }
step() { printf '\n%s\n' "$*"; }

# Prints mode, numeric owner, named owner and major:minor for each device.
show_devices() {
    for dev in "$@"; do
        [ -e "$dev" ] || continue
        printf '    %s  %s  uid:gid %s  (%s)  %d:%d\n' \
            "$(stat -c '%A' "$dev")" "$dev" "$(stat -c '%u:%g' "$dev")" \
            "$(stat -c '%U:%G' "$dev")" \
            "0x$(stat -c '%t' "$dev")" "0x$(stat -c '%T' "$dev")"
    done
}

host_mode() {
    local ctid=${1:-}

    step "Host: Proxmox version"
    local pve
    pve=$(pveversion 2>/dev/null | sed -n 's|^pve-manager/\([0-9]*\.[0-9]*\).*|\1|p')
    if [ -z "$pve" ]; then
        warn "could not read pveversion"
    elif [ "${pve%%.*}" -gt 8 ] || { [ "${pve%%.*}" -eq 8 ] && [ "${pve#*.}" -ge 1 ]; }; then
        ok "Proxmox VE $pve (devN: passthrough needs 8.1 or later)"
    else
        fail "Proxmox VE $pve is older than 8.1, no devN: passthrough. See docs/lxc-proxmox.md."
    fi

    step "Host: /dev/dri"
    set -- /dev/dri/card* /dev/dri/renderD*
    [ $# -gt 0 ] || fail "no /dev/dri devices on the host. Is the iGPU enabled in the BIOS and the i915 driver loaded?"
    show_devices "$@"
    local nodes=(/dev/dri/renderD*)
    [ ${#nodes[@]} -gt 0 ] || fail "no renderD* node on the host. QSV needs the render node."
    local render=${nodes[0]}

    step "Host: /dev/net/tun (for Gluetun)"
    local tun=0
    if [ -c /dev/net/tun ]; then
        show_devices /dev/net/tun
        tun=1
    else
        warn "/dev/net/tun missing on the host (modprobe tun)"
    fi

    # The render node goes to the stack's PGID, the group the LinuxServer
    # user already belongs to. See docs/lxc-proxmox.md for why not "render".
    step "Lines this hardware calls for in /etc/pve/lxc/<CTID>.conf (PGID=$PGID)"
    printf '    dev0: %s,gid=%s\n' "$render" "$PGID"
    if [ "$tun" -eq 1 ]; then
        printf '    lxc.cgroup2.devices.allow: c 10:200 rwm\n'
        printf '    lxc.mount.entry: /dev/net dev/net none bind,create=dir\n'
    fi

    [ -n "$ctid" ] || return 0

    local conf=/etc/pve/lxc/$ctid.conf
    step "Checking $conf"
    [ -r "$conf" ] || fail "cannot read $conf"
    # Only the current config, not the [snapshot] sections below it.
    local current
    current=$(awk '/^\[/ { exit } { print }' "$conf")

    local missing=0
    grep -q '^unprivileged: 1' <<<"$current" && ok "unprivileged" || warn "not unprivileged (this guide assumes it is)"
    grep -q '^features:.*nesting=1' <<<"$current" && ok "nesting=1" || { warn "nesting=1 missing, Docker will not run"; missing=1; }
    grep -q '^features:.*keyctl=1' <<<"$current" && ok "keyctl=1" || { warn "keyctl=1 missing"; missing=1; }

    local devline
    devline=$(grep -E "^dev[0-9]+: $render(,|\$)" <<<"$current")
    if [ -z "$devline" ]; then
        warn "no devN: entry for $render"; missing=1
    elif grep -qE "(,|: [^,]*,)gid=$PGID(,|\$)" <<<"$devline"; then
        ok "$devline"
    else
        warn "$devline: gid is not $PGID, the Jellyfin user may not be able to open it"; missing=1
    fi
    if grep -qE '^lxc\.(cgroup2\.devices\.allow: c 226:|mount\.entry: /dev/dri )' <<<"$current"; then
        warn "old-style /dev/dri lines present (cgroup2 226:* or /dev/dri bind mount). They make the"
        warn "device visible but owned by nobody:nogroup in the LXC. Remove them in favour of devN:."
        missing=1
    fi

    if [ "$tun" -eq 1 ]; then
        for line in 'lxc.cgroup2.devices.allow: c 10:200 rwm' 'lxc.mount.entry: /dev/net dev/net none bind,create=dir'; do
            if grep -qxF "$line" <<<"$current"; then
                ok "$line"
            else
                warn "missing: $line"; missing=1
            fi
        done
    fi

    [ "$missing" -eq 0 ] || fail "fix $conf, then restart the container (pct reboot $ctid)"
    ok "config looks right. Run this script inside the LXC next."
}

lxc_mode() {
    step "LXC: /dev/dri"
    set -- /dev/dri/card* /dev/dri/renderD*
    [ $# -gt 0 ] || fail "/dev/dri is empty or missing in the LXC. The problem is in /etc/pve/lxc/<CTID>.conf, not Docker. Run this script on the host."
    show_devices "$@"
    local nodes=(/dev/dri/renderD*)
    [ ${#nodes[@]} -gt 0 ] || fail "no renderD* node in the LXC, only a card. QSV needs the render node."
    local render=${nodes[0]}
    if [ "$(stat -c '%g' "$render")" = 65534 ]; then
        warn "$render is owned by nogroup: the host group isn't mapped into this LXC, so"
        warn "nothing in here can open it. Use devN: passthrough, see docs/lxc-proxmox.md."
    else
        ok "render node: $render"
    fi

    step "LXC: /dev/net/tun (for Gluetun, not needed for transcoding)"
    if [ -c /dev/net/tun ]; then
        show_devices /dev/net/tun
        ok "present"
    else
        warn "missing. Gluetun will not come up. See docs/lxc-proxmox.md, TUN section."
    fi

    step "Container '$JF_CONTAINER'"
    command -v docker >/dev/null || fail "docker not found"
    [ "$(docker inspect -f '{{.State.Running}}' "$JF_CONTAINER" 2>/dev/null)" = true ] \
        || fail "container $JF_CONTAINER is not running"
    ok "running"

    step "Container: /dev/dri"
    docker exec "$JF_CONTAINER" test -e "$render" \
        || fail "$render not visible in the container. Check 'devices: - /dev/dri:/dev/dri' in the compose file."
    docker exec "$JF_CONTAINER" sh -c \
        'for d in /dev/dri/*; do printf "    %s  %s  uid:gid %s  (%s)\n" "$(stat -c %A "$d")" "$d" "$(stat -c %u:%g "$d")" "$(stat -c %U:%G "$d")"; done'
    printf '    id %s: %s\n' "$JF_USER" "$(docker exec "$JF_CONTAINER" id "$JF_USER" 2>&1)"

    # Not fatal: permissions inside a user namespace can be misleading, and
    # the encode below is the real test.
    step "Container: can $JF_USER open $render?"
    if docker exec -u "$JF_USER" "$JF_CONTAINER" sh -c "test -r $render && test -w $render"; then
        ok "read/write access"
    else
        warn "$JF_USER has no read/write access according to the permission bits. Trying the encode anyway."
        warn "The device's group (above) should be one of $JF_USER's groups, usually the PGID."
    fi

    step "Jellyfin: last FFmpeg job and its video encoder"
    local log
    # Any FFmpeg job, so a remux or direct stream shows up too: its name tells
    # you playback didn't need a transcode at all.
    log=$(docker exec "$JF_CONTAINER" sh -c 'ls -t /config/log/FFmpeg.*.log 2>/dev/null | head -n1')
    if [ -n "$log" ]; then
        printf '    %s\n' "$log"
        local enc
        enc=$(docker exec "$JF_CONTAINER" grep -m1 -oE -- '-codec:v:0 [^ ]+' "$log")
        if [ "$enc" = "-codec:v:0 copy" ]; then
            printf '    %s\n' "$enc"
            warn "video was copied, not transcoded. This playback says nothing about the GPU."
        elif [ -n "$enc" ]; then
            printf '    %s\n' "$enc"
        else
            warn "no video encoder found in that log"
        fi
    else
        warn "no FFmpeg log in /config/log. Play something at a forced lower quality first."
    fi

    step "Container: VA-API driver"
    if docker exec "$JF_CONTAINER" test -x "$FFMPEG_DIR/vainfo"; then
        local va
        va=$(docker exec -u "$JF_USER" "$JF_CONTAINER" "$FFMPEG_DIR/vainfo" --display drm --device "$render" 2>&1)
        if grep -q 'Driver version' <<<"$va"; then
            ok "$(grep -m1 'Driver version' <<<"$va" | sed 's/^.*: //')"
        else
            printf '%s\n' "$va" | sed 's/^/    /'
            warn "vainfo could not initialise the device. Trying the encode anyway, for its error message."
        fi
    else
        warn "$FFMPEG_DIR/vainfo not found, skipping"
    fi

    step "Container: real QSV encode (3 s of test video)"
    local ffmpeg=$FFMPEG_DIR/ffmpeg
    qsv_encode() {
        docker exec -u "$JF_USER" "$JF_CONTAINER" "$ffmpeg" -hide_banner -v error \
            -init_hw_device "vaapi=va:$render" -init_hw_device qsv=qs@va -filter_hw_device qs \
            -f lavfi -i testsrc2=size=1280x720:rate=30 -t 3 \
            -vf 'format=nv12,hwupload=extra_hw_frames=64' -c:v "$1" -f null - 2>&1
    }
    local out
    if out=$(qsv_encode h264_qsv); then
        ok "h264_qsv encode succeeded"
    else
        printf '%s\n' "$out" | sed 's/^/    /'
        fail "h264_qsv encode failed"
    fi
    if out=$(qsv_encode hevc_qsv); then
        ok "hevc_qsv encode succeeded"
    else
        printf '%s\n' "$out" | sed 's/^/    /'
        warn "hevc_qsv failed (older iGPUs lack HEVC encode)"
    fi

    printf '\nDone. The device works; whether Jellyfin uses it depends on\n'
    printf 'Dashboard > Playback > Transcoding, which an upgrade can reset.\n'
}

if command -v pct >/dev/null 2>&1; then
    host_mode "$@"
else
    lxc_mode
fi
