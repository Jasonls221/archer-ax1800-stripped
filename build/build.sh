#!/bin/bash
# build.sh - strip the cloud/telemetry/backdoor stuff out of a stock
# Archer AX1800 v1.20 firmware and produce a flashable, SSH-capable image.
#
# Usage:
#   ./build.sh <stock-firmware.bin> <path-to-ax1800v1.20_GPL> [output.bin]
#
# Needs to run as root (ubi_reader permission preservation requires it).
# Needs the i386 runtime libs if you're on an x86_64 build box, since the
# GPL tree's host tools are 32-bit:
#   dpkg --add-architecture i386 && apt-get update
#   apt-get install libc6:i386 libstdc++6:i386 zlib1g:i386 liblzo2-2:i386 libuuid1:i386
#
# Needs ubi_reader:
#   pip install ubi_reader --break-system-packages

set -euo pipefail

STOCK_BIN="${1:?usage: build.sh <stock.bin> <GPL tree path> [out.bin]}"
GPL_DIR="${2:?usage: build.sh <stock.bin> <GPL tree path> [out.bin]}"
OUT_BIN="${3:-custom_fsonly.bin}"

HOSTTOOLS="$GPL_DIR/bcm675x/bcm963xx_router/hostTools"
MKFS_UBIFS="$HOSTTOOLS/mtd-utils-2.0.1/mkfs.ubifs"
UBINIZE="$HOSTTOOLS/mtd-utils-2.0.1/ubinize"
BCMFSTAG="$HOSTTOOLS/BcmFsTag"
ADDVTOKEN="$HOSTTOOLS/addvtoken"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_DIR="$(pwd)"
WORK="$(mktemp -d)"
trap 'echo "(leaving work dir for inspection: $WORK)"' EXIT

if [ "$EUID" -ne 0 ]; then
	echo "needs to run as root (ubi_reader -k permission preservation)" >&2
	exit 1
fi
for t in "$MKFS_UBIFS" "$UBINIZE" "$BCMFSTAG" "$ADDVTOKEN"; do
	[ -x "$t" ] || { echo "missing/not executable: $t" >&2; echo "(32-bit host tool - did you install the i386 libs? see top of this script)" >&2; exit 1; }
done
command -v ubireader_extract_files >/dev/null || { echo "ubireader_extract_files not found - pip install ubi_reader" >&2; exit 1; }

echo "== carving boot region + UBI rootfs out of the stock image =="
# These offsets are specific to the 1.3.6/rel.23076 header layout. See
# docs/DEVICE-NOTES.md for the full byte-offset table. If you're on a
# different firmware build, verify these before trusting the output -
# check that BOOT_REGION ends right where "UBI#" starts.
HEADER_SIZE=4560        # 0x11D0 - end of the TP-Link outer header
BOOT_REGION_SIZE=4194304 # exactly 4MB, bootfs + marker, PEB-aligned

dd if="$STOCK_BIN" of="$WORK/boot_region.bin" bs=1 skip=$HEADER_SIZE count=$BOOT_REGION_SIZE status=none
UBI_OFFSET=$((HEADER_SIZE + BOOT_REGION_SIZE))
UBI_MAGIC=$(dd if="$STOCK_BIN" bs=1 skip=$UBI_OFFSET count=4 status=none | od -An -tx1 | tr -d ' \n')
if [ "$UBI_MAGIC" != "55424923" ]; then
	echo "UBI magic not found where expected (got 0x$UBI_MAGIC) - header layout" >&2
	echo "doesn't match what this script assumes. Check docs/DEVICE-NOTES.md" >&2
	echo "and re-derive HEADER_SIZE/BOOT_REGION_SIZE for your firmware build." >&2
	exit 1
fi
dd if="$STOCK_BIN" of="$WORK/ubi_rootfs.img" bs=1 skip=$UBI_OFFSET status=none

echo "== extracting rootfs (this needs root for correct permissions) =="
ubireader_extract_files -k -o "$WORK/extracted" "$WORK/ubi_rootfs.img" >/dev/null
ROOTFS=$(find "$WORK/extracted" -maxdepth 3 -type d -name rootfs_ubifs)
[ -d "$ROOTFS" ] || { echo "couldn't find extracted rootfs_ubifs dir" >&2; exit 1; }

echo "== applying strip list =="
while read -r f; do
	[ -z "$f" ] && continue
	case "$f" in \#*) continue ;; esac
	if [ -e "$ROOTFS/$f" ] || [ -L "$ROOTFS/$f" ]; then
		rm -rf -- "$ROOTFS/$f"
	fi
done < "$HERE/strip-list.txt"

echo "== cleaning up dangling rc.d symlinks =="
for l in "$ROOTFS"/etc/rc.d/*; do
	[ -L "$l" ] && [ ! -e "$l" ] && rm -f "$l"
done

echo "== known dangling-reference fixups =="
# monit's proc watchlist mentions some things we just deleted - strip those
# entries out so monit doesn't spend its life trying to respawn ghosts.
for f in "$ROOTFS/etc/monit/monit_proclist" "$ROOTFS/lib/monit/monit_proclist"; do
	[ -f "$f" ] || continue
	sed -i -E 's/\b(tmpServer|cloud_brd|cloud_https)\b//g' "$f"
	sed -i '/^local \(tmpServer\|cloud_brd\|cloud_https\)=/d' "$f"
done
# lib/ffs/ffs_network.sh sources domain_login_core.sh (which we just
# deleted as part of the domain_login backdoor) purely to get at one
# generic subnet-math lua helper it never directly calls any function
# from. Point it at the helper directly instead of the whole sourced file.
FFS="$ROOTFS/lib/ffs/ffs_network.sh"
if [ -f "$FFS" ] && grep -q '^\. /lib/domain_login/domain_login_core\.sh$' "$FFS"; then
	mkdir -p "$ROOTFS/lib/domain_login"
	# domain_login_core.sh itself is gone (it's the actual backdoor logic),
	# but the generic lua helper it shipped alongside isn't - pull it back
	# out of the pre-strip extraction if you still have it, or comment this
	# out and accept that ffs_network.sh loses IP-conflict checking.
	sed -i 's#^\. /lib/domain_login/domain_login_core\.sh$#DLOGIN_LIB_PATH=/lib/domain_login#' "$FFS"
fi
# sysupgrade's ramfs-copy list references a binary we just deleted.
PLATFORM_SH="$ROOTFS/lib/upgrade/platform.sh"
[ -f "$PLATFORM_SH" ] && sed -i 's# /usr/sbin/cloud_cleanFwInfo##' "$PLATFORM_SH"

echo "== installing dropbear fix + config =="
cp "$HERE/files/etc/init.d/dropbear" "$ROOTFS/etc/init.d/dropbear"
cp "$HERE/files/etc/config/dropbear" "$ROOTFS/etc/config/dropbear"
chmod 755 "$ROOTFS/etc/init.d/dropbear"
chown root:root "$ROOTFS/etc/init.d/dropbear" "$ROOTFS/etc/config/dropbear"
chmod 700 "$ROOTFS/etc/dropbear" 2>/dev/null || true

echo "== setting root password =="
if [ -n "${ROOT_PASSWORD:-}" ]; then
	PW="$ROOT_PASSWORD"
else
	read -rsp "root password for the device: " PW; echo
	read -rsp "confirm: " PW2; echo
	[ "$PW" = "$PW2" ] || { echo "didn't match" >&2; exit 1; }
fi
HASH=$(python3 -c "import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))" "$PW")
# Goes in BOTH passwd and shadow - see SSH-DEBUGGING.md bug #3 for why the
# passwd copy is the one that actually matters on this device.
sed -i "s#^root:[^:]*:#root:${HASH}:#" "$ROOTFS/etc/shadow"
sed -i "s#^root:[^:]*:#root:${HASH}:#" "$ROOTFS/etc/passwd"
chmod 600 "$ROOTFS/etc/shadow"
chmod 644 "$ROOTFS/etc/passwd"

echo "== hostname + banner =="
HOSTNAME="${DEVICE_HOSTNAME:-Archer_AX1800-CUSTOM}"
sed -i "s#option hostname.*#option hostname\t${HOSTNAME}#" "$ROOTFS/etc/config/system" 2>/dev/null || true
cat > "$ROOTFS/etc/banner" <<BANNER

  *** CUSTOM FIRMWARE - stripped, TP-Link cloud/debug backdoors removed ***

BANNER
chmod 644 "$ROOTFS/etc/banner"

echo "== rebuilding UBIFS/UBI image =="
cd "$WORK"
"$MKFS_UBIFS" -m 2048 -e 126976 -c 2048 -x zlib -f 8 -k r5 -p 1 -l 5 -r "$ROOTFS" img_0.ubifs
cat > img.ini <<INI
[rootfs_ubifs]
mode = ubi
image = img_0.ubifs
vol_type = dynamic
vol_flags = autoresize
vol_id = 0
vol_name = rootfs_ubifs
vol_alignment = 1
vol_size = 38600704
INI
"$UBINIZE" -p 131072 -m 2048 -O 2048 -s 2048 -x 1 -Q 1025704112 -o img.ubi img.ini

echo "== wrapping with BcmFsTag/addvtoken =="
cat boot_region.bin img.ubi > merged.tmp
"$ADDVTOKEN" --endian little --chip 47622 --flashtype NAND128 --btrm 1 merged.tmp "$OUT_BIN"

cp "$WORK/$OUT_BIN" "$ORIG_DIR/$OUT_BIN"
echo
echo "done: $ORIG_DIR/$OUT_BIN"
echo "flash via the router's recovery-mode page (hold reset, browse to 192.168.0.1)."
echo "you may need a factory reset after the first flash - see the README."
