#!/bin/sh
# Read-only ECC / EDAC / ACPI EINJ inventory.
# This script does not load modules, mount filesystems, or write to sysfs.

set -u

say_file()
{
	path=$1
	if [ -r "$path" ]; then
		printf '%s: ' "$path"
		cat "$path"
	else
		printf '%s: unavailable\n' "$path"
	fi
}

printf '%s\n' 'ECC injection preflight (read-only)'
printf 'kernel: '
uname -r
printf 'command line: '
cat /proc/cmdline
printf '\n'

if [ -d /sys/devices/system/edac/mc/mc0 ]; then
	say_file /sys/devices/system/edac/mc/mc0/mc_name
	say_file /sys/devices/system/edac/mc/mc0/size_mb
	say_file /sys/devices/system/edac/mc/mc0/ce_count
	say_file /sys/devices/system/edac/mc/mc0/ue_count
	if find /sys/devices/system/edac/mc/mc0 -maxdepth 1 -name 'inject_*' -print | grep -q .; then
		printf '%s\n' 'EDAC driver injection controls: present'
	else
		printf '%s\n' 'EDAC driver injection controls: absent'
	fi
else
	printf '%s\n' 'EDAC memory controller mc0: absent'
fi

if [ -r /sys/firmware/acpi/tables/EINJ ]; then
	printf 'ACPI EINJ table: present (%s bytes)\n' "$(wc -c < /sys/firmware/acpi/tables/EINJ)"
else
	printf '%s\n' 'ACPI EINJ table: absent'
fi

if [ -d /sys/module/einj ]; then
	printf '%s\n' 'einj module: loaded'
else
	printf '%s\n' 'einj module: not loaded'
fi

einj_dir=/sys/kernel/debug/apei/einj
if [ -r "$einj_dir/available_error_type" ]; then
	printf '%s\n' 'Firmware-advertised injection types:'
	cat "$einj_dir/available_error_type"
else
	printf '%s\n' 'EINJ debugfs interface: unavailable'
fi

if [ -d /sys/module/ie31200_edac/parameters ]; then
	printf '%s\n' 'ie31200_edac module parameters:'
	find /sys/module/ie31200_edac/parameters -maxdepth 1 -type f -print
else
	printf '%s\n' 'ie31200_edac module parameters: none'
fi

if modinfo einj >/dev/null 2>&1; then
	printf '%s\n' 'einj kernel module: available'
	modinfo -p einj
else
	printf '%s\n' 'einj kernel module: unavailable'
fi

if modinfo mce-inject >/dev/null 2>&1; then
	printf '%s\n' 'mce-inject kernel module: available (software reporting-path test only)'
else
	printf '%s\n' 'mce-inject kernel module: unavailable'
fi

printf '\n%s\n' 'No state was changed.'
