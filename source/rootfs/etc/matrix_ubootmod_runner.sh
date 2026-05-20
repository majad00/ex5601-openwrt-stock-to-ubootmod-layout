#!/bin/sh
#Written by LUT

DIR="/tmp/matrix-ubootmod"
REQ="$DIR/request"
RUNNING="$DIR/running"
PIDFILE="$DIR/stager.pid"
LOG="$DIR/status.log"

STAGER="/tmp/matrix_boot_initramfs.sh"
STAGER_LOG="/tmp/matrix_project_c_boot_initramfs.log"

mkdir -p "$DIR"

write_ready() {
	cat > "$LOG" <<EOF
===== U-Boot Layout =====
Matrix U-Boot layout runner ready.
Waiting for LuCI request.

Runner:
  $0

Stager:
  $STAGER

Stager log:
  $STAGER_LOG
EOF
}

write_running_status() {
	pid="$1"

	{
		echo "===== U-Boot Layout ====="
		echo "Project C initramfs staging is running."
		echo
		echo "Started by LuCI button."
		echo "Stager PID: $pid"
		echo
		echo "Stager:"
		echo "  $STAGER"
		echo
		echo "Stager log:"
		echo "  $STAGER_LOG"
		echo
		echo "This stage uses the Project C stager."
		echo "The stager itself decides whether to use sysupgrade staging or fail safely."
		echo
		echo "===== stager log tail ====="

		if [ -s "$STAGER_LOG" ]; then
			tail -120 "$STAGER_LOG"
		else
			echo "Waiting for stager log..."
		fi
	} > "$LOG"
}

write_final_status() {
	rc="$1"

	{
		echo "===== U-Boot Layout ====="
		echo "Project C initramfs stager exited."
		echo
		echo "Exit code: $rc"
		echo
		echo "Stager:"
		echo "  $STAGER"
		echo
		echo "Stager log:"
		echo "  $STAGER_LOG"
		echo
		if [ "$rc" = "0" ]; then
			echo "Result:"
			echo "  Stager exited with success."
			echo
			echo "If sysupgrade/reboot has started, the router may boot into initramfs soon."
			echo "Give it a minute or two."
		else
			echo "Result:"
			echo "  Stager failed before completing."
			echo
			echo "No successful staging was reported."
			echo "Check the stager log below."
		fi
		echo
		echo "===== stager log tail ====="

		if [ -s "$STAGER_LOG" ]; then
			tail -160 "$STAGER_LOG"
		else
			echo "No stager log found."
		fi
	} > "$LOG"
}

write_error_status() {
	msg="$1"

	{
		echo "===== U-Boot Layout ====="
		echo "ERROR: $msg"
		echo
		echo "Stager:"
		echo "  $STAGER"
		echo
		echo "Stager log:"
		echo "  $STAGER_LOG"
	} > "$LOG"
}

write_ready

while true; do
	if [ -f "$REQ" ]; then
		rm -f "$REQ"

		if [ -f "$RUNNING" ]; then
			{
				echo "===== U-Boot Layout ====="
				echo "U-Boot layout staging is already running."
				echo
				[ -f "$PIDFILE" ] && echo "Stager PID: $(cat "$PIDFILE" 2>/dev/null)"
				echo
				echo "===== stager log tail ====="
				tail -120 "$STAGER_LOG" 2>/dev/null || echo "No stager log yet."
			} > "$LOG"

			sleep 1
			continue
		fi

		touch "$RUNNING"

		if [ ! -x "$STAGER" ]; then
			write_error_status "$STAGER not found or not executable"
			rm -f "$RUNNING" "$PIDFILE"
			sleep 1
			continue
		fi

		rm -f "$STAGER_LOG"
		rm -f "$PIDFILE"

		{
			echo "===== U-Boot Layout ====="
			echo "Project C initramfs staging started: $(date 2>/dev/null || true)"
			echo
			echo "Starting:"
			echo "  $STAGER"
			echo
			echo "Following:"
			echo "  $STAGER_LOG"
		} > "$LOG"

		"$STAGER" &
		pid="$!"
		echo "$pid" > "$PIDFILE"

		while kill -0 "$pid" 2>/dev/null; do
			write_running_status "$pid"
			sleep 2
		done

		wait "$pid"
		rc="$?"

		write_final_status "$rc"

		rm -f "$RUNNING" "$PIDFILE"
	fi

	sleep 1
done