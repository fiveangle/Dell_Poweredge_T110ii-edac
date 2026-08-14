#!/bin/sh
# Guarded front-end for Dell firmware-mediated correctable-memory EINJ.
# Dry-run is the default. This never loads modules or remounts debugfs.

set -eu

einj_dir=/sys/kernel/debug/apei/einj
confirmation='INJECT A CORRECTABLE MEMORY ERROR'
execute=0
confirmed=

usage()
{
	printf 'Dry run: %s\n' "$0" >&2
	printf 'Execute: %s --execute --confirm "%s"\n' "$0" "$confirmation" >&2
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
		-h|--help) usage ;;
		*) usage ;;
	esac
done

for node in available_error_type error_type error_inject; do
	[ -e "$einj_dir/$node" ] || {
		printf 'Refusing: %s is unavailable. Run ecc_preflight.sh first.\n' "$einj_dir/$node" >&2
		exit 1
	}
done

grep -Eq '^0x0*8([[:space:]]|$)' "$einj_dir/available_error_type" || {
	printf '%s\n' 'Refusing: firmware does not advertise Memory Correctable (0x8).' >&2
	exit 1
}

printf '%s\n' 'Firmware advertises Memory Correctable (0x8).'
printf '%s\n' 'This legacy Dell EINJ interface selects its target internally.'
printf '%s\n' 'EDAC counters before injection:'
for counter in ce_count ue_count; do
	printf '%s: ' "$counter"
	cat "/sys/devices/system/edac/mc/mc0/$counter"
done

if [ "$execute" -eq 0 ]; then
	printf '%s\n' 'Dry run only; no EINJ controls were written.'
	exit 0
fi

[ "$confirmed" = "$confirmation" ] || usage
if [ ! -w "$einj_dir/error_type" ] || [ ! -w "$einj_dir/error_inject" ]; then
	printf '%s\n' 'Refusing: EINJ controls are not writable (debugfs may be read-only).' >&2
	exit 1
fi

printf '%s\n' '0x8' > "$einj_dir/error_type"
printf '%s\n' '1' > "$einj_dir/error_inject"

printf '%s\n' 'Injection command completed. Check EDAC counters and kernel/BMC logs.'
for counter in ce_count ue_count; do
	printf '%s: ' "$counter"
	cat "/sys/devices/system/edac/mc/mc0/$counter"
done
