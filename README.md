# jetson-debian-rootfs

Debian 11 (bullseye) rootfs for **Jetson AGX Xavier** (L4T R35.6.5 / JetPack 5.1.x), built natively on GitHub Actions **arm64** runners (free for public repos, no qemu emulation).

Produces a CUDA-capable rootfs: `cuInit=0`, Xavier 30991MB / CC 7.2 / 8 SMs — verified on-device with the exact same recipe (2026-11-24).

## What's inside

| Layer | Source |
|---|---|
| Debian 11 bullseye base | debootstrap (mirror auto-fallback: deb.debian.org → TUNA → archive) |
| NVIDIA L4T userspace (libcuda, firmware, kernel modules, dtbs) | `repo.download.nvidia.com/jetson/{common,t194}` suite `r35.6`, pinned `35.6.5-20260701022834` (matches running kernel `5.10.216-tegra`) |
| Patch layer (proven on-device) | modules-load.d/nv.conf + idempotent `nvgpu-autoload.service`, tegra ldconfig path, MAC-pinned udev `ethlan` + static IP, DNS hook, NTP aliyun + Asia/Shanghai, fstab (root sync mode + NVMe nofail), sudo NOPASSWD, serial console on ttyTCU0 |

Headless scope: GUI/Weston/X11/GStreamer/camera debs intentionally excluded. Included: systemd, ssh, sudo, gcc, make, kmod, ntp, python3, rsync.

## CI build

Push to `main` touching `build/**`, or run manually (workflow_dispatch). Artifact: `debian11-xavier-rootfs` (~3GB tar.zst + sha256 + build_info.txt), retention 14 days.

## Flash to a USB drive (on the Xavier)

```bash
# 1. Format (on-device mkfs; if using WSL add -O ^metadata_csum_seed,^orphan_file
#    or UEFI's ext4 driver will fail to mount APP/rootfs!)
lsblk                       # find the USB disk node, e.g. /dev/sda
sudo mkfs.ext4 -L rootfs /dev/sdX1
sudo blkid /dev/sdX1        # note UUID=...

# 2. Untar
sudo mount /dev/sdX1 /mnt/usb
sudo tar -I zstd -xf debian11-*.rootfs.tar.zst -C /mnt/usb
sync

# 3. Point the boot entry at it (eMMC /boot/extlinux/extlinux.conf is shared)
#    LABEL debian entry: root=UUID=<usb-uuid>
sudo fdtput /boot/extlinux/extlinux.conf ... # (edit root= line only)
sudo reboot
```

Boot menu (eMMC extlinux.conf): `DEFAULT debian` boots USB rootfs; select `primary` for stock Ubuntu.

## Credentials & network defaults (override via env in build_rootfs.sh)

- user `nvidia` / `nvidia` (sudo NOPASSWD), root `root`
- hostname `debian11-xavier`, onboard NIC MAC `48:B0:2D:3D:CB:A8` → `ethlan` → 192.168.219.171/24 gw 192.168.219.176

## Gotchas (learned the hard way, encoded in this repo)

- `rmmod nvgpu` kernel-panics; modules are loaded idempotently instead.
- Hard reboot loses un-synced ext4 writes → root is mounted `sync`.
- Xavier has no RTC battery → fake clock at boot; NTP (aliyun pool) + Asia/Shanghai preinstalled.
- CUDA works even though `/dev/nvhost-gpu` may not appear in `ls /dev` — don't use node presence as a failure signal; check `cuInit` instead.

## Dual-boot auto-select (USB Debian / eMMC Ubuntu fallback)

Implemented via a patched eMMC initrd: USB rootfs mount retry extended to 30s, with automatic fallback to `/dev/mmcblk0p1` when the USB drive is absent. Factory initrd preserved as `initrd.orig` (used by primary/backup/recovery menu entries).

- Docs: [docs/dualboot-incident-20261125.md](docs/dualboot-incident-20261125.md) — full incident post-mortem: the A/B rootfs retry-counter lockout that forces "Attempting Recovery Boot" (no menu shown), the UEFI Shell rescue via `dmpstore -d RootfsStatusSlotA/B`, and the verified acceptance matrix.
- Quick rescue if boot enters Recovery Boot with no menu (UEFI Shell):
  ```
  dmpstore -d -guid 781E084C-A330-417C-B678-38E696380CB9 RootfsStatusSlotA
  dmpstore -d -guid 781E084C-A330-417C-B678-38E696380CB9 RootfsStatusSlotB
  reset
  ```

## Chinese version & dual-boot tooling

- 中文文档：[README.zh-CN.md](README.zh-CN.md) (includes TF-card (/dev/mmcblk1) dual-boot disk prep)
- Boot-layer (eMMC initrd) patch scripts live in [tools/](tools/): v1 fallback + v2 retry-window extension — both verified on-device 2026-11-25.
- Note: CI builds the **rootfs content**; the dual-boot auto-select lives in the **eMMC boot layer** (patched initrd + extlinux.conf). Switching rootfs media (USB <-> TF card) only requires changing `root=UUID=...` in extlinux.conf — no initrd changes needed.

## `dualboot` — boot-target switcher (installed on both systems)

Deployed to `/usr/local/bin/dualboot` on **both** the USB/TF Debian and the eMMC Ubuntu. Run with sudo:

```
dualboot status          # running OS / menu labels / next-boot target
dualboot poweroff        # shutdown
dualboot reboot          # reboot (current DEFAULT)
dualboot switch debian   # next boot -> USB Debian (reboots after 3s)
dualboot switch ubuntu   # next boot -> eMMC Ubuntu  (reboots after 3s)
dualboot switch <label> [--noreboot]   # primary / backup / recovery
```

It only rewrites `DEFAULT` in the canonical extlinux.conf (auto-locates it: `/boot` when running eMMC Ubuntu, or mounts the eMMC APP partition when running Debian) — initrd patches and fallback logic stay untouched.
