#!/bin/sh
# Matrix EX5601-T0 Project C stock-layout -> ubootmod initramfs launcher
# Keep this runtime path/name as /tmp/matrix_boot_initramfs.sh for LuCI.
# Minimal raw-FIT launcher: validates /tmp/initramfs.bin, then sysupgrade -F -n.

set -u

LOG="${LOG:-/tmp/matrix_project_c_boot_initramfs.log}"
LOCK="${LOCK:-/tmp/matrix-project-c-rawfit-stage.lock}"
RAW_FIT="${RAW_FIT:-/tmp/initramfs.bin}"

exec > "$LOG" 2>&1

say() { echo "$*"; }
fail() {
	echo
	echo "ERROR: $*"
	echo "Log: $LOG"
	exit 1
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

magic4() {
	dd if="$1" bs=4 count=1 2>/dev/null | hexdump -v -e '4/1 "%02x"'
}

mtd_index_by_name_ci() {
	want="$(echo "$1" | tr 'A-Z' 'a-z')"
	awk -v want="$want" '
		/^mtd[0-9]+:/ {
			name=$4
			gsub(/"/, "", name)
			if (tolower(name) == want) {
				gsub(/^mtd/, "", $1)
				gsub(/:$/, "", $1)
				print $1
				exit
			}
		}
	' /proc/mtd
}

mtd_size_hex_by_index() {
	awk -v m="mtd${1}:" '$1 == m { print $2; exit }' /proc/mtd
}

mtd_name_by_index() {
	awk -v m="mtd${1}:" '$1 == m { gsub(/"/, "", $4); print $4; exit }' /proc/mtd
}

mtd_size_dec_by_index() {
	cat "/sys/class/mtd/mtd${1}/size" 2>/dev/null
}

cleanup() {
	rm -rf "$LOCK"
}
trap cleanup EXIT

mkdir "$LOCK" 2>/dev/null || fail "another Project C staging process is running"

say "================================================"
say " Matrix Project C raw FIT initramfs launcher"
say "================================================"
say "This launcher only stages the ubootmod initramfs FIT."
say "It does not format NAND or write bootloaders."
say "================================================"

say "Checking commands"
for c in awk cat dd grep hexdump ls rm sleep strings sync sysupgrade; do
	need_cmd "$c"
done

say "Checking current board/layout"
[ -r /proc/mtd ] || fail "/proc/mtd missing"
[ -r /proc/cmdline ] || fail "/proc/cmdline missing"

BOARD_NAME=""
[ -f /tmp/sysinfo/board_name ] && BOARD_NAME="$(cat /tmp/sysinfo/board_name 2>/dev/null || true)"
say "board_name=$BOARD_NAME"

case "$(echo "$BOARD_NAME" | tr 'A-Z' 'a-z')" in
	*ex5601*t0*stock*|zyxel,ex5601-t0-stock) ;;
	*) fail "this launcher must run from OpenWrt stock layout; unexpected board_name=$BOARD_NAME" ;;
esac

say "/proc/mtd:"
cat /proc/mtd
say

# Only sanity-check that this is not already ubootmod layout.
# Stock labels may be ubi/ubi2 or ubi_oem/ubi depending on image/runtime.
UBI_IDX="$(mtd_index_by_name_ci ubi || true)"
if [ -n "$UBI_IDX" ]; then
	UBI_SIZE="$(mtd_size_dec_by_index "$UBI_IDX")"
	UBI_HEX="$(mtd_size_hex_by_index "$UBI_IDX")"
	UBI_NAME="$(mtd_name_by_index "$UBI_IDX")"
	say "detected MTD named ubi: mtd$UBI_IDX name=$UBI_NAME size_hex=$UBI_HEX size_dec=$UBI_SIZE"
	[ -n "$UBI_SIZE" ] || fail "cannot read mtd$UBI_IDX size"
	[ "$UBI_SIZE" -lt 134217728 ] || fail "mtd$UBI_IDX/ubi is large; this already looks like ubootmod layout"
else
	say "WARNING: no MTD named ubi found; continuing because raw FIT staging does not write raw MTD"
fi

CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"
say "cmdline=$CMDLINE"
case "$CMDLINE" in
	*rootubi=ubi2*) say "active stock bank hint: ubi2" ;;
	*rootubi=ubi*)  say "active stock bank hint: ubi" ;;
	*) say "WARNING: no rootubi hint found; continuing because sysupgrade owns the write path" ;;
esac

say
say "Validating raw ubootmod initramfs FIT"
[ -s "$RAW_FIT" ] || fail "missing raw FIT: $RAW_FIT"
ls -lh "$RAW_FIT" || true
MAGIC="$(magic4 "$RAW_FIT")"
say "magic=$MAGIC"
[ "$MAGIC" = "d00dfeed" ] || fail "$RAW_FIT is not a FIT/ITB image"

# Positive markers: must be ubootmod and initramfs/ramdisk.
strings "$RAW_FIT" | grep -q 'zyxel_ex5601-t0-ubootmod' || \
	fail "$RAW_FIT does not contain zyxel_ex5601-t0-ubootmod"

if strings "$RAW_FIT" | grep -qiE 'initramfs|initrd|ramdisk|RAMDisk'; then
	say "initramfs/RAMDisk marker: OK"
else
	fail "$RAW_FIT does not look like an initramfs/RAMDisk FIT"
fi

# Negative markers: never flash a stock production image in this Project C first hop.
if strings "$RAW_FIT" | grep -qE 'zyxel_ex5601-t0-stock|zyxel,ex5601-t0-stock'; then
	fail "$RAW_FIT contains stock-layout board markers; refusing to flash wrong image"
fi

say "raw FIT validation: PASS"

say
say "Testing sysupgrade metadata"
if sysupgrade -T "$RAW_FIT"; then
	say "sysupgrade -T unexpectedly passed; using normal sysupgrade"
	FORCE=0
else
	RC="$?"
	say "sysupgrade -T rejected raw FIT as expected rc=$RC"
	say "Using developer raw-FIT path: sysupgrade -F -n"
	FORCE=1
fi

say
say "Starting first-hop staging now"
say "Expected result: reboot into ubootmod initramfs."
sync
sleep 2

if [ "$FORCE" = "1" ]; then
	sysupgrade -F -n "$RAW_FIT"
else
	sysupgrade -n "$RAW_FIT"
fi
RC="$?"
say "sysupgrade returned rc=$RC"

# OpenWrt sysupgrade may return non-zero/246 after handoff but still continue.
# Do not declare immediate failure; wait briefly for log/handoff.
i=0
while [ "$i" -lt 60 ]; do
	if grep -q 'sysupgrade successful' "$LOG" 2>/dev/null; then
		say "sysupgrade reported success; reboot should happen now"
		sync
		sleep 2
		reboot -f
		exit 0
	fi
	sleep 1
	i=$((i + 1))
done

say "No sysupgrade success marker seen after handoff."
say "If the router did not reboot, this first-hop failed."
exit 1
