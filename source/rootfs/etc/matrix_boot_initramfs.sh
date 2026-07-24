#!/bin/sh
# Matrix EX5601-T0 Project C OpenWrt-stock -> ubootmod initramfs stager
# Fixed v5
#
# Normal staging:
#   /tmp/matrix_boot_initramfs.sh
#
# Stage without reboot:
#   NO_REBOOT=1 /tmp/matrix_boot_initramfs.sh
#
# Read-only diagnosis:
#   /tmp/matrix_boot_initramfs.sh --diagnose
#
# Optional custom initramfs path:
#   INITRAMFS=/tmp/initramfs.bin /tmp/matrix_boot_initramfs.sh
#   RAW_FIT=/tmp/initramfs.bin /tmp/matrix_boot_initramfs.sh

set -u

ACTION="${1:-stage}"

case "$ACTION" in
	stage|--stage|"")
		ACTION="stage"
		;;
	diagnose|--diagnose|check|--check)
		ACTION="diagnose"
		;;
	*)
		echo "Usage: $0 [stage|--stage|diagnose|--diagnose]" >&2
		exit 1
		;;
esac

INITRAMFS="${INITRAMFS:-${RAW_FIT:-/tmp/initramfs.bin}}"

if [ "$ACTION" = "diagnose" ]; then
	LOG="${LOG:-/tmp/matrix_project_c_boot_initramfs_diagnose.log}"
else
	LOG="${LOG:-/tmp/matrix_project_c_boot_initramfs.log}"
fi

WORK="/tmp/matrix-initramfs-stage"
LOCK="${LOCK:-/tmp/matrix-project-c-inactive-bank-stage.lock}"
NO_REBOOT="${NO_REBOOT:-0}"


ZYFWINFO_MODE="${ZYFWINFO_MODE:-rich}"



ZLOADER_FIX="${ZLOADER_FIX:-0}"
OLD_ZLOADER_PATH="${OLD_ZLOADER_PATH:-/tmp/zl34.bin}"
OLD_ZLOADER_MATCH="${OLD_ZLOADER_MATCH:-zld-2.4}"
ZLOADER_ACTION="unknown"
ZLOADER_CURRENT_STRING=""
ZLOADER_CURRENT_HASH=""
ZLOADER_TARGET_HASH=""


FIP_FIX="${FIP_FIX:-0}"
FIP_PATH="${FIP_PATH:-/tmp/fip.bin}"
FIP_ACTION="unknown"
FIP_CURRENT_STRING=""
FIP_CURRENT_HASH=""
FIP_TARGET_STRING=""
FIP_TARGET_HASH=""

# Unattended state tracking.
STAGE="startup"
TARGET_FORMATTED=0
BOOT_SWITCH_COMMITTED=0
FAIL_IN_PROGRESS=0
TIMEOUT_GUARD_PID=""


STAGE_TIMEOUT="${STAGE_TIMEOUT:-600}"
FAIL_REBOOT_DELAY="${FAIL_REBOOT_DELAY:-8}"

exec > "$LOG" 2>&1

# Mirror important state messages to UART as well as the log.
if [ -w /dev/console ]; then
	exec 3>/dev/console
else
	exec 3>/dev/null
fi

say() {
	echo "$*"
	echo "$*" >&3 2>/dev/null || true
}

force_reboot_now() {
	sync 2>/dev/null || true
	sleep 1

	if command -v reboot >/dev/null 2>&1; then
		reboot -f 2>/dev/null || true
	fi

	if [ -x /sbin/reboot ]; then
		/sbin/reboot -f 2>/dev/null || true
	fi

	# Last-resort immediate reboot when enabled by the kernel.
	if [ -w /proc/sysrq-trigger ]; then
		echo b > /proc/sysrq-trigger 2>/dev/null || true
	fi

	sleep 10
	exit 1
}

invalidate_uncommitted_target_switch() {
	# If the final zyfwinfo update started but was not verified, make a best-
	# effort attempt to leave the target metadata volume empty. This keeps the
	# untouched active bank as the preferred boot bank.
	if [ "$BOOT_SWITCH_COMMITTED" = "0" ] && \
	   [ "${STAGE:-}" = "committing_boot_switch" ] && \
	   [ -n "${TARGET_ZYFW:-}" ] && \
	   [ -e "${TARGET_ZYFW:-}" ]; then
		say "Invalidating unverified target zyfwinfo before reboot"
		ubiupdatevol "$TARGET_ZYFW" -t >/dev/null 2>&1 || true
		sync 2>/dev/null || true
	fi
}

fail() {
	msg="$*"

	if [ "$FAIL_IN_PROGRESS" = "1" ]; then
		echo "SECONDARY ERROR DURING FAILURE HANDLING: $msg" >&3 2>/dev/null || true
		force_reboot_now
	fi
	FAIL_IN_PROGRESS=1

	say ""
	say "================================================"
	say "UNATTENDED STAGER FAILURE"
	say "================================================"
	say "ERROR: $msg"
	say "STAGE=${STAGE:-unknown}"
	say "TARGET_FORMATTED=${TARGET_FORMATTED:-0}"
	say "BOOT_SWITCH_COMMITTED=${BOOT_SWITCH_COMMITTED:-0}"
	say "ACTIVE_MTD=${ACTIVE_MTD:-unknown}"
	say "TARGET_MTD=${TARGET_MTD:-unknown}"
	say "TARGET_NAME=${TARGET_NAME:-unknown}"
	say "LOG=$LOG"

	if [ "$ACTION" = "diagnose" ]; then
		say "Diagnosis mode: exiting without reboot."
		exit 1
	fi

	invalidate_uncommitted_target_switch

	say ""
	say "Failure-state /proc/mtd:"
	cat /proc/mtd 2>/dev/null >&3 || true

	say ""
	say "Failure-state UBI mapping:"
	for u in /sys/class/ubi/ubi[0-9]*; do
		[ -f "$u/mtd_num" ] || continue
		echo "$(basename "$u") -> mtd$(cat "$u/mtd_num" 2>/dev/null)" >&3 2>/dev/null || true
	done

	if [ "$BOOT_SWITCH_COMMITTED" = "1" ]; then
		say "The staged target was fully verified; reboot should enter the initramfs."
	else
		say "The boot switch was not committed; reboot should return to the untouched active bank."
	say "Mount-aware protection prevented formatting any bank detected as live."
	fi

	say "Rebooting automatically after failure."
	sync 2>/dev/null || true
	sleep "$FAIL_REBOOT_DELAY"
	force_reboot_now
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

file_sha256() {
	sha256sum "$1" | awk '{print $1}'
}

mtd_num_by_name() {
	local name="$1"

	awk -v want="$name" '
		BEGIN {
			want = tolower(want)
		}

		/^mtd[0-9]+:/ {
			name = $4
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

find_ubi_by_mtdnum() {
	local want="$1"
	local u n

	for u in /sys/class/ubi/ubi[0-9]*; do
		[ -f "$u/mtd_num" ] || continue
		n="$(cat "$u/mtd_num" 2>/dev/null || true)"

		if [ "$n" = "$want" ]; then
			echo "/dev/$(basename "$u")"
			return 0
		fi
	done

	return 1
}


mtd_name_by_num() {
	local mtdnum="$1"

	awk -v dev="mtd${mtdnum}:" '
		$1 == dev {
			name = $4
			gsub(/"/, "", name)
			print name
			exit
		}
	' /proc/mtd
}

ubi_num_from_mount_source() {
	local src="$1"
	local tmp

	case "$src" in
		/dev/ubi[0-9]*_[0-9]*)
			tmp="${src#/dev/ubi}"
			echo "${tmp%%_*}"
			return 0
			;;
		/dev/ubiblock[0-9]*_[0-9]*)
			tmp="${src#/dev/ubiblock}"
			echo "${tmp%%_*}"
			return 0
			;;
		ubi[0-9]*:*)
			tmp="${src#ubi}"
			echo "${tmp%%:*}"
			return 0
			;;
	esac

	return 1
}

mtd_from_mount_source() {
	local src="$1"
	local ubinum

	ubinum="$(ubi_num_from_mount_source "$src" 2>/dev/null || true)"
	[ -n "$ubinum" ] || return 1
	[ -r "/sys/class/ubi/ubi$ubinum/mtd_num" ] || return 1

	cat "/sys/class/ubi/ubi$ubinum/mtd_num"
}

detect_mounted_active_bank() {
	local allowed_a="$1"
	local allowed_b="$2"
	local src mnt rest mtd
	local detected=""
	local evidence=""

	MOUNT_ACTIVE_MTD=""
	MOUNT_ACTIVE_EVIDENCE=""

	[ -r /proc/mounts ] || return 0

	while read -r src mnt rest; do
		case "$mnt" in
			/|/rom|/overlay)
				;;
			*)
				continue
				;;
		esac

		mtd="$(mtd_from_mount_source "$src" 2>/dev/null || true)"
		[ -n "$mtd" ] || continue

		case "$mtd" in
			"$allowed_a"|"$allowed_b")
				evidence="${evidence}${mnt}=${src}->mtd${mtd}; "
				if [ -z "$detected" ]; then
					detected="$mtd"
				elif [ "$detected" != "$mtd" ]; then
					fail "live root mounts resolve to different firmware banks: mtd$detected and mtd$mtd"
				fi
				;;
		esac
	done < /proc/mounts

	MOUNT_ACTIVE_MTD="$detected"
	MOUNT_ACTIVE_EVIDENCE="$evidence"
}

rootubi_hint_to_mtd() {
	local hint="$1"
	local mtd_ubi="$2"
	local mtd_ubi2="$3"

	case "$hint" in
		ubi)
			echo "$mtd_ubi"
			;;
		ubi2)
			echo "$mtd_ubi2"
			;;
		*)
			return 1
			;;
	esac
}

assert_mtd_not_live_mounted() {
	local target_mtd="$1"
	local src mnt rest mapped
	local busy=0

	[ -r /proc/mounts ] || fail "/proc/mounts missing during target safety check"

	while read -r src mnt rest; do
		mapped="$(mtd_from_mount_source "$src" 2>/dev/null || true)"
		[ "$mapped" = "$target_mtd" ] || continue

		say "TARGET_MOUNT_CONFLICT: $src mounted on $mnt maps to mtd$target_mtd"
		busy=1
	done < /proc/mounts

	[ "$busy" = "0" ] || \
		fail "refusing to touch mtd$target_mtd because it backs a live mount"

	say "Target mtd$target_mtd has no live UBI/ubiblock mounts"
}

ubi_vol_dev_by_name() {
	local ubidev="$1"
	local want="$2"
	local base="${ubidev##*/}"
	local p name

	for p in /sys/class/ubi/"$base"_*; do
		[ -f "$p/name" ] || continue
		name="$(cat "$p/name" 2>/dev/null || true)"

		if [ "$name" = "$want" ]; then
			echo "/dev/$(basename "$p")"
			return 0
		fi
	done

	return 1
}

attach_mtd() {
	local mtdnum="$1"
	local ubidev

	ubidev="$(find_ubi_by_mtdnum "$mtdnum" || true)"

	if [ -n "$ubidev" ]; then
		echo "$ubidev"
		return 0
	fi

	ubiattach -p "/dev/mtd$mtdnum" >/dev/null 2>&1 || \
		ubiattach /dev/ubi_ctrl -m "$mtdnum" >/dev/null 2>&1 || \
		fail "could not attach /dev/mtd$mtdnum"

	sleep 1

	ubidev="$(find_ubi_by_mtdnum "$mtdnum" || true)"
	[ -n "$ubidev" ] || fail "attached mtd$mtdnum but could not find UBI device"

	echo "$ubidev"
}

mtd_is_writable() {
	local mtdnum="$1"
	local flags dec

	flags="$(cat "/sys/class/mtd/mtd$mtdnum/flags" 2>/dev/null || echo 0)"
	case "$flags" in
		0x[0-9a-fA-F]*|[0-9]*)
			dec="$(printf '%d' "$flags" 2>/dev/null || echo 0)"
			;;
		*)
			dec=0
			;;
	esac

	[ $((dec & 1024)) -ne 0 ]
}

load_mtd_rw_for_staging() {
	local target_mtd="$1"
	local ko=""

	if mtd_is_writable "$target_mtd"; then
		say "mtd$target_mtd is already writable"
		return 0
	fi

	say "mtd$target_mtd is read-only; loading mtd-rw"

	if grep -q '^mtd_rw ' /proc/modules 2>/dev/null; then
		say "mtd-rw is already loaded"
	else
		for candidate in \
			/tmp/mtd-rw.ko \
			"/lib/modules/$(uname -r)/mtd-rw.ko"
		do
			if [ -f "$candidate" ]; then
				ko="$candidate"
				break
			fi
		done

		if [ -z "$ko" ]; then
			ko="$(find "/lib/modules/$(uname -r)" -name 'mtd-rw.ko' 2>/dev/null | head -n1 || true)"
		fi

		[ -n "$ko" ] || fail "mtd$target_mtd is read-only and mtd-rw.ko was not found"

		say "Loading $ko with i_want_a_brick=1"
		insmod "$ko" i_want_a_brick=1 || fail "failed to load mtd-rw from $ko"
		sleep 1
	fi

	flags="$(cat "/sys/class/mtd/mtd$target_mtd/flags" 2>/dev/null || echo unknown)"
	say "mtd$target_mtd flags after mtd-rw: $flags"

	mtd_is_writable "$target_mtd" || \
		fail "mtd$target_mtd is still read-only after loading mtd-rw"
}

assert_target_ubi_not_mounted() {
	local ubidev="$1"
	local base="${ubidev##*/}"
	local ubinum="${base#ubi}"
	local src mnt rest
	local busy=0

	[ -r /proc/mounts ] || fail "/proc/mounts missing during UBI detach safety check"

	while read -r src mnt rest; do
		case "$src" in
			/dev/"${base}"_*|/dev/ubiblock"${ubinum}"_*|"${base}":*)
				say "TARGET_UBI_MOUNT_CONFLICT: $src mounted on $mnt"
				busy=1
				;;
		esac
	done < /proc/mounts

	[ "$busy" = "0" ] || \
		fail "refusing to detach $ubidev because it has live mounts"

	say "$ubidev has no live mounts"
}

remove_target_ubiblocks() {
	local ubidev="$1"
	local base="${ubidev##*/}"
	local ubinum="${base#ubi}"
	local v vol blockdev found

	found=0

	for v in /sys/class/ubi/"${base}"_[0-9]*; do
		[ -d "$v" ] || continue
		vol="${v##*/}"
		blockdev="/dev/ubiblock${vol#ubi}"

		if [ -e "$blockdev" ] || ls "$v"/ubiblock* >/dev/null 2>&1; then
			found=1
			say "Removing target-bank ubiblock for /dev/$vol ($blockdev)"

			command -v ubiblock >/dev/null 2>&1 || \
				fail "$blockdev exists but ubiblock command is unavailable"

			if ubiblock -r "/dev/$vol" 2>&1; then
				say "Removed ubiblock using: ubiblock -r /dev/$vol"
			elif ubiblock --remove "/dev/$vol" 2>&1; then
				say "Removed ubiblock using: ubiblock --remove /dev/$vol"
			else
				say "ubiblock removal failed for /dev/$vol"
				say "The volume may still be held open by the running root filesystem."
				fail "could not remove ubiblock for /dev/$vol"
			fi

			sleep 1

			if [ -e "$blockdev" ] || ls "$v"/ubiblock* >/dev/null 2>&1; then
				fail "ubiblock for /dev/$vol still exists after removal"
			fi
		fi
	done

	if [ "$found" = "0" ]; then
		say "No target-bank ubiblock devices found for $base"
	fi
}

detach_mtd_if_attached() {
	local mtdnum="$1"
	local ubidev base ubinum attempt

	ubidev="$(find_ubi_by_mtdnum "$mtdnum" || true)"
	if [ -z "$ubidev" ]; then
		say "mtd$mtdnum is not attached to UBI"
		return 0
	fi

	base="${ubidev##*/}"
	ubinum="${base#ubi}"

	say "Preparing to detach $ubidev from mtd$mtdnum"
	assert_target_ubi_not_mounted "$ubidev"
	remove_target_ubiblocks "$ubidev"
	sync
	sleep 1

	attempt=1
	while [ "$attempt" -le 3 ]; do
		say "UBI detach attempt $attempt for $ubidev / mtd$mtdnum"

		ubidetach -p "/dev/mtd$mtdnum" 2>&1 || true

		if [ -z "$(find_ubi_by_mtdnum "$mtdnum" || true)" ]; then
			say "Detached mtd$mtdnum successfully using -p"
			return 0
		fi

		ubidetach /dev/ubi_ctrl -m "$mtdnum" 2>&1 || true

		if [ -z "$(find_ubi_by_mtdnum "$mtdnum" || true)" ]; then
			say "Detached mtd$mtdnum successfully using ubi_ctrl -m"
			return 0
		fi

		ubidetach /dev/ubi_ctrl -d "$ubinum" 2>&1 || true

		if [ -z "$(find_ubi_by_mtdnum "$mtdnum" || true)" ]; then
			say "Detached mtd$mtdnum successfully using ubi_ctrl -d"
			return 0
		fi

		sleep 1
		attempt=$((attempt + 1))
	done

	say ""
	say "===== detach failure diagnostics ====="
	say "Target MTD: mtd$mtdnum"
	say "Target UBI: $ubidev"
	cat /proc/mounts 2>/dev/null || true
	ls -l /dev/ubi* /dev/ubiblock* 2>/dev/null || true
	ubinfo -a 2>&1 || true

	fail "could not detach /dev/mtd$mtdnum after removing mounts and ubiblock devices"
}

get_leb_size() {
	local ubidev="$1"
	local base="${ubidev##*/}"
	local leb=""

	if [ -f "/sys/class/ubi/$base/usable_eb_size" ]; then
		leb="$(cat "/sys/class/ubi/$base/usable_eb_size" 2>/dev/null || true)"
		if [ -n "$leb" ]; then
			echo "$leb"
			return 0
		fi
	fi

	ubinfo "$ubidev" | awk -F: '/Logical eraseblock size/ {
		gsub(/ bytes.*/, "", $2);
		gsub(/ /, "", $2);
		print $2;
		exit;
	}'
}

round_up_leb_size() {
	local size="$1"
	local leb="$2"

	echo $(( ((size + leb - 1) / leb) * leb ))
}

read_byte_dec() {
	dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | hexdump -v -e '1/1 "%u"'
}

write_byte() {
	local file="$1"
	local off="$2"
	local val="$3"
	local oct

	[ "$val" -ge 0 ] && [ "$val" -le 255 ] || fail "byte out of range: $val"

	oct="$(printf '%03o' "$val")"
	printf "\\$oct" | dd of="$file" bs=1 seek="$off" conv=notrunc 2>/dev/null
}

write_le32_dec() {
	local file="$1"
	local offset="$2"
	local value="$3"
	local b0 b1 b2 b3

	[ "$value" -ge 0 ] || fail "le32 value out of range: $value"

	b0=$((value & 255))
	b1=$(((value >> 8) & 255))
	b2=$(((value >> 16) & 255))
	b3=$(((value >> 24) & 255))

	write_byte "$file" "$offset" "$b0"
	write_byte "$file" $((offset + 1)) "$b1"
	write_byte "$file" $((offset + 2)) "$b2"
	write_byte "$file" $((offset + 3)) "$b3"
}

read_le32_dec() {
	local file="$1"
	local offset="$2"
	local bytes b0 b1 b2 b3

	bytes="$(dd if="$file" bs=1 skip="$offset" count=4 2>/dev/null | hexdump -v -e '1/1 "%u\n"')"
	b0="$(echo "$bytes" | sed -n '1p')"
	b1="$(echo "$bytes" | sed -n '2p')"
	b2="$(echo "$bytes" | sed -n '3p')"
	b3="$(echo "$bytes" | sed -n '4p')"

	[ -n "$b0" ] && [ -n "$b1" ] && [ -n "$b2" ] && [ -n "$b3" ] || \
		fail "could not read le32 at offset $offset from $file"

	echo $((b0 + b1 * 256 + b2 * 65536 + b3 * 16777216))
}

round_up_4k_size() {
	local size="$1"
	echo $(( ((size + 4095) / 4096) * 4096 ))
}

calc_rootfs_load_size_for_zyfwinfo() {
	local rootfs="$1"
	local magic bytes_used load_size data_bytes sysname

	magic="$(dd if="$rootfs" bs=4 count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"')"

	case "$magic" in
		68737173)
			# Squashfs magic "hsqs". ACEA zloader uses bytes_used rounded to 4 KiB.
			bytes_used="$(read_le32_dec "$rootfs" 40)"
			load_size="$(round_up_4k_size "$bytes_used")"
			printf "Target rootfs squashfs bytes_used=0x%08x load_size=0x%08x\n" "$bytes_used" "$load_size" >&2
			echo "$load_size"
			;;
		00000000)

			#  the old zloader workaround this field is not used .
			printf "Target rootfs placeholder detected; rich zyfwinfo rootfs load size set to 0x00000000\n" >&2
			echo 0
			;;
		*)
			# Fallback for unusual images: use UBI data_bytes if available, rounded to 4 KiB.
			sysname="${rootfs#/dev/}"
			data_bytes=""
			[ -f "/sys/class/ubi/$sysname/data_bytes" ] && data_bytes="$(cat "/sys/class/ubi/$sysname/data_bytes" 2>/dev/null || true)"
			[ -n "$data_bytes" ] || fail "target rootfs is not squashfs/empty and data_bytes is unavailable; magic=$magic"
			load_size="$(round_up_4k_size "$data_bytes")"
			printf "WARNING: target rootfs magic=%s; using UBI data_bytes load_size=0x%08x\n" "$magic" "$load_size" >&2
			echo "$load_size"
			;;
	esac
}

calc_zyfwinfo_checksum() {
	local file="$1"

	dd if="$file" bs=1 count=254 2>/dev/null | \
		hexdump -v -e '1/1 "%u\n"' | \
		awk '{s += $1} END {print s % 65536}'
}

read_zyfwinfo_stored_checksum() {
	local file="$1"
	local lo hi

	lo="$(read_byte_dec "$file" 254)"
	hi="$(read_byte_dec "$file" 255)"

	echo $((lo + hi * 256))
}

write_zyfwinfo_checksum() {
	local file="$1"
	local checksum lo hi

	checksum="$(calc_zyfwinfo_checksum "$file")"
	lo=$((checksum & 255))
	hi=$(((checksum >> 8) & 255))

	write_byte "$file" 254 "$lo"
	write_byte "$file" 255 "$hi"

	echo "$checksum"
}

verify_zyfwinfo_file() {
	local file="$1"
	local expected_seq="$2"
	local label="$3"
	local seq calc stored byte04 byte09 rootfs_load_size

	[ -f "$file" ] || fail "$label missing: $file"

	seq="$(read_byte_dec "$file" 6)"
	byte04="$(read_byte_dec "$file" 4)"
	byte09="$(read_byte_dec "$file" 9)"
	rootfs_load_size="$(read_le32_dec "$file" 120)"
	calc="$(calc_zyfwinfo_checksum "$file")"
	stored="$(read_zyfwinfo_stored_checksum "$file")"

	say "$label first 1 KiB:"
	dd if="$file" bs=1024 count=1 2>/dev/null | hexdump -C
	say "$label sequence: $seq"
	say "$label format byte04: $byte04"
	say "$label format byte09: $byte09"
	say "$label rootfs load size field 0x78: 0x$(printf '%08x' "$rootfs_load_size")"
	say "$label checksum calculated: 0x$(printf '%04x' "$calc")"
	say "$label checksum stored:     0x$(printf '%04x' "$stored")"

	[ "$seq" = "$expected_seq" ] || fail "$label sequence mismatch: expected $expected_seq got $seq"
	[ "$calc" = "$stored" ] || fail "$label checksum mismatch"
}

make_minimal_zyfwinfo() {
	local file="$1"
	local seq="$2"
	local checksum

	dd if=/dev/zero of="$file" bs=256 count=1 >/dev/null 2>&1 || \
		fail "could not create minimal zyfwinfo"

	# Magic: EXYZ
	write_byte "$file" 0 69
	write_byte "$file" 1 88
	write_byte "$file" 2 89
	write_byte "$file" 3 90

	# Minimal OpenWrt-compatible fields.
	write_byte "$file" 4 2
	write_byte "$file" 6 "$seq"
	write_byte "$file" 9 1

	checksum="$(write_zyfwinfo_checksum "$file")"
	echo "$checksum"
}

make_rich_zyfwinfo() {
	local active_zyfw="$1"
	local file="$2"
	local seq="$3"
	local target_rootfs="$4"
	local leb_size="$5"
	local checksum magic rootfs_load_size

	dd if="$active_zyfw" of="$file" bs="$leb_size" count=1 >/dev/null 2>&1 || \
		fail "could not read full active zyfwinfo"

	magic="$(dd if="$file" bs=4 count=1 2>/dev/null || true)"
	[ "$magic" = "EXYZ" ] || fail "active zyfwinfo has bad magic"


	write_byte "$file" 4 3
	write_byte "$file" 9 4
	say "Forced zyfwinfo rich markers: byte04=3 byte09=4"

	# Sequence controls which bank zloader selects.
	write_byte "$file" 6 "$seq"


	rootfs_load_size="$(calc_rootfs_load_size_for_zyfwinfo "$target_rootfs")"
	write_le32_dec "$file" 120 "$rootfs_load_size"

	printf "Target rootfs load size for rich zyfwinfo: 0x%08x\n" "$rootfs_load_size" >&2

	# Recalculate first-0x100 zyfwinfo checksum.
	write_byte "$file" 254 0
	write_byte "$file" 255 0
	checksum="$(write_zyfwinfo_checksum "$file")"
	echo "$checksum"
}

inspect_zloader_for_switch() {
	local zld_mtd="$1"
	local current_file="$WORK/zloader.current.bin"
	local target_file="$OLD_ZLOADER_PATH"
	local target_size target_string

	ZLOADER_ACTION="keep"
	ZLOADER_CURRENT_STRING="unknown"
	ZLOADER_CURRENT_HASH=""
	ZLOADER_TARGET_HASH=""

	[ "$ZLOADER_FIX" = "1" ] || {
		ZLOADER_ACTION="disabled"
		say "ZLOADER_FIX=0; zloader replacement disabled."
		return 0
	}

	[ -f "$target_file" ] || fail "zloader replacement missing: $target_file"

	target_size="$(wc -c < "$target_file" | awk '{print $1}')"
	[ "$target_size" -gt 4096 ] || fail "zloader replacement looks too small: $target_file"
	[ "$target_size" -le 262144 ] || fail "zloader replacement is larger than 256 KiB partition: $target_size"

	dd if="/dev/mtd$zld_mtd" of="$current_file" bs="$target_size" count=1 >/dev/null 2>&1 || \
		fail "could not read current zloader from /dev/mtd$zld_mtd"

	ZLOADER_CURRENT_HASH="$(file_sha256 "$current_file")"
	ZLOADER_TARGET_HASH="$(file_sha256 "$target_file")"

	ZLOADER_CURRENT_STRING="$(strings "$current_file" | grep -E 'zld-[0-9]' | head -n1 || true)"
	[ -n "$ZLOADER_CURRENT_STRING" ] || ZLOADER_CURRENT_STRING="unknown"

	target_string="$(strings "$target_file" | grep -E 'zld-[0-9]' | head -n1 || true)"
	[ -n "$target_string" ] || fail "could not identify zloader string in $target_file"

	say "Current zloader:     $ZLOADER_CURRENT_STRING"
	say "Current zloader sha: $ZLOADER_CURRENT_HASH"
	say "Target zloader:      $target_string"
	say "Target zloader sha:  $ZLOADER_TARGET_HASH"

	# Keep this string sanity check because writing a bad zloader is fatal on no-UART devices.
	echo "$target_string" | grep -q "$OLD_ZLOADER_MATCH" || \
		fail "$target_file does not look like expected old zloader ($OLD_ZLOADER_MATCH)"

	if [ "$ZLOADER_CURRENT_HASH" = "$ZLOADER_TARGET_HASH" ]; then
		ZLOADER_ACTION="keep"
		say "Current zloader already matches $target_file; no zloader replacement needed."
	else
		ZLOADER_ACTION="replace"
		say "Current zloader hash differs from $target_file; will replace zloader before reboot."
	fi
}

apply_zloader_switch_if_needed() {
	local zld_mtd="$1"
	local zld_size check_file ro

	[ "$ZLOADER_FIX" = "1" ] || {
		say "ZLOADER_FIX=0; not replacing zloader."
		return 0
	}

	[ "$ZLOADER_ACTION" = "replace" ] || {
		say "Zloader replacement not needed."
		return 0
	}

	say "Backing up current zloader to $WORK/zloader.before_replace.bin"
	dd if="/dev/mtd$zld_mtd" of="$WORK/zloader.before_replace.bin" bs=256K count=1 >/dev/null 2>&1 || \
		fail "could not backup current zloader"

	if [ -f "/sys/class/mtd/mtd$zld_mtd/ro" ]; then
		ro="$(cat "/sys/class/mtd/mtd$zld_mtd/ro" 2>/dev/null || echo 0)"
		if [ "$ro" != "0" ]; then
			say "zloader MTD is read-only; trying /tmp/mtd-rw.ko"
			insmod /tmp/mtd-rw.ko i_want_a_brick=1 2>/dev/null || true
			ro="$(cat "/sys/class/mtd/mtd$zld_mtd/ro" 2>/dev/null || echo 1)"
			[ "$ro" = "0" ] || fail "zloader MTD is still read-only"
		fi
	fi

	say "Writing old zloader from $OLD_ZLOADER_PATH to /dev/mtd$zld_mtd"
	mtd write "$OLD_ZLOADER_PATH" "/dev/mtd$zld_mtd" >/dev/null || \
		fail "could not write old zloader"
	sync

	zld_size="$(wc -c < "$OLD_ZLOADER_PATH" | awk '{print $1}')"
	check_file="$WORK/zloader.after_replace.bin"
	dd if="/dev/mtd$zld_mtd" of="$check_file" bs="$zld_size" count=1 >/dev/null 2>&1 || \
		fail "could not read back replaced zloader"

	cmp "$OLD_ZLOADER_PATH" "$check_file" >/dev/null || fail "old zloader readback mismatch"
	say "OLD_ZLOADER_WRITE_OK"
	strings "$check_file" | grep -E 'zld-[0-9]' | head -n1 || true
}

inspect_fip_for_switch() {
	local fip_mtd="$1"
	local current_file="$WORK/fip.current.bin"
	local target_file="$FIP_PATH"
	local target_size

	FIP_ACTION="keep"
	FIP_CURRENT_STRING="unknown"
	FIP_TARGET_STRING="unknown"
	FIP_CURRENT_HASH=""
	FIP_TARGET_HASH=""

	[ "$FIP_FIX" = "1" ] || {
		FIP_ACTION="disabled"
		say "FIP_FIX=0; FIP replacement disabled."
		return 0
	}

	if [ ! -f "$target_file" ]; then
		FIP_ACTION="missing"
		say "WARNING: FIP replacement missing: $target_file"
		say "WARNING: continuing without FIP replacement."
		return 0
	fi

	target_size="$(wc -c < "$target_file" | awk '{print $1}')"
	if [ "$target_size" -le 1048576 ]; then
		FIP_ACTION="invalid"
		say "WARNING: FIP replacement looks too small: $target_file ($target_size bytes)"
		say "WARNING: continuing without FIP replacement."
		return 0
	fi
	if [ "$target_size" -gt 2097152 ]; then
		FIP_ACTION="invalid"
		say "WARNING: FIP replacement is larger than expected 2 MiB partition: $target_size"
		say "WARNING: continuing without FIP replacement."
		return 0
	fi

	dd if="/dev/mtd$fip_mtd" of="$current_file" bs="$target_size" count=1 >/dev/null 2>&1 || {
		FIP_ACTION="read_failed"
		say "WARNING: could not read current FIP from /dev/mtd$fip_mtd"
		say "WARNING: continuing without FIP replacement."
		return 0
	}

	FIP_CURRENT_HASH="$(file_sha256 "$current_file")"
	FIP_TARGET_HASH="$(file_sha256 "$target_file")"

	FIP_CURRENT_STRING="$(strings "$current_file" | grep -Ei 'U-Boot 20|v2\\.6\\(release\\)|Built :' | head -n1 || true)"
	[ -n "$FIP_CURRENT_STRING" ] || FIP_CURRENT_STRING="unknown"
	FIP_TARGET_STRING="$(strings "$target_file" | grep -Ei 'U-Boot 20|v2\\.6\\(release\\)|Built :' | head -n1 || true)"
	[ -n "$FIP_TARGET_STRING" ] || FIP_TARGET_STRING="unknown"

	say "Current FIP hint:     $FIP_CURRENT_STRING"
	say "Current FIP sha:      $FIP_CURRENT_HASH"
	say "Target FIP hint:      $FIP_TARGET_STRING"
	say "Target FIP sha:       $FIP_TARGET_HASH"

	if [ "$FIP_CURRENT_HASH" = "$FIP_TARGET_HASH" ]; then
		FIP_ACTION="keep"
		say "Current FIP already matches $target_file; no FIP replacement needed."
	else
		FIP_ACTION="replace"
		say "Current FIP hash differs from $target_file; will try to replace FIP before reboot."
		say "If FIP replacement fails cleanly, the script will continue."
	fi
}

apply_fip_switch_if_needed() {
	local fip_mtd="$1"
	local target_size check_file before_file after_fail_file ro

	[ "$FIP_FIX" = "1" ] || {
		say "FIP_FIX=0; not replacing FIP."
		return 0
	}

	[ "$FIP_ACTION" = "replace" ] || {
		say "FIP replacement not needed. action=$FIP_ACTION"
		return 0
	}

	target_size="$(wc -c < "$FIP_PATH" | awk '{print $1}')"
	before_file="$WORK/fip.before_replace.bin"
	check_file="$WORK/fip.after_replace.bin"
	after_fail_file="$WORK/fip.after_failed_replace.bin"

	say "Backing up current FIP exact replacement-size region to $before_file"
	dd if="/dev/mtd$fip_mtd" of="$before_file" bs="$target_size" count=1 >/dev/null 2>&1 || {
		say "WARNING: could not backup current FIP; skipping FIP replacement."
		FIP_ACTION="backup_failed"
		return 0
	}

	if [ -f "/sys/class/mtd/mtd$fip_mtd/ro" ]; then
		ro="$(cat "/sys/class/mtd/mtd$fip_mtd/ro" 2>/dev/null || echo 0)"
		if [ "$ro" != "0" ]; then
			say "FIP MTD is read-only; trying /tmp/mtd-rw.ko"
			insmod /tmp/mtd-rw.ko i_want_a_brick=1 2>/dev/null || true
		fi
	fi

	say "Trying to write FIP from $FIP_PATH to /dev/mtd$fip_mtd"
	if ! mtd write "$FIP_PATH" "/dev/mtd$fip_mtd" >/dev/null 2>&1; then
		say "WARNING: FIP write command failed. Checking whether current FIP stayed unchanged."
		dd if="/dev/mtd$fip_mtd" of="$after_fail_file" bs="$target_size" count=1 >/dev/null 2>&1 || \
			fail "FIP write failed and FIP readback also failed; refusing to continue"
		if cmp "$before_file" "$after_fail_file" >/dev/null; then
			say "FIP unchanged after failed write; continuing without FIP replacement."
			FIP_ACTION="write_failed_unchanged"
			return 0
		fi
		fail "FIP changed during failed write; refusing to continue"
	fi

	sync

	dd if="/dev/mtd$fip_mtd" of="$check_file" bs="$target_size" count=1 >/dev/null 2>&1 || \
		fail "FIP write reported success but readback failed"

	if cmp "$FIP_PATH" "$check_file" >/dev/null; then
		say "FIP_WRITE_OK"
		FIP_ACTION="replaced"
		return 0
	fi

	fail "FIP write reported success but readback mismatch; refusing to reboot"
}

inspect_initramfs_strings() {
	say "[2b] Inspecting initramfs strings"

	if command -v strings >/dev/null 2>&1; then
		say "Interesting initramfs strings:"
		strings "$INITRAMFS" | grep -Ei 'ubootmod|stock|labelswap|bootargs|rootubi|ubi_oem|EX5601|OpenWrt|Linux' | head -n 80 || true

		if strings "$INITRAMFS" | grep -qi 'ubootmod'; then
			say "WARNING: initramfs contains 'ubootmod'."
			say "WARNING: stock Zyxel zloader may fail with: bootargs in fdt not found"
		fi

		if strings "$INITRAMFS" | grep -qiE 'stock|labelswap|ubi_oem'; then
			say "INITRAMFS_LAYOUT_HINT=stock_or_labelswap"
		else
			say "WARNING: initramfs does not show stock/labelswap/ubi_oem strings."
			say "WARNING: this may still boot, but without UART it is harder to confirm."
		fi
	else
		say "WARNING: strings command not found; skipping initramfs string diagnosis"
	fi
}

diagnose_dump_zyfwinfo() {
	local label="$1"
	local dev="$2"
	local out="$WORK/diagnose_${label}_zyfwinfo.bin"
	local seq calc stored

	say ""
	say "===== $label zyfwinfo ====="
	say "device=$dev"

	dd if="$dev" of="$out" bs=256 count=1 >/dev/null 2>&1 || {
		say "ERROR: could not read $label zyfwinfo from $dev"
		return 1
	}

	hexdump -C "$out"

	seq="$(read_byte_dec "$out" 6)"
	calc="$(calc_zyfwinfo_checksum "$out")"
	stored="$(read_zyfwinfo_stored_checksum "$out")"

	say "${label}_SEQ=$seq"
	say "${label}_CHECKSUM_CALC=0x$(printf '%04x' "$calc")"
	say "${label}_CHECKSUM_STORED=0x$(printf '%04x' "$stored")"

	if [ "$calc" = "$stored" ]; then
		say "${label}_CHECKSUM=OK"
	else
		say "${label}_CHECKSUM=BAD"
	fi

	echo "$seq" > "$WORK/diagnose_${label}_seq.txt"
	echo "$calc" > "$WORK/diagnose_${label}_calc.txt"
	echo "$stored" > "$WORK/diagnose_${label}_stored.txt"
}

diagnose_kernel_volume() {
	local dev="$1"
	local target_name="$2"
	local sample="$WORK/diagnose_target_kernel_sample.bin"
	local magic

	say ""
	say "===== target kernel/FIT diagnosis ====="
	say "device=$dev"

	# Read up to 16 MiB, enough for typical initramfs FITs and DTB strings.
	dd if="$dev" of="$sample" bs=512K count=32 >/dev/null 2>&1 || {
		say "ERROR: could not read target kernel volume"
		return 1
	}

	magic="$(dd if="$sample" bs=4 count=1 2>/dev/null | hexdump -v -e '4/1 "%02x"')"
	say "FIT_MAGIC=$magic"

	if [ "$magic" = "d00dfeed" ]; then
		say "FIT_MAGIC_CHECK=OK"
	else
		say "FIT_MAGIC_CHECK=BAD"
	fi

	if command -v strings >/dev/null 2>&1; then
		say ""
		say "Interesting strings from target kernel:"
		strings "$sample" | grep -Ei 'ubootmod|stock|labelswap|bootargs|rootubi|ubi_oem|EX5601|OpenWrt|Linux' | head -n 100 || true
	else
		say "WARNING: strings command not found; skipping target kernel string diagnosis"
	fi

	if grep -aq 'ubootmod' "$sample"; then
		say "WARNING: target image contains 'ubootmod'."
		say "WARNING: stock Zyxel zloader may fail with: bootargs in fdt not found"
	fi

	if [ "$target_name" = "ubi2" ]; then
		if grep -aqE 'labelswap|ubi_oem' "$sample"; then
			say "LABELSWAP_CHECK=probably OK for physical ubi2 target"
		else
			say "WARNING: target is physical ubi2, but image does not show labelswap/ubi_oem string"
		fi
	fi
}

diagnose_no_uart() {
	local CMDLINE ROOTUBI
	local MTD_PARENT MTD_UBI MTD_UBI2 MTD_ZYUBI
	local ACTIVE_MTD TARGET_MTD TARGET_NAME
	local ACTIVE_UBI TARGET_UBI
	local ACTIVE_ZYFW TARGET_ZYFW TARGET_KERNEL TARGET_ROOTFS TARGET_ZYDEFAULT
	local ACTIVE_SEQ TARGET_SEQ TARGET_CALC TARGET_STORED MAGIC

	say "=== Matrix EX5601-T0 no-UART diagnosis ==="
	say "READ-ONLY MODE"
	say "No formatting, no writing, no sys atsw, no sys seqnum, no sys atsh."
	say "LOG=$LOG"
	say ""

	need_cmd awk
	need_cmd cat
	need_cmd dd
	need_cmd grep
	need_cmd hexdump
	need_cmd mkdir
	need_cmd sleep
	need_cmd ubiattach
	need_cmd ubinfo

	rm -rf "$WORK/diagnose"
	mkdir -p "$WORK"

	say "===== date ====="
	date 2>/dev/null || true

	say ""
	say "===== /proc/cmdline ====="
	[ -r /proc/cmdline ] || fail "/proc/cmdline missing"
	cat /proc/cmdline

	say ""
	say "===== /proc/mtd ====="
	[ -r /proc/mtd ] || fail "/proc/mtd missing"
	cat /proc/mtd

	CMDLINE="$(cat /proc/cmdline)"
	ROOTUBI="$(awk '{
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^rootubi=/) {
				sub(/^rootubi=/, "", $i)
				print $i
				exit
			}
		}
	}' /proc/cmdline)"

	MTD_PARENT="$(mtd_num_by_name spi0.1 || true)"
	MTD_UBI="$(mtd_num_by_name ubi || true)"
	MTD_UBI2="$(mtd_num_by_name ubi2 || true)"
	MTD_ZYUBI="$(mtd_num_by_name zyubi || true)"

	if [ -n "$MTD_PARENT" ]; then
		say "Parent MTD spi0.1 is present as mtd$MTD_PARENT"
	else
		say "Parent MTD spi0.1 is not exposed; OpenWrt stock commonly exposes only child partitions"
	fi
	[ -n "$MTD_UBI" ] || fail "mtd named ubi missing"
	[ -n "$MTD_UBI2" ] || fail "mtd named ubi2 missing"
	[ -n "$MTD_ZYUBI" ] || fail "mtd named zyubi missing"

	case "$ROOTUBI" in
		ubi)
			ACTIVE_MTD="$MTD_UBI"
			TARGET_MTD="$MTD_UBI2"
			TARGET_NAME="ubi2"
			;;
		ubi2)
			ACTIVE_MTD="$MTD_UBI2"
			TARGET_MTD="$MTD_UBI"
			TARGET_NAME="ubi"
			;;
		*)
			fail "unsupported or missing rootubi=$ROOTUBI"
			;;
	esac

	say ""
	say "===== bank decision ====="
	say "ROOTUBI=$ROOTUBI"
	if [ -n "$MTD_PARENT" ]; then
		if [ -n "$MTD_PARENT" ]; then
	say "MTD_PARENT=mtd$MTD_PARENT"
else
	say "MTD_PARENT=not-exposed"
fi
	else
		say "MTD_PARENT=not-exposed"
	fi
	say "MTD_UBI=mtd$MTD_UBI"
	say "MTD_UBI2=mtd$MTD_UBI2"
	say "MTD_ZYUBI=mtd$MTD_ZYUBI"
	say "ACTIVE_MTD=mtd$ACTIVE_MTD"
	say "TARGET_MTD=mtd$TARGET_MTD"
	say "TARGET_NAME=$TARGET_NAME"

	ACTIVE_UBI="$(attach_mtd "$ACTIVE_MTD")"
	TARGET_UBI="$(attach_mtd "$TARGET_MTD")"

	say "ACTIVE_UBI=$ACTIVE_UBI"
	say "TARGET_UBI=$TARGET_UBI"

	say ""
	say "===== ubinfo -a ====="
	ubinfo -a 2>&1 || true

	ACTIVE_ZYFW="$(ubi_vol_dev_by_name "$ACTIVE_UBI" zyfwinfo || true)"
	TARGET_ZYFW="$(ubi_vol_dev_by_name "$TARGET_UBI" zyfwinfo || true)"
	TARGET_KERNEL="$(ubi_vol_dev_by_name "$TARGET_UBI" kernel || true)"
	TARGET_ROOTFS="$(ubi_vol_dev_by_name "$TARGET_UBI" rootfs || true)"
	TARGET_ZYDEFAULT="$(ubi_vol_dev_by_name "$TARGET_UBI" zydefault || true)"

	[ -n "$ACTIVE_ZYFW" ] || fail "active zyfwinfo not found"
	[ -n "$TARGET_ZYFW" ] || fail "target zyfwinfo not found"
	[ -n "$TARGET_KERNEL" ] || fail "target kernel not found"
	[ -n "$TARGET_ROOTFS" ] || fail "target rootfs not found"

	say ""
	say "===== target volume devices ====="
	say "TARGET_KERNEL=$TARGET_KERNEL"
	say "TARGET_ROOTFS=$TARGET_ROOTFS"
	say "TARGET_ZYFW=$TARGET_ZYFW"
	say "TARGET_ZYDEFAULT=${TARGET_ZYDEFAULT:-missing}"

	diagnose_dump_zyfwinfo active "$ACTIVE_ZYFW"
	diagnose_dump_zyfwinfo target "$TARGET_ZYFW"

	ACTIVE_SEQ="$(cat "$WORK/diagnose_active_seq.txt")"
	TARGET_SEQ="$(cat "$WORK/diagnose_target_seq.txt")"
	TARGET_CALC="$(cat "$WORK/diagnose_target_calc.txt")"
	TARGET_STORED="$(cat "$WORK/diagnose_target_stored.txt")"

	say ""
	say "===== boot switch condition ====="

	if [ "$TARGET_CALC" = "$TARGET_STORED" ]; then
		say "TARGET_ZYFWINFO_CHECKSUM=OK"
	else
		say "TARGET_ZYFWINFO_CHECKSUM=BAD"
	fi

	if [ "$TARGET_SEQ" -gt "$ACTIVE_SEQ" ] 2>/dev/null; then
		say "TARGET_SEQUENCE_HIGHER=OK"
	else
		say "TARGET_SEQUENCE_HIGHER=BAD"
	fi

	say "ACTIVE_SEQ=$ACTIVE_SEQ"
	say "TARGET_SEQ=$TARGET_SEQ"

	diagnose_kernel_volume "$TARGET_KERNEL" "$TARGET_NAME"

	say ""
	say "===== optional current initramfs file diagnosis ====="

	if [ -f "$INITRAMFS" ]; then
		say "INITRAMFS=$INITRAMFS exists"
		MAGIC="$(dd if="$INITRAMFS" bs=4 count=1 2>/dev/null | hexdump -v -e '4/1 "%02x"')"
		say "INITRAMFS_FIT_MAGIC=$MAGIC"
		inspect_initramfs_strings
	else
		say "INITRAMFS=$INITRAMFS does not exist; skipping file diagnosis"
	fi

	say ""
	say "===== diagnosis summary ====="

	if [ "$TARGET_CALC" = "$TARGET_STORED" ] && [ "$TARGET_SEQ" -gt "$ACTIVE_SEQ" ] 2>/dev/null; then
		say "ZYFWINFO_SWITCH_CONDITION=OK"
	else
		say "ZYFWINFO_SWITCH_CONDITION=BAD"
	fi

	say "If ZYFWINFO_SWITCH_CONDITION=OK but router still boots OEM, suspect wrong FIT/DTB image."
	say "If target image contains 'ubootmod', stock zloader may stop with: bootargs in fdt not found"
	say "Log saved to: $LOG"
}

timeout_guard() {
	sleep "$STAGE_TIMEOUT"

	say ""
	say "================================================"
	say "STAGING TIMEOUT"
	say "================================================"
	say "The starter exceeded ${STAGE_TIMEOUT}s."
	say "Last recorded stage: ${STAGE:-unknown}"
	say "Boot switch committed: ${BOOT_SWITCH_COMMITTED:-0}"

	invalidate_uncommitted_target_switch
	say "Forcing reboot because the unattended starter stopped making progress."
	force_reboot_now
}

is_positive_integer() {
	case "$1" in
		""|*[!0-9]*|0)
			return 1
			;;
		*)
			return 0
			;;
	esac
}

start_timeout_guard() {
	[ "$ACTION" = "stage" ] || return 0

	is_positive_integer "$STAGE_TIMEOUT" || {
		STAGE_TIMEOUT=600
		say "WARNING: invalid STAGE_TIMEOUT; using 600 seconds"
	}

	is_positive_integer "$FAIL_REBOOT_DELAY" || {
		FAIL_REBOOT_DELAY=8
		say "WARNING: invalid FAIL_REBOOT_DELAY; using 8 seconds"
	}

	timeout_guard &
	TIMEOUT_GUARD_PID="$!"
	say "Unattended timeout guard started: pid=$TIMEOUT_GUARD_PID timeout=${STAGE_TIMEOUT}s"
}

cleanup() {
	if [ -n "${TIMEOUT_GUARD_PID:-}" ]; then
		kill "$TIMEOUT_GUARD_PID" 2>/dev/null || true
		wait "$TIMEOUT_GUARD_PID" 2>/dev/null || true
	fi
	rm -rf "$LOCK"
}
trap cleanup EXIT

verify_openwrt_stock_board() {
	local board_name compatible model

	board_name="$(cat /tmp/sysinfo/board_name 2>/dev/null || true)"
	compatible="$(tr '\000' ' ' < /proc/device-tree/compatible 2>/dev/null || true)"
	model="$(tr '\000' ' ' < /proc/device-tree/model 2>/dev/null || true)"

	say "BOARD_NAME=${board_name:-missing}"
	say "MODEL=${model:-missing}"
	say "COMPATIBLE=${compatible:-missing}"

	case "$(echo "$board_name" | tr 'A-Z' 'a-z')" in
		*ex5601*t0*stock*|zyxel,ex5601-t0-stock)
			;;
		*)
			fail "this launcher must run from OpenWrt stock layout; unexpected board_name=$board_name"
			;;
	esac
}

log_ubi_state() {
	local label="$1"
	local u base v

	say ""
	say "===== $label: UBI sysfs mapping ====="
	for u in /sys/class/ubi/ubi[0-9]*; do
		[ -f "$u/mtd_num" ] || continue
		base="$(basename "$u")"
		say "$base -> mtd$(cat "$u/mtd_num" 2>/dev/null || echo '?')"

		for v in /sys/class/ubi/"${base}"_*; do
			[ -f "$v/name" ] || continue
			say "  ${v##*/}: name=$(cat "$v/name" 2>/dev/null || echo '?') reserved_ebs=$(cat "$v/reserved_ebs" 2>/dev/null || echo '?') data_bytes=$(cat "$v/data_bytes" 2>/dev/null || echo '?')"
		done
	done

	say ""
	say "===== $label: ubinfo -a ====="
	ubinfo -a 2>&1 || true
}

verify_volume_prefix() {
	local dev="$1"
	local file="$2"
	local label="$3"
	local size want got

	size="$(wc -c < "$file" | awk '{print $1}')"
	[ "$size" -gt 0 ] || fail "$label verification source is empty: $file"

	want="$(file_sha256 "$file")"
	got="$(dd if="$dev" bs="$size" count=1 2>/dev/null | sha256sum | awk '{print $1}')"

	say "${label}_SOURCE_SHA256=$want"
	say "${label}_READBACK_SHA256=$got"

	[ "$got" = "$want" ] || fail "$label readback mismatch from $dev"
	say "${label}_READBACK=OK"
}

verify_initramfs_readback() {
	local dev="$1"
	verify_volume_prefix "$dev" "$INITRAMFS" "INITRAMFS"
}

if [ "$ACTION" = "diagnose" ]; then
	diagnose_no_uart
	exit 0
fi

mkdir "$LOCK" 2>/dev/null || fail "another initramfs staging process is running"
start_timeout_guard

say "=== Matrix EX5601-T0 Project C inactive-bank initramfs stager ==="
say "Boot switch method: inactive stock bank + rich zyfwinfo sequence"
say "No sysupgrade is used for this first hop."
say "No sys atsw / no sys seqnum / no sys atsh"
say "ZYFWINFO_MODE=$ZYFWINFO_MODE"
say "ZLOADER_FIX=$ZLOADER_FIX"
say "OLD_ZLOADER_PATH=$OLD_ZLOADER_PATH"
say "FIP_FIX=$FIP_FIX"
say "FIP_PATH=$FIP_PATH"
say "NO_REBOOT=$NO_REBOOT"
say "INITRAMFS=$INITRAMFS"
say "LOG=$LOG"
say "STAGE_TIMEOUT=$STAGE_TIMEOUT"

case "$NO_REBOOT" in
	0|1)
		;;
	*)
		fail "NO_REBOOT must be 0 or 1"
		;;
esac

STAGE="preflight"


[ "$FIP_FIX" = "0" ] || fail "FIP_FIX must remain 0 for unattended Project C staging"
[ "$ZLOADER_FIX" = "0" ] || fail "ZLOADER_FIX must remain 0 for unattended Project C staging"

case "$ZYFWINFO_MODE" in
	rich|copy_oem|copy_oem_rich)
		;;
	*)
		fail "ZYFWINFO_MODE must be rich for unattended staging"
		;;
esac

say "[1] Checking commands"

need_cmd awk
need_cmd cat
need_cmd cp
need_cmd dd
need_cmd grep
need_cmd hexdump
need_cmd strings
need_cmd sha256sum
need_cmd mtd
need_cmd cmp
need_cmd sed
need_cmd head
need_cmd mkdir
need_cmd rm
need_cmd sleep
need_cmd sync
need_cmd ubidetach
need_cmd ubiformat
need_cmd ubiattach
need_cmd umount
need_cmd ubimkvol
need_cmd ubinfo
need_cmd ubiupdatevol
need_cmd wc

say "[2] Checking OpenWrt stock runtime and image"

verify_openwrt_stock_board

say ""
say "===== current /proc/cmdline ====="
cat /proc/cmdline 2>/dev/null || true

say ""
say "===== current /proc/mtd ====="
cat /proc/mtd 2>/dev/null || true

say ""
say "===== current /proc/mounts ====="
cat /proc/mounts 2>/dev/null || true

log_ubi_state "Before staging"

[ -f "$INITRAMFS" ] || fail "missing $INITRAMFS"

INITRAMFS_SIZE="$(wc -c < "$INITRAMFS" | awk '{print $1}')"
[ "$INITRAMFS_SIZE" -gt 1048576 ] || fail "initramfs image too small"

MAGIC="$(dd if="$INITRAMFS" bs=4 count=1 2>/dev/null | hexdump -v -e '4/1 "%02x"')"

case "$MAGIC" in
	d00dfeed)
		say "FIT image detected"
		;;
	*)
		fail "initramfs.bin does not look like a FIT/ITB image, magic=$MAGIC"
		;;
esac

say "INITRAMFS_SIZE=$INITRAMFS_SIZE"
say "INITRAMFS_SHA256=$(file_sha256 "$INITRAMFS")"
inspect_initramfs_strings

strings "$INITRAMFS" | grep -q 'zyxel_ex5601-t0-ubootmod' || \
	fail "$INITRAMFS does not contain zyxel_ex5601-t0-ubootmod"

if strings "$INITRAMFS" | grep -qiE 'initramfs|initrd|ramdisk|RAMDisk'; then
	say "INITRAMFS_MARKER_CHECK=OK"
else
	fail "$INITRAMFS does not look like an initramfs/RAMDisk FIT"
fi

if strings "$INITRAMFS" | grep -qE 'zyxel_ex5601-t0-stock|zyxel,ex5601-t0-stock'; then
	fail "$INITRAMFS contains stock-layout board markers; refusing the wrong first-hop image"
fi

say "RAW_UBOOTMOD_INITRAMFS_VALIDATION=PASS"

say "[3] Checking OpenWrt stock dual-bank layout"

[ -r /proc/mtd ] || fail "/proc/mtd missing"
[ -r /proc/cmdline ] || fail "/proc/cmdline missing"

MTD_PARENT="$(mtd_num_by_name spi0.1 || true)"
MTD_UBI="$(mtd_num_by_name ubi || true)"
MTD_UBI2="$(mtd_num_by_name ubi2 || true)"
MTD_ZYUBI="$(mtd_num_by_name zyubi || true)"
MTD_ZLOADER="$(mtd_num_by_name zloader || true)"
MTD_FIP="$(mtd_num_by_name FIP || true)"

if [ -n "$MTD_PARENT" ]; then
	say "Parent MTD spi0.1 is present as mtd$MTD_PARENT"
else
	say "Parent MTD spi0.1 is not exposed; continuing with named child partitions"
fi
[ -n "$MTD_UBI" ] || fail "not OEM stock layout: mtd named ubi missing"
[ -n "$MTD_UBI2" ] || fail "not OEM stock layout: mtd named ubi2 missing"
[ -n "$MTD_ZYUBI" ] || fail "not OEM stock layout: mtd named zyubi missing"
[ -n "$MTD_ZLOADER" ] || fail "not OEM stock layout: mtd named zloader missing"
[ -n "$MTD_FIP" ] || fail "not OEM stock layout: mtd named FIP/fip missing"

CMDLINE="$(cat /proc/cmdline)"
say "$CMDLINE"

ROOTUBI_HINT="$(awk '{
	for (i = 1; i <= NF; i++) {
		if ($i ~ /^rootubi=/) {
			sub(/^rootubi=/, "", $i)
			print $i
			exit
		}
	}
}' /proc/cmdline)"

ROOTUBI_HINT_MTD="$(rootubi_hint_to_mtd "$ROOTUBI_HINT" "$MTD_UBI" "$MTD_UBI2" 2>/dev/null || true)"

detect_mounted_active_bank "$MTD_UBI" "$MTD_UBI2"

say "ROOTUBI_HINT=${ROOTUBI_HINT:-missing}"
say "ROOTUBI_HINT_MTD=${ROOTUBI_HINT_MTD:-unresolved}"
say "MOUNT_ACTIVE_MTD=${MOUNT_ACTIVE_MTD:-unresolved}"
say "MOUNT_ACTIVE_EVIDENCE=${MOUNT_ACTIVE_EVIDENCE:-none}"

if [ -n "$MOUNT_ACTIVE_MTD" ]; then
	ACTIVE_MTD="$MOUNT_ACTIVE_MTD"
	ACTIVE_DECISION_SOURCE="live mounts"

	if [ -n "$ROOTUBI_HINT_MTD" ] && [ "$ROOTUBI_HINT_MTD" != "$ACTIVE_MTD" ]; then
		say "WARNING: rootubi hint points to mtd$ROOTUBI_HINT_MTD, but live mounts use mtd$ACTIVE_MTD"
		say "WARNING: trusting live mount evidence; this is expected on some label-swapped stock builds"
	fi
elif [ -n "$ROOTUBI_HINT_MTD" ]; then
	ACTIVE_MTD="$ROOTUBI_HINT_MTD"
	ACTIVE_DECISION_SOURCE="rootubi fallback"
	say "WARNING: no mount-backed UBI source was resolved; falling back to rootubi hint"
else
	fail "could not determine active bank from live mounts or rootubi hint"
fi

if [ "$ACTIVE_MTD" = "$MTD_UBI" ]; then
	TARGET_MTD="$MTD_UBI2"
elif [ "$ACTIVE_MTD" = "$MTD_UBI2" ]; then
	TARGET_MTD="$MTD_UBI"
else
	fail "resolved active bank mtd$ACTIVE_MTD is not ubi or ubi2"
fi

TARGET_NAME="$(mtd_name_by_num "$TARGET_MTD")"
[ -n "$TARGET_NAME" ] || fail "could not resolve target MTD name"

[ "$TARGET_MTD" != "$MTD_ZYUBI" ] || fail "refusing to target zyubi"
[ "$TARGET_MTD" != "$ACTIVE_MTD" ] || fail "target equals active bank"

# This is the final non-destructive check before active metadata inspection.
# It prevents the starter from ever unmounting or formatting a live bank.
assert_mtd_not_live_mounted "$TARGET_MTD"

if [ -n "$MTD_PARENT" ]; then
	say "MTD_PARENT=mtd$MTD_PARENT"
else
	say "MTD_PARENT=not-exposed"
fi
say "MTD_UBI=mtd$MTD_UBI"
say "MTD_UBI2=mtd$MTD_UBI2"
say "MTD_ZYUBI=mtd$MTD_ZYUBI"
say "MTD_FIP=mtd$MTD_FIP"
say "MTD_ZLOADER=mtd$MTD_ZLOADER"
say "ACTIVE_MTD=mtd$ACTIVE_MTD"
say "ACTIVE_DECISION_SOURCE=$ACTIVE_DECISION_SOURCE"
say "TARGET_MTD=mtd$TARGET_MTD"
say "TARGET_NAME=$TARGET_NAME"

say "[4] Reading active metadata"

ACTIVE_UBI="$(attach_mtd "$ACTIVE_MTD")"
say "ACTIVE_UBI=$ACTIVE_UBI"

log_ubi_state "After attaching active bank"

ACTIVE_ZYFW="$(ubi_vol_dev_by_name "$ACTIVE_UBI" zyfwinfo || true)"
ACTIVE_ZYDEFAULT="$(ubi_vol_dev_by_name "$ACTIVE_UBI" zydefault || true)"

[ -n "$ACTIVE_ZYFW" ] || fail "active zyfwinfo volume missing"
say "ACTIVE_ZYFW=$ACTIVE_ZYFW"

rm -rf "$WORK"
mkdir -p "$WORK"

inspect_fip_for_switch "$MTD_FIP"
inspect_zloader_for_switch "$MTD_ZLOADER"

dd if="$ACTIVE_ZYFW" of="$WORK/zyfwinfo.active.bin" bs=256 count=1 >/dev/null 2>&1 || \
	fail "could not read active zyfwinfo"

ACTIVE_SEQ="$(read_byte_dec "$WORK/zyfwinfo.active.bin" 6)"
[ -n "$ACTIVE_SEQ" ] || fail "could not read active zyfwinfo sequence"

NEW_SEQ=$((ACTIVE_SEQ + 1))
[ "$NEW_SEQ" -le 255 ] || fail "zyfwinfo sequence overflow"

say "ACTIVE_SEQ=$ACTIVE_SEQ"
say "NEW_SEQ=$NEW_SEQ"

ACTIVE_LEB_SIZE="$(get_leb_size "$ACTIVE_UBI")"
[ -n "$ACTIVE_LEB_SIZE" ] || fail "could not determine active LEB size"

if [ -n "$ACTIVE_ZYDEFAULT" ]; then
	say "ACTIVE_ZYDEFAULT=$ACTIVE_ZYDEFAULT"
	dd if="$ACTIVE_ZYDEFAULT" of="$WORK/zydefault.active.bin" bs="$ACTIVE_LEB_SIZE" count=1 >/dev/null 2>&1 || \
		fail "could not read active zydefault"
else
	say "WARNING: active zydefault volume not found; will write empty zydefault"
fi

say "[5] Preparing and formatting inactive stock bank"
STAGE="releasing_inactive_bank"

say "Target MTD before mtd-rw:"
say "  name=$(cat "/sys/class/mtd/mtd$TARGET_MTD/name" 2>/dev/null || echo '?')"
say "  size=$(cat "/sys/class/mtd/mtd$TARGET_MTD/size" 2>/dev/null || echo '?')"
say "  flags=$(cat "/sys/class/mtd/mtd$TARGET_MTD/flags" 2>/dev/null || echo '?')"

load_mtd_rw_for_staging "$TARGET_MTD"

say "Repeating target live-mount check immediately before detach"
assert_mtd_not_live_mounted "$TARGET_MTD"

detach_mtd_if_attached "$TARGET_MTD"

say "Formatting /dev/mtd$TARGET_MTD"
ubiformat "/dev/mtd$TARGET_MTD" -y || \
	fail "ubiformat failed on /dev/mtd$TARGET_MTD"

TARGET_FORMATTED=1
STAGE="inactive_bank_formatted"

TARGET_UBI="$(attach_mtd "$TARGET_MTD")"
say "TARGET_UBI=$TARGET_UBI"

TARGET_UBI_BASE="${TARGET_UBI##*/}"
if [ -r "/sys/class/ubi/$TARGET_UBI_BASE/ro_mode" ]; then
	TARGET_UBI_RO="$(cat "/sys/class/ubi/$TARGET_UBI_BASE/ro_mode" 2>/dev/null || echo 1)"
	say "$TARGET_UBI_BASE ro_mode=$TARGET_UBI_RO"
	[ "$TARGET_UBI_RO" = "0" ] || fail "$TARGET_UBI_BASE attached in read-only mode"
fi

log_ubi_state "After formatting and attaching target bank"

LEB_SIZE="$(get_leb_size "$TARGET_UBI")"
[ -n "$LEB_SIZE" ] || fail "could not determine target LEB size"

KERNEL_VOL_SIZE="$(round_up_leb_size "$INITRAMFS_SIZE" "$LEB_SIZE")"
ROOTFS_VOL_SIZE="$LEB_SIZE"
ZYDEFAULT_VOL_SIZE="$LEB_SIZE"

say "LEB_SIZE=$LEB_SIZE"
say "KERNEL_VOL_SIZE=$KERNEL_VOL_SIZE"

TARGET_UBI_BASE="${TARGET_UBI##*/}"
AVAILABLE_EBS="$(cat "/sys/class/ubi/$TARGET_UBI_BASE/avail_eraseblocks" 2>/dev/null || echo 0)"
KERNEL_LEBS=$((KERNEL_VOL_SIZE / LEB_SIZE))
REQUIRED_EBS=$((KERNEL_LEBS + 4))

say "AVAILABLE_EBS=$AVAILABLE_EBS"
say "REQUIRED_EBS_BEFORE_ROOTFS_DATA=$REQUIRED_EBS"

[ "$AVAILABLE_EBS" -gt "$REQUIRED_EBS" ] || \
	fail "inactive bank does not have enough UBI eraseblocks for initramfs staging"

say "[6] Creating temporary boot volumes"
STAGE="creating_target_volumes"

ubimkvol "$TARGET_UBI" -n 0 -N kernel -s "$KERNEL_VOL_SIZE" >/dev/null || \
	fail "could not create kernel volume"

ubimkvol "$TARGET_UBI" -n 1 -N rootfs -s "$ROOTFS_VOL_SIZE" >/dev/null || \
	fail "could not create rootfs volume"

# Rich zyfwinfo needs a full LEB because ACEA zloader reads at least 0x400 bytes.
ubimkvol "$TARGET_UBI" -n 2 -N zyfwinfo -s "$LEB_SIZE" >/dev/null || \
	fail "could not create zyfwinfo volume"

ubimkvol "$TARGET_UBI" -n 3 -N zydefault -s "$ZYDEFAULT_VOL_SIZE" >/dev/null || \
	fail "could not create zydefault volume"

ubimkvol "$TARGET_UBI" -n 4 -N rootfs_data -m >/dev/null || \
	fail "could not create rootfs_data volume"

TARGET_KERNEL="$(ubi_vol_dev_by_name "$TARGET_UBI" kernel || true)"
TARGET_ROOTFS="$(ubi_vol_dev_by_name "$TARGET_UBI" rootfs || true)"
TARGET_ZYFW="$(ubi_vol_dev_by_name "$TARGET_UBI" zyfwinfo || true)"
TARGET_ZYDEFAULT="$(ubi_vol_dev_by_name "$TARGET_UBI" zydefault || true)"

[ -n "$TARGET_KERNEL" ] || fail "target kernel volume not found"
[ -n "$TARGET_ROOTFS" ] || fail "target rootfs volume not found"
[ -n "$TARGET_ZYFW" ] || fail "target zyfwinfo volume not found"
[ -n "$TARGET_ZYDEFAULT" ] || fail "target zydefault volume not found"

say "TARGET_KERNEL=$TARGET_KERNEL"
say "TARGET_ROOTFS=$TARGET_ROOTFS"
say "TARGET_ZYFW=$TARGET_ZYFW"
say "TARGET_ZYDEFAULT=$TARGET_ZYDEFAULT"

say "[7] Writing and verifying initramfs FIT"
STAGE="writing_initramfs"

ubiupdatevol "$TARGET_KERNEL" "$INITRAMFS" >/dev/null || \
	fail "could not write initramfs kernel volume"

sync
verify_initramfs_readback "$TARGET_KERNEL"
STAGE="initramfs_verified"

say "[8] Writing and verifying rootfs placeholder"

dd if=/dev/zero of="$WORK/empty-rootfs.bin" bs="$LEB_SIZE" count=1 >/dev/null 2>&1 || \
	fail "could not create empty rootfs placeholder"

ubiupdatevol "$TARGET_ROOTFS" "$WORK/empty-rootfs.bin" >/dev/null || \
	fail "could not write empty rootfs placeholder"

sync
verify_volume_prefix "$TARGET_ROOTFS" "$WORK/empty-rootfs.bin" "ROOTFS_PLACEHOLDER"
STAGE="rootfs_placeholder_verified"

say "[9] Writing and verifying zydefault"

if [ -f "$WORK/zydefault.active.bin" ]; then
	ZYDEFAULT_SOURCE="$WORK/zydefault.active.bin"
else
	ZYDEFAULT_SOURCE="$WORK/zydefault.empty.bin"
	dd if=/dev/zero of="$ZYDEFAULT_SOURCE" bs="$LEB_SIZE" count=1 >/dev/null 2>&1 || \
		fail "could not create empty zydefault"
fi

ubiupdatevol "$TARGET_ZYDEFAULT" "$ZYDEFAULT_SOURCE" >/dev/null || \
	fail "could not write zydefault"

sync
verify_volume_prefix "$TARGET_ZYDEFAULT" "$ZYDEFAULT_SOURCE" "ZYDEFAULT"
STAGE="zydefault_verified"

say "[10] Preparing final target zyfwinfo in RAM"

CHECKSUM="$(make_rich_zyfwinfo "$ACTIVE_ZYFW" "$WORK/zyfwinfo.target.bin" "$NEW_SEQ" "$TARGET_ROOTFS" "$LEB_SIZE")"
say "Generated zyfwinfo checksum: 0x$(printf '%04x' "$CHECKSUM")"
verify_zyfwinfo_file "$WORK/zyfwinfo.target.bin" "$NEW_SEQ" "Generated target zyfwinfo"

# Re-verify the payloads immediately before committing the higher sequence.
verify_initramfs_readback "$TARGET_KERNEL"
verify_volume_prefix "$TARGET_ROOTFS" "$WORK/empty-rootfs.bin" "ROOTFS_PLACEHOLDER_FINAL"
verify_volume_prefix "$TARGET_ZYDEFAULT" "$ZYDEFAULT_SOURCE" "ZYDEFAULT_FINAL"

say "[11] FINAL COMMIT: writing boot-switch zyfwinfo last"
STAGE="committing_boot_switch"

ubiupdatevol "$TARGET_ZYFW" "$WORK/zyfwinfo.target.bin" >/dev/null || \
	fail "could not write final target zyfwinfo"

sync
sleep 1

dd if="$TARGET_ZYFW" of="$WORK/zyfwinfo.final.bin" bs=1024 count=1 >/dev/null 2>&1 || \
	fail "could not read final target zyfwinfo"

verify_zyfwinfo_file "$WORK/zyfwinfo.final.bin" "$NEW_SEQ" "Final committed target zyfwinfo"

BOOT_SWITCH_COMMITTED=1
STAGE="boot_switch_committed"
say "BOOT_SWITCH_COMMIT=VERIFIED"

say "[12] Final sync and staged-bank diagnosis"

sync
sync

log_ubi_state "After inactive-bank staging"

say ""
say "===== final staged bank summary ====="
say "ACTIVE_MTD=mtd$ACTIVE_MTD"
say "TARGET_MTD=mtd$TARGET_MTD"
say "TARGET_NAME=$TARGET_NAME"
say "TARGET_KERNEL=$TARGET_KERNEL"
say "TARGET_ROOTFS=$TARGET_ROOTFS"
say "TARGET_ZYFW=$TARGET_ZYFW"
say "TARGET_ZYDEFAULT=$TARGET_ZYDEFAULT"
say "EXPECTED_NEXT_BOOT=ubootmod initramfs FIT from inactive stock bank"

say "=============================================="
say "SUCCESS: initramfs staging complete"
say "Temporary initramfs FIT has been written."
say "Boot switch method: inactive-bank rich zyfwinfo sequence."
say "No sys atsw was used."
say "No sys seqnum was used."
say "No sys atsh was used."
say "Target bank: mtd$TARGET_MTD / $TARGET_NAME"
say "New zyfwinfo sequence: $ACTIVE_SEQ -> $NEW_SEQ"
say "New zyfwinfo mode: $ZYFWINFO_MODE"
say "New zyfwinfo checksum: 0x$(printf '%04x' "$CHECKSUM")"
say "fip action: $FIP_ACTION"
say "fip current sha: ${FIP_CURRENT_HASH:-unknown}"
say "fip target sha:  ${FIP_TARGET_HASH:-unknown}"
say "zloader action: $ZLOADER_ACTION"
say "zloader before: $ZLOADER_CURRENT_STRING"
say "zloader current sha: ${ZLOADER_CURRENT_HASH:-unknown}"
say "zloader target sha:  ${ZLOADER_TARGET_HASH:-unknown}"
say "No final ubootmod NAND conversion was done in this starter."
say "The ubootmod initramfs will perform the unattended final conversion after reboot."
say "Log: $LOG"
say "Please wait for two minutes before accessing router at 192.168.1.1"
say "=============================================="

STAGE="staging_complete"

if [ "$NO_REBOOT" = "1" ]; then
	say "NO_REBOOT=1 set. Not rebooting."
	say "Do not run sys atsh/sys seqnum before reboot."
	say "FIP planned action was: $FIP_ACTION"
	say "Zloader planned action was: $ZLOADER_ACTION"
	say "FIP/zloader replacement is NOT applied when NO_REBOOT=1."
	say "Manual raw check:"
	say "dd if=$TARGET_ZYFW of=/tmp/initramfs_final_zyfwinfo_check.bin bs=1024 count=1 2>/dev/null; hexdump -C /tmp/initramfs_final_zyfwinfo_check.bin"
	say "You can also run read-only diagnosis:"
	say "$0 --diagnose"
	exit 0
fi

say "Boot-chain writes are disabled for this unattended stock-side first hop."
sync

STAGE="rebooting_to_staged_initramfs"
say "Rebooting into the staged ubootmod initramfs in 5 seconds..."
sleep 5
force_reboot_now
