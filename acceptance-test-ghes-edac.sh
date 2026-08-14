#!/bin/sh
# Guarded end-to-end correctable-only ECC acceptance test.

set -eu

confirmation='INJECT ONE CORRECTABLE ECC ERROR'
execute=0
confirmed=
wait_seconds=60
self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
database=/var/lib/rasdaemon/ras-mc_event.db

usage()
{
	cat >&2 <<EOF
Dry run: $0
Execute: $0 --execute --confirm '$confirmation'
Optional: --wait-seconds N (default: $wait_seconds)
EOF
	exit 2
}

while [ "$#" -gt 0 ]; do
	case $1 in
		--execute) execute=1; shift ;;
		--confirm)
			[ "$#" -ge 2 ] || usage
			confirmed=$2
			shift 2
			;;
		--wait-seconds)
			[ "$#" -ge 2 ] || usage
			wait_seconds=$2
			shift 2
			;;
		*) usage ;;
	esac
done

case $wait_seconds in
	''|*[!0-9]*) usage ;;
esac

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'ERROR: run as root' >&2; exit 1; }
[ -x "$self_dir/verify-ghes-edac.sh" ] || { printf '%s\n' 'ERROR: verifier is missing' >&2; exit 1; }
[ -x "$self_dir/einj_correctable_test.sh" ] || { printf '%s\n' 'ERROR: EINJ helper is missing' >&2; exit 1; }

"$self_dir/verify-ghes-edac.sh"

if [ "$execute" -eq 0 ]; then
	printf '%s\n' 'Dry run passed. No module was loaded and no error was injected.'
	printf "To execute: %s --execute --confirm '%s'\n" "$0" "$confirmation"
	exit 0
fi

[ "$confirmed" = "$confirmation" ] || usage

einj_was_loaded=0
[ -d /sys/module/einj ] && einj_was_loaded=1
cleanup()
{
	if [ "$einj_was_loaded" -eq 0 ]; then
		modprobe -r einj >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT HUP INT TERM

modprobe einj
einj_dir=/sys/kernel/debug/apei/einj
if [ ! -w "$einj_dir/error_type" ] || [ ! -w "$einj_dir/error_inject" ]; then
	printf '%s\n' 'ERROR: EINJ controls are not writable; debugfs must be mounted read-write' >&2
	exit 1
fi

ce_before=$(cat /sys/devices/system/edac/mc/mc0/ce_count)
ue_before=$(cat /sys/devices/system/edac/mc/mc0/ue_count)
db_before=$(sqlite3 "$database" 'SELECT count(*) FROM mc_event;')
start_time=$(date '+%Y-%m-%d %H:%M:%S')

"$self_dir/einj_correctable_test.sh" --execute \
	--confirm 'INJECT A CORRECTABLE MEMORY ERROR'

ce_after=$(cat /sys/devices/system/edac/mc/mc0/ce_count)
ue_after=$(cat /sys/devices/system/edac/mc/mc0/ue_count)

[ "$ce_after" -eq $((ce_before + 1)) ] || {
	printf 'ERROR: expected CE count %s, observed %s\n' "$((ce_before + 1))" "$ce_after" >&2
	exit 1
}
[ "$ue_after" -eq "$ue_before" ] || {
	printf 'ERROR: UE count changed from %s to %s\n' "$ue_before" "$ue_after" >&2
	exit 1
}

elapsed=0
db_after=$db_before
while [ "$elapsed" -lt "$wait_seconds" ]; do
	db_after=$(sqlite3 "$database" 'SELECT count(*) FROM mc_event;')
	[ "$db_after" -ge $((db_before + 1)) ] && break
	sleep 2
	elapsed=$((elapsed + 2))
done

[ "$db_after" -ge $((db_before + 1)) ] || {
	printf 'ERROR: rasdaemon did not store a new mc_event within %ss\n' "$wait_seconds" >&2
	exit 1
}

if journalctl -k -b --since "$start_time" --no-pager \
	| grep -q 'It has been corrected by h/w'; then
	printf '%s\n' 'PASS: GHES says the error was corrected by hardware.'
else
	printf '%s\n' 'ERROR: matching GHES corrected-by-hardware message was not found' >&2
	exit 1
fi

printf 'PASS: EDAC CE count increased from %s to %s.\n' "$ce_before" "$ce_after"
printf 'PASS: EDAC UE count remained %s.\n' "$ue_after"
printf 'PASS: rasdaemon mc_event rows increased from %s to %s.\n' "$db_before" "$db_after"
printf '%s\n' 'End-to-end correctable ECC acceptance test passed.'
