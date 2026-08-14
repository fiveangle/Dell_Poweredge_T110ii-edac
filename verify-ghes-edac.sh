#!/bin/sh
# Read-only post-reboot verification for the GHES -> EDAC -> rasdaemon path.

set -eu

wait_seconds=360
force_parameter=ghes.edac_force_enable=1
blacklist_parameter=modprobe.blacklist=ie31200_edac
trace_root=/sys/kernel/tracing/instances/rasdaemon
database=/var/lib/rasdaemon/ras-mc_event.db

usage()
{
	printf 'Usage: %s [--wait-seconds N]\n' "$0" >&2
	exit 2
}

pass()
{
	printf 'PASS: %s\n' "$*"
}

fail()
{
	printf 'FAIL: %s\n' "$*" >&2
	failures=$((failures + 1))
}

has_running_token()
{
	case " $(cat /proc/cmdline) " in
		*" $1 "*) return 0 ;;
		*) return 1 ;;
	esac
}

while [ "$#" -gt 0 ]; do
	case $1 in
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

failures=0
printf 'Running kernel: '
uname -r

for parameter in "$force_parameter" "$blacklist_parameter"; do
	if has_running_token "$parameter"; then
		pass "running command line contains $parameter"
	else
		fail "running command line lacks $parameter"
	fi
done

if [ -r /sys/devices/system/edac/mc/mc0/mc_name ] \
	&& [ "$(cat /sys/devices/system/edac/mc/mc0/mc_name)" = ghes_edac ]; then
	pass 'ghes_edac owns EDAC mc0'
else
	fail 'ghes_edac does not own EDAC mc0'
fi

if [ ! -d /sys/module/ie31200_edac ]; then
	pass 'ie31200_edac is not loaded'
else
	fail 'ie31200_edac is loaded'
fi

if journalctl -k -b --no-pager 2>/dev/null | grep -q 'Force-loading ghes_edac'; then
	pass 'kernel log confirms forced ghes_edac activation'
else
	fail 'kernel log lacks forced ghes_edac activation message'
fi

if systemctl is-active --quiet rasdaemon.service; then
	pass 'rasdaemon service is active'
else
	fail 'rasdaemon service is not active'
fi

elapsed=0
while [ "$elapsed" -lt "$wait_seconds" ]; do
	if journalctl -u rasdaemon.service -b --no-pager 2>/dev/null \
		| grep -q 'Listening to events for cpus'; then
		break
	fi
	sleep 2
	elapsed=$((elapsed + 2))
done

if journalctl -u rasdaemon.service -b --no-pager 2>/dev/null \
	| grep -q 'Listening to events for cpus'; then
	pass "rasdaemon reached its event loop (waited up to ${elapsed}s)"
else
	fail "rasdaemon did not reach its event loop within ${wait_seconds}s"
fi

if [ -r "$trace_root/events/ras/mc_event/enable" ] \
	&& [ "$(cat "$trace_root/events/ras/mc_event/enable")" = 1 ]; then
	pass "rasdaemon's private ras:mc_event tracepoint is enabled"
else
	fail "rasdaemon's private ras:mc_event tracepoint is not enabled"
fi

for counter in ce_count ue_count; do
	path=/sys/devices/system/edac/mc/mc0/$counter
	if [ -r "$path" ]; then
		value=$(cat "$path")
		case $value in
			''|*[!0-9]*) fail "$counter is not numeric" ;;
			*) pass "$counter is readable ($value)" ;;
		esac
	else
		fail "$counter is unavailable"
	fi
done

if command -v sqlite3 >/dev/null 2>&1 \
	&& [ -r "$database" ] \
	&& sqlite3 "$database" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='mc_event';" 2>/dev/null \
		| grep -qx 1; then
	count=$(sqlite3 "$database" 'SELECT count(*) FROM mc_event;')
	pass "rasdaemon database and mc_event table are readable ($count existing event(s))"
else
	fail 'rasdaemon SQLite database or mc_event table is unavailable'
fi

if [ "$failures" -ne 0 ]; then
	printf '%s verification check(s) failed.\n' "$failures" >&2
	exit 1
fi

printf '%s\n' 'GHES/EDAC/rasdaemon verification passed.'
