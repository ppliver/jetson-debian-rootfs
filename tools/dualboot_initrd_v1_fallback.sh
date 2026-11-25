#!/bin/bash
# Dual-boot patch v1: eMMC initrd fallback — USB/TF rootfs absent -> boot eMMC Ubuntu
#
# What it does (run from any Linux that can mount eMMC rw, e.g. the running Debian):
#   1. Keeps factory initrd as /boot/initrd.orig (independent rescue path)
#   2. Patches initrd's init: on rootfs mount failure, retry mounting /dev/mmcblk0p1
#      instead of process_bash_reboot (which dead-silently waits on serial console)
#   3. extlinux.conf: TIMEOUT 100, primary/backup use factory initrd.orig,
#      adds "recovery" entry (factory initrd + USB debian root)
#
# Verified on-device 2026-11-25: USB present -> Debian (zero extra wait);
# USB absent -> 30s retry then automatic eMMC Ubuntu. See docs/dualboot-incident-20261125.md
set -e
M=/mnt/ubuntu_probe
BOOT=$M/boot

# 0. mount eMMC rw (reuse existing mount if OK, else fresh mount)
if ! mountpoint -q "$M"; then
  umount -l "$M" 2>/dev/null || true
  for i in $(seq 1 40); do
    grep -qs "$M" /proc/mounts || break
    sleep 0.5
  done
  mount /dev/mmcblk0p1 "$M" || { echo "FATAL: eMMC mount failed"; exit 1; }
fi
mount | grep "$M" | grep -qs ',rw[ ,]' || { mount -o remount,rw "$M" || { echo "FATAL: not rw"; exit 1; }; }
echo "== eMMC mounted =="

# 1. keep factory copy
if [ ! -f "$BOOT/initrd.orig" ]; then
  cp -a "$BOOT/initrd" "$BOOT/initrd.orig"
  echo "initrd.orig created"
else
  echo "initrd.orig already exists"
fi
md5sum "$BOOT/initrd" "$BOOT/initrd.orig"

# 2. extract
rm -rf /tmp/irp && mkdir -p /tmp/irp/x
zcat "$BOOT/initrd" > /tmp/irp/ir.cpio
cd /tmp/irp/x && cpio -idm < /tmp/irp/ir.cpio 2>/dev/null
[ -f init ] || { echo "FATAL: init not found"; exit 1; }

# 3. patch init (exact single replacement; anchor is the stock mount-failure handler)
python3 - <<'PYEOF'
p = "/tmp/irp/x/init"
s = open(p).read()
old = """\t\tmountpoint /mnt/;
\t\tif [ $? -ne 0 ]; then
\t\t\techo "ERROR: ${rootdev} mount fail..." > /dev/kmsg
\t\t\tprocess_bash_reboot
\t\tfi;
\tfi;
"""
new = """\t\tif ! mountpoint /mnt/ ; then
\t\t\techo "WARN: rootfs ${rootdev} not found, falling back to eMMC rootfs" > /dev/kmsg;
\t\t\tumount /mnt/ 2>/dev/null;
\t\t\trootdev="/dev/mmcblk0p1";
\t\t\tmount ${rootdev} /mnt/;
\t\tfi;
\t\tmountpoint /mnt/;
\t\tif [ $? -ne 0 ]; then
\t\t\techo "ERROR: ${rootdev} mount fail..." > /dev/kmsg
\t\t\tprocess_bash_reboot
\t\tfi;
\tfi;
"""
n = s.count(old)
assert n == 1, f"anchor found {n} times, abort"
open(p, "w").write(s.replace(old, new))
print("patch applied: 1 anchor replaced")
PYEOF

# 4. syntax check + repack
bash -n /tmp/irp/x/init && echo "init syntax OK"
cd /tmp/irp/x && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > /tmp/irp/initrd.new
gzip -t /tmp/irp/initrd.new && echo "new initrd gzip OK"

# 5. round-trip verify
mkdir -p /tmp/irp/y && cd /tmp/irp/y
zcat /tmp/irp/initrd.new | cpio -idm 2>/dev/null
grep -q "falling back to eMMC" init && echo "round-trip: patch present"
cmp -s /tmp/irp/x/init /tmp/irp/y/init && echo "round-trip: init identical"

# 6. install
cp /tmp/irp/initrd.new "$BOOT/initrd"
sync
ls -la "$BOOT"/initrd "$BOOT"/initrd.orig

# 7. extlinux: recovery entry + primary/backup use factory initrd + longer timeout
python3 - <<'PYEOF'
p = "/mnt/ubuntu_probe/boot/extlinux/extlinux.conf"
s = open(p).read()
s = s.replace("TIMEOUT 30", "TIMEOUT 100", 1)
# primary & backup -> factory initrd (independent fallback path)
s = s.replace("      INITRD /boot/initrd\n      APPEND  root=/dev/mmcblk0p1",
              "      INITRD /boot/initrd.orig\n      APPEND  root=/dev/mmcblk0p1")
assert "INITRD /boot/initrd.orig" in s, "primary/backup initrd swap failed"
# recovery entry = factory initrd + debian root (for USB-present recovery)
entry = """LABEL recovery
      MENU LABEL recovery (factory initrd, USB debian)
      LINUX /boot/Image
      FDT /boot/kernel_c4test.dtb
      INITRD /boot/initrd.orig
      APPEND  root=UUID=973bde2b-0e70-491d-91ec-c56808c06c06 rw rootwait rootfstype=ext4 mminit_loglevel=4 console=ttyTCU0,115200n8 console=tty0 fbcon=map:0 net.ifnames=0 video=efifb:off
"""
if "LABEL recovery" not in s:
    s = s.rstrip("\n") + "\n" + entry
open(p, "w").write(s)
print("extlinux.conf updated")
PYEOF
sync
echo "== FINAL extlinux.conf =="
grep -vE '^\s*#|^\s*$' "$BOOT/extlinux/extlinux.conf"
umount "$M" || umount -l "$M" || true
echo "== DONE =="
