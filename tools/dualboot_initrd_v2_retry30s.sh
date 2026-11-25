#!/bin/bash
# Dual-boot patch v2: extend stock initrd USB rootfs mount retry window 10s -> 30s
#
# WHY: the factory initrd retries rootfs mount only 50 x 0.2s = 10 seconds.
# Cold-boot USB enumeration can exceed that -> mount fails -> stock handler
# dead-silently waits on the serial console (looks bricked, no panic).
# v2 raises the window to 150 x 0.2s = 30s. Apply AFTER v1 (v1's fallback
# patch must already be present; this script verifies both).
#
# Verified on-device 2026-11-25. See docs/dualboot-incident-20261125.md
set -e
M=/mnt/ubuntu_probe
BOOT=$M/boot

if ! mountpoint -q "$M"; then
  umount -l "$M" 2>/dev/null || true
  for i in $(seq 1 40); do grep -qs "$M" /proc/mounts || break; sleep 0.5; done
  mount /dev/mmcblk0p1 "$M" || { echo "FATAL: mount failed"; exit 1; }
fi
mount -o remount,rw "$M" 2>/dev/null || true
echo "== eMMC mounted =="

rm -rf /tmp/irv2 && mkdir -p /tmp/irv2/x
zcat "$BOOT/initrd" > /tmp/irv2/ir.cpio
cd /tmp/irv2/x && cpio -idm < /tmp/irv2/ir.cpio 2>/dev/null
[ -f init ] || { echo "FATAL: no init"; exit 1; }
grep -q "falling back to eMMC" init && echo "v1 patch present" \
  || { echo "FATAL: v1 fallback patch not present, run dualboot_initrd_v1_fallback.sh first"; exit 1; }

python3 - <<'PYEOF'
p = "/tmp/irv2/x/init"
s = open(p).read()
old = """\t\tcount=0;
\t\twhile [ ${count} -lt 50 ]; do
\t\t\tsleep 0.2;
\t\t\tcount="$(expr ${count} + 1)"
"""
new = """\t\tcount=0;
\t\twhile [ ${count} -lt 150 ]; do
\t\t\tsleep 0.2;
\t\t\tcount="$(expr ${count} + 1)"
"""
n = s.count(old)
assert n == 1, f"anchor found {n} times, abort"
open(p, "w").write(s.replace(old, new))
print("retry window: 50 -> 150 (10s -> 30s)")
PYEOF

bash -n /tmp/irv2/x/init && echo "syntax OK"
cd /tmp/irv2/x && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > /tmp/irv2/initrd.new
gzip -t /tmp/irv2/initrd.new && echo "gzip OK"
mkdir -p /tmp/irv2/y && cd /tmp/irv2/y
zcat /tmp/irv2/initrd.new | cpio -idm 2>/dev/null
cmp -s /tmp/irv2/x/init /tmp/irv2/y/init && echo "round-trip OK"
grep -q "lt 150" init && grep -q "falling back to eMMC" init && echo "both patches verified"

cp /tmp/irv2/initrd.new "$BOOT/initrd"
sync
ls -la "$BOOT/initrd"
umount "$M" || umount -l "$M" || true
echo "== DONE v2 =="
