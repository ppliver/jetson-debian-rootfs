#!/usr/bin/env bash
# build_rootfs.sh — Build a Debian 11 (bullseye) arm64 rootfs for Jetson AGX Xavier
# with NVIDIA L4T R35.6.5 (35.6.5-20260701022834) userspace + CUDA driver stack.
#
# Runs natively on arm64 GitHub-hosted runners (ubuntu-24.04-arm), no qemu needed.
# Reproduces the proven on-device recipe (2026-11-24, cuInit=0 verified on Xavier):
#   debootstrap bullseye -> inject nvidia-l4t-* debs via dpkg -x -> patch layer
#
# Usage (root): bash build/build_rootfs.sh
set -euo pipefail

# ----------------------- configuration -----------------------
DEBIAN_SUITE="${DEBIAN_SUITE:-bullseye}"
# Mirror candidates, tried in order (first with a valid Release file wins)
MIRROR_CANDIDATES=(
  "http://deb.debian.org/debian"
  "http://mirrors.tuna.tsinghua.edu.cn/debian"
  "http://mirrors.tuna.tsinghua.edu.cn/debian-archive/debian"
  "http://archive.debian.org/debian"
)
NV_REPO_BASE="https://repo.download.nvidia.com/jetson"
NV_SUITE="${NV_SUITE:-r35.6}"
NV_COMPONENTS=(common t194)   # t194 = Xavier AGX
# Exact L4T version shipped in JetPack 5.1.x for R35.6.5 (matches running kernel
# 5.10.216-tegra #1 SMP PREEMPT Wed Jul 1 02:07:52 PDT 2026)
NV_VERSION="${NV_VERSION:-35.6.5-20260701022834}"

# Headless CUDA set (GUI/Weston/X11/GStreamer/camera intentionally excluded).
# Package -> repo component resolved automatically from Packages index.
NV_PACKAGES=(
  nvidia-l4t-core
  nvidia-l4t-cuda
  nvidia-l4t-firmware
  nvidia-l4t-init
  nvidia-l4t-configs
  nvidia-l4t-kernel
  nvidia-l4t-kernel-dtbs
  nvidia-l4t-kernel-headers
  nvidia-l4t-display-kernel
  nvidia-l4t-nvsci
  nvidia-l4t-nvpmodel
  nvidia-l4t-xusb-firmware
)

KERNEL_VERSION="${KERNEL_VERSION:-5.10.216-tegra}"

# Device defaults (this image targets the lab Xavier, easy to override via env)
DEV_USER="${DEV_USER:-nvidia}"
DEV_PASS="${DEV_PASS:-nvidia}"
ROOT_PASS="${ROOT_PASS:-root}"
DEV_HOSTNAME="${DEV_HOSTNAME:-debian11-xavier}"
DEV_MAC="${DEV_MAC:-48:B0:2D:3D:CB:A8}"      # Xavier onboard NIC (nvethernet)
DEV_IP="${DEV_IP:-192.168.219.171/24}"
DEV_GW="${DEV_GW:-192.168.219.176}"          # lab side-router
NVME_UUID="${NVME_UUID:-61be83cb-0d3c-4fcf-879f-6c76be6f83f6}"  # optional /mnt/nvme, nofail

WORK="${WORK:-/tmp/rootfs-build}"
ROOTFS="$WORK/rootfs"
DEBS="$WORK/debs"

# ----------------------- helpers -----------------------
log() { echo -e "\e[1;32m[build] $*\e[0m"; }
die() { echo -e "\e[1;31m[build:FATAL] $*\e[0m" >&2; exit 1; }

run_in_rootfs() {
  # chroot with api-fs mounted
  chroot "$ROOTFS" /bin/bash -e -c "$1"
}

# ----------------------- preflight -----------------------
[ "$(id -u)" = 0 ] || die "run as root"
mkdir -p "$ROOTFS" "$DEBS"
echo "build dir: $WORK"; df -h /tmp | tail -1

# ----------------------- mirror selection -----------------------
MIRROR=""
for m in "${MIRROR_CANDIDATES[@]}"; do
  if curl -fsSL --max-time 20 "${m}/dists/${DEBIAN_SUITE}/Release" -o /dev/null; then
    MIRROR="$m"; break
  fi
done
[ -n "$MIRROR" ] || die "no mirror serves ${DEBIAN_SUITE}"
log "using mirror: $MIRROR (suite ${DEBIAN_SUITE})"

# ----------------------- stage 1: debootstrap -----------------------
# --no-merged-usr is REQUIRED: nvidia-l4t-* debs are built for split-usr
# (Ubuntu 20.04). On a merged-usr rootfs, dpkg -x of the kernel deb replaces
# the /lib -> usr/lib symlink with a real dir and kills the ELF loader path
# (/lib/ld-linux-aarch64.so.1), i.e. every binary in the chroot goes ENOENT.
log "debootstrap ${DEBIAN_SUITE} arm64 (native, split-usr)..."
debootstrap --variant=minbase --arch=arm64 --no-merged-usr --include="ca-certificates" \
  "$DEBIAN_SUITE" "$ROOTFS" "$MIRROR"

# api-fs for chroot
mount -t proc proc "$ROOTFS/proc"
mount --rbind /dev  "$ROOTFS/dev"  && mount --make-rslave "$ROOTFS/dev"
mount --rbind /sys  "$ROOTFS/sys"  && mount --make-rslave "$ROOTFS/sys"
cleanup_mounts() {
  umount -l "$ROOTFS/proc" "$ROOTFS/dev" "$ROOTFS/sys" 2>/dev/null || true
}
trap cleanup_mounts EXIT

cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${DEBIAN_SUITE} main contrib non-free
EOF

# ----------------------- stage 2: base system via apt -----------------------
log "apt install base toolchain inside chroot..."
run_in_rootfs "apt-get update"
run_in_rootfs "env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  systemd systemd-sysv sudo openssh-server gcc libc6-dev make kmod ntp tzdata locales \
  iputils-ping net-tools ifupdown python3 rsync nano less ca-certificates \
  e2fsprogs util-linux xxd"

# ----------------------- stage 3: NVIDIA L4T R35.6.5 layer -----------------------
log "resolving NVIDIA deb URLs from Packages index (suite ${NV_SUITE})..."
> "$WORK/nv_urls.txt"
for comp in "${NV_COMPONENTS[@]}"; do
  curl -fsSL "${NV_REPO_BASE}/${comp}/dists/${NV_SUITE}/main/binary-arm64/Packages" \
    -o "$WORK/Packages.${comp}"
  python3 - "$WORK/Packages.${comp}" "$comp" >> "$WORK/nv_urls.txt" <<'PYEOF'
import sys
blocks = open(sys.argv[1]).read().split("\n\n")
comp = sys.argv[2]
for b in blocks:
    pkg = ver = fn = None
    for line in b.splitlines():
        if line.startswith("Package: "): pkg = line[9:]
        elif line.startswith("Version: "): ver = line[9:]
        elif line.startswith("Filename: "): fn = line[10:]
    if pkg and fn:
        print(f"{comp}\t{pkg}\t{ver or ''}\t{fn}")
PYEOF
done

log "downloading ${#NV_PACKAGES[@]} nvidia-l4t debs (version ${NV_VERSION})..."
for pkg in "${NV_PACKAGES[@]}"; do
  row=$(python3 - "$WORK/nv_urls.txt" "$pkg" "$NV_VERSION" <<'PYEOF'
import sys
rows = [l.split("\t") for l in open(sys.argv[1]).read().splitlines() if "\t" in l]
pkg, want = sys.argv[2], sys.argv[3]
cands = [r for r in rows if r[1] == pkg]
# prefer exact version, else newest available
exact = [r for r in cands if r[2] == want]
pick = exact[0] if exact else (max(cands, key=lambda r: r[2]) if cands else None)
if pick is None:
    sys.exit(f"package not found in index: {pkg}")
print(pick[0] + "\t" + pick[3])
PYEOF
) || die "resolve failed: $pkg"
  comp="${row%%$'\t'*}"
  url="${row#*$'\t'}"
  fn="$DEBS/$(basename "$url")"
  [ -f "$fn" ] || curl -fsSL --retry 3 "${NV_REPO_BASE}/${comp}/${url}" -o "$fn"
  log "  $(basename "$fn") ($(numfmt --to=iec $(stat -c%s "$fn")))"
  dpkg -x "$fn" "$ROOTFS"
done

# ldconfig + depmod for the injected libs/modules
run_in_rootfs "ldconfig"
depmod -b "$ROOTFS" "$KERNEL_VERSION"

# ----------------------- stage 4: patch layer (proven on-device recipe) -----------------------
log "applying Xavier patch layer..."

# 4.1 kernel module autoload (Ubuntu parity)
cat > "$ROOTFS/etc/modules-load.d/nv.conf" <<EOF
nvmap
nvgpu
EOF

# 4.2 idempotent fallback service (modprobe, no insmod -> no false-failure)
mkdir -p "$ROOTFS/etc/systemd/system"
cat > "$ROOTFS/etc/systemd/system/nvgpu-autoload.service" <<'EOF'
[Unit]
Description=Load NVIDIA Tegra nvmap/nvgpu modules for CUDA
DefaultDependencies=no
After=systemd-modules-load.service
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/sbin/modprobe nvmap
ExecStart=/sbin/modprobe nvgpu
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
mkdir -p "$ROOTFS/etc/systemd/system/sysinit.target.wants"
ln -sf ../nvgpu-autoload.service "$ROOTFS/etc/systemd/system/sysinit.target.wants/nvgpu-autoload.service"

# 4.3 ld.so path for tegra libs (dpkg -x skips postinst)
cat > "$ROOTFS/etc/ld.so.conf.d/nvidia-tegra.conf" <<EOF
/usr/lib/aarch64-linux-gnu/tegra
EOF
run_in_rootfs "ldconfig"

# 4.4 serial console on TCU (rescue path)
mkdir -p "$ROOTFS/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/serial-getty@.service \
  "$ROOTFS/etc/systemd/system/getty.target.wants/serial-getty@ttyTCU0.service"

# 4.5 network: replicate the proven on-device setup exactly —
#     udev renames the onboard NIC (nvethernet, MAC-pinned) to ethlan,
#     ifupdown brings up static config (net.ifnames=0 comes from eMMC cmdline)
mkdir -p "$ROOTFS/etc/systemd/network" "$ROOTFS/etc/udev/rules.d" "$ROOTFS/etc/network"
cat > "$ROOTFS/etc/udev/rules.d/70-onboard-lan.rules" <<EOF
SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="$(echo ${DEV_MAC} | tr 'A-F' 'a-f')", NAME="ethlan"
EOF
cat > "$ROOTFS/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

# Onboard LAN (MAC pinned by udev rule) - same IP as Ubuntu (systems don't run together)
auto ethlan
iface ethlan inet static
    address ${DEV_IP%/*}
    netmask 255.255.255.0
    gateway ${DEV_GW}
    dns-nameservers 223.5.5.5 8.8.8.8
EOF

# 4.6 DNS persistence hook (ifupdown wipes resolv.conf on ifup)
cat > "$ROOTFS/etc/network/if-up.d/00-dns" <<'EOF'
#!/bin/sh
printf "nameserver 223.5.5.5\nnameserver 8.8.8.8\n" > /etc/resolv.conf
EOF
chmod 755 "$ROOTFS/etc/network/if-up.d/00-dns"

# 4.7 NTP: aliyun pool (debian pool unreachable from CN networks)
sed -i 's|^pool .*pool.ntp.org.*|pool ntp.aliyun.com iburst|' "$ROOTFS/etc/ntp.conf"

# 4.8 timezone
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$ROOTFS/etc/localtime"
echo "Asia/Shanghai" > "$ROOTFS/etc/timezone"

# 4.9 fstab — root entry intentionally ABSENT: the kernel mounts / via root=UUID
#     from extlinux.conf (eMMC shared boot chain), a placeholder UUID here would
#     drop first boot into emergency mode. Sync mode applied by remount service.
cat > "$ROOTFS/etc/fstab" <<EOF
# NOTE: no root line — / comes from root=UUID=... in /boot/extlinux/extlinux.conf
# lab NVMe (harmless nofail elsewhere)
UUID=${NVME_UUID}   /mnt/nvme    ext4  defaults,nofail                  0  2
EOF
mkdir -p "$ROOTFS/mnt/nvme"

# 4.9b root sync mode (hard-reboot data-loss protection, proven on device)
cat > "$ROOTFS/etc/systemd/system/remount-root-sync.service" <<'EOF'
[Unit]
Description=Remount root ext4 with sync (data-loss protection on hard reboot)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/mount -o remount,sync /
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf ../remount-root-sync.service \
  "$ROOTFS/etc/systemd/system/multi-user.target.wants/remount-root-sync.service"

# 4.10 users
run_in_rootfs "echo 'root:${ROOT_PASS}' | chpasswd"
run_in_rootfs "useradd -m -s /bin/bash ${DEV_USER} && echo '${DEV_USER}:${DEV_PASS}' | chpasswd"
cat > "$ROOTFS/etc/sudoers" <<EOF
Defaults env_reset
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
root ALL=(ALL:ALL) ALL
${DEV_USER} ALL=(ALL:ALL) NOPASSWD: ALL
@includedir /etc/sudoers.d
EOF
chmod 440 "$ROOTFS/etc/sudoers"
mkdir -p "$ROOTFS/etc/sudoers.d"

# 4.11 identity
echo "$DEV_HOSTNAME" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${DEV_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
EOF
rm -f "$ROOTFS/etc/machine-id"; touch "$ROOTFS/etc/machine-id"

# 4.12 services: ssh + ntp enabled at boot (systemctl --root, no bus needed)
mkdir -p "$ROOTFS/etc/ssh"
sed -i 's|^#\?PermitRootLogin.*|PermitRootLogin no|' "$ROOTFS/etc/ssh/sshd_config" || true
systemctl --root="$ROOTFS" enable ssh.service ntp.service nvpmodel.service 2>/dev/null || \
  ln -sf /lib/systemd/system/ssh.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/ssh.service"

# 4.13 GPU sanity script (cuInit check, proven recipe from the lab session)
mkdir -p "$ROOTFS/opt/tools"
cat > "$ROOTFS/opt/tools/gpu_check.py" <<'EOF'
import ctypes
l = ctypes.CDLL("libcuda.so.1")
r = l.cuInit(0)
print("cuInit =", r)
if r == 0:
    dev, name, mem = ctypes.c_int(), ctypes.create_string_buffer(256), ctypes.c_size_t()
    l.cuDeviceGet(ctypes.byref(dev), 0)
    l.cuDeviceGetName(name, 256, dev)
    l.cuDeviceTotalMem_v2(ctypes.byref(mem), dev)
    print(name.value.decode(), int(mem.value) // (1024*1024), "MB")
EOF
chmod 755 "$ROOTFS/opt/tools/gpu_check.py"

# ----------------------- stage 5: verification -----------------------
log "verifying critical artifacts..."
must_exist=(
  "usr/lib/aarch64-linux-gnu/tegra/libcuda.so.1"
  "lib/firmware/gv11b/gpmu_ucode_image.bin"
  "lib/modules/${KERNEL_VERSION}/kernel/drivers/video/tegra/nvmap/nvmap.ko"
  "lib/modules/${KERNEL_VERSION}/kernel/drivers/gpu/nvgpu/nvgpu.ko"
  "lib/modules/${KERNEL_VERSION}/modules.dep"
  "etc/systemd/system/nvgpu-autoload.service"
  "lib/ld-linux-aarch64.so.1"
)
# fail loudly if the rootfs drifted into merged-usr (breaks deb injection)
[ ! -L "$ROOTFS/lib" ] || die "rootfs /lib is a symlink (merged-usr) — deb injection unsafe"
for f in "${must_exist[@]}"; do
  [ -e "$ROOTFS/$f" ] || die "missing after injection: $f"
  log "  ok: $f"
done

run_in_rootfs "python3 -c 'import ctypes; print(\"ctypes ok\")'" || die "python3 broken in rootfs"
run_in_rootfs "gcc --version | head -1"
run_in_rootfs "ldconfig -p | grep libcuda | head -2" || true

log "rootfs size: $(du -sh "$ROOTFS" | cut -f1)"

# ----------------------- stage 6: pack -----------------------
# slim down before packing
run_in_rootfs "apt-get clean"
rm -rf "$ROOTFS/var/lib/apt/lists/"*
# static DNS (if-up.d/00-dns rewrites it on ethlan up anyway)
printf "nameserver 223.5.5.5\nnameserver 8.8.8.8\n" > "$ROOTFS/etc/resolv.conf"

STAMP=$(date +%Y%m%d)
OUT="$WORK/debian11-${DEBIAN_SUITE}-xavier-${NV_VERSION}-${STAMP}.rootfs.tar.zst"
log "packing $OUT ..."
tar -C "$ROOTFS" -cf - . | zstd -3 -T0 -o "$OUT"
SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
echo "$SHA  $(basename "$OUT")" > "${OUT}.sha256"
log "packed: $(numfmt --to=iec $(stat -c%s "$OUT"))  sha256=$SHA"

# final state dump for the artifact
{
  echo "== build info =="
  echo "date: $(date -u +%FT%TZ)"
  echo "debian: ${DEBIAN_SUITE}  mirror: ${MIRROR}"
  echo "l4t: ${NV_VERSION}  suite: ${NV_SUITE}  kernel: ${KERNEL_VERSION}"
  echo "rootfs size: $(du -sh "$ROOTFS" | cut -f1)"
  echo "tarball: $(numfmt --to=iec $(stat -c%s "$OUT"))  sha256: $SHA"
  echo "== critical files =="
  for f in "${must_exist[@]}"; do echo "  $f"; done
} > "$WORK/build_info.txt"

log "DONE"
