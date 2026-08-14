#!/bin/sh
# Idempotently configure GHES-backed EDAC reporting on the Dell PowerEdge T110 II.

set -eu

force_parameter=ghes.edac_force_enable=1
blacklist_parameter=modprobe.blacklist=ie31200_edac
state_dir=/var/lib/ghes-edac-deployment
backup_dir=/var/backups/ghes-edac
grub_snippet=/etc/default/grub.d/99-ghes-edac.cfg
install_packages=1
force_platform=0

usage()
{
	cat <<'EOF'
Usage:
  configure-ghes-edac.sh check [--force]
  configure-ghes-edac.sh apply [--force] [--no-install-packages]
  configure-ghes-edac.sh rollback
  configure-ghes-edac.sh status

check     Read-only platform and kernel compatibility checks.
apply     Install rasdaemon/sqlite3, configure the boot parameters, and
          refresh the detected Proxmox bootloader. Does not reboot.
rollback  Remove only configuration managed by this script and refresh.
status    Show configured and running state without changing anything.

--force   Permit check/apply on hardware other than a Dell PowerEdge T110 II.
          This bypasses only the DMI platform check; all other checks remain.
EOF
}

say()
{
	printf '%s\n' "$*"
}

die()
{
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

need_root()
{
	[ "$(id -u)" -eq 0 ] || die 'this action must run as root'
}

has_token()
{
	line=$1
	token=$2
	case " $line " in
		*" $token "*) return 0 ;;
		*) return 1 ;;
	esac
}

detect_boot_method()
{
	if command -v proxmox-boot-tool >/dev/null 2>&1 \
		&& [ -s /etc/kernel/proxmox-boot-uuids ] \
		&& [ -f /etc/kernel/cmdline ] \
		&& proxmox-boot-tool status --quiet >/dev/null 2>&1; then
		printf '%s\n' proxmox-boot-tool
	elif command -v update-grub >/dev/null 2>&1 && [ -f /etc/default/grub ]; then
		printf '%s\n' grub
	else
		return 1
	fi
}

kernel_config_path()
{
	path=/boot/config-$(uname -r)
	[ -r "$path" ] || path=/proc/config.gz
	printf '%s\n' "$path"
}

config_has()
{
	config=$1
	setting=$2
	case $config in
		*.gz) gzip -cd "$config" 2>/dev/null | grep -qx "$setting" ;;
		*) grep -qx "$setting" "$config" 2>/dev/null ;;
	esac
}

hardware_summary()
{
	if command -v dmidecode >/dev/null 2>&1; then
		vendor=$(dmidecode -s system-manufacturer 2>/dev/null | sed -n '1p')
		product=$(dmidecode -s system-product-name 2>/dev/null | sed -n '1p')
	else
		vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
		product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
	fi
	printf '%s|%s\n' "$vendor" "$product"
}

check_platform()
{
	failures=0
	hardware=$(hardware_summary)
	vendor=${hardware%%|*}
	product=${hardware#*|}
	say "System: ${vendor:-unknown} ${product:-unknown}"
	case "$vendor $product" in
		*Dell*PowerEdge*T110*II*) say 'PASS: expected Dell PowerEdge T110 II platform' ;;
		*)
			if [ "$force_platform" -eq 1 ]; then
				say 'WARNING: unsupported platform accepted by explicit --force override'
			else
				say 'FAIL: this toolkit is restricted to the Dell PowerEdge T110 II (use --force to override at your own risk)'
				failures=$((failures + 1))
			fi
			;;
	esac

	for table in HEST EINJ; do
		if [ -r "/sys/firmware/acpi/tables/$table" ]; then
			say "PASS: ACPI $table table is present"
		else
			say "FAIL: ACPI $table table is unavailable"
			failures=$((failures + 1))
		fi
	done

	config=$(kernel_config_path)
	if [ -r "$config" ]; then
		say "Kernel config: $config"
		for setting in CONFIG_ACPI_APEI_GHES=y CONFIG_EDAC=y CONFIG_EDAC_GHES=y; do
			if config_has "$config" "$setting"; then
				say "PASS: $setting"
			else
				say "FAIL: $setting is not enabled"
				failures=$((failures + 1))
			fi
		done
	else
		say 'FAIL: running kernel configuration is unavailable'
		failures=$((failures + 1))
	fi

	if boot_method=$(detect_boot_method); then
		say "PASS: detected boot configuration method: $boot_method"
	else
		say 'FAIL: neither a configured proxmox-boot-tool setup nor GRUB was detected'
		failures=$((failures + 1))
	fi

	if command -v systemctl >/dev/null 2>&1; then
		say 'PASS: systemd is available'
	else
		say 'FAIL: systemctl is unavailable'
		failures=$((failures + 1))
	fi

	[ "$failures" -eq 0 ] || die "$failures compatibility check(s) failed"
	say 'Compatibility checks passed.'
}

write_state()
{
	mkdir -p "$state_dir"
	{
		printf 'boot_method=%s\n' "$1"
		printf 'added_force=%s\n' "$2"
		printf 'added_blacklist=%s\n' "$3"
	} > "$state_dir/state.new"
	chmod 0600 "$state_dir/state.new"
	mv "$state_dir/state.new" "$state_dir/state"
}

read_state_value()
{
	key=$1
	[ -r "$state_dir/state" ] || return 1
	sed -n "s/^${key}=//p" "$state_dir/state" | sed -n '1p'
}

configure_proxmox_boot_tool()
{
	current=$(tr '\n' ' ' < /etc/kernel/cmdline | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
	updated=$current
	added_force=0
	added_blacklist=0
	if ! has_token "$updated" "$force_parameter"; then
		updated="$updated $force_parameter"
		added_force=1
	fi
	if ! has_token "$updated" "$blacklist_parameter"; then
		updated="$updated $blacklist_parameter"
		added_blacklist=1
	fi
	if [ -r "$state_dir/state" ] \
		&& [ "$(read_state_value boot_method)" = proxmox-boot-tool ]; then
		[ "$(read_state_value added_force)" = 1 ] && added_force=1
		[ "$(read_state_value added_blacklist)" = 1 ] && added_blacklist=1
	fi

	mkdir -p "$backup_dir"
	stamp=$(date +%Y%m%dT%H%M%S)
	cp -a /etc/kernel/cmdline "$backup_dir/kernel-cmdline.$stamp"
	tmp=$(mktemp /etc/kernel/cmdline.XXXXXX)
	trap 'rm -f "$tmp"' EXIT HUP INT TERM
	printf '%s\n' "$updated" > "$tmp"
	chmod 0644 "$tmp"
	mv "$tmp" /etc/kernel/cmdline
	trap - EXIT HUP INT TERM
	write_state proxmox-boot-tool "$added_force" "$added_blacklist"
	proxmox-boot-tool refresh
}

configure_grub()
{
	mkdir -p "$backup_dir" /etc/default/grub.d
	if [ -e "$grub_snippet" ]; then
		cp -a "$grub_snippet" "$backup_dir/99-ghes-edac.cfg.$(date +%Y%m%dT%H%M%S)"
	fi
	extra=
	for parameter in "$force_parameter" "$blacklist_parameter"; do
		found=0
		for file in /etc/default/grub /etc/default/grub.d/*.cfg; do
			[ -f "$file" ] || continue
			[ "$file" = "$grub_snippet" ] && continue
			if grep -Fq -- "$parameter" "$file"; then
				found=1
				break
			fi
		done
		[ "$found" -eq 1 ] || extra="${extra}${extra:+ }$parameter"
	done
	if [ -z "$extra" ]; then
		rm -f "$grub_snippet"
		write_state grub 0 0
		update-grub
		return
	fi
	tmp=$(mktemp /etc/default/grub.d/99-ghes-edac.cfg.XXXXXX)
	trap 'rm -f "$tmp"' EXIT HUP INT TERM
	cat > "$tmp" <<EOF
# Managed by configure-ghes-edac.sh.
GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE_LINUX_DEFAULT:+\$GRUB_CMDLINE_LINUX_DEFAULT }$extra"
EOF
	chmod 0644 "$tmp"
	mv "$tmp" "$grub_snippet"
	trap - EXIT HUP INT TERM
	write_state grub 1 1
	update-grub
}

install_dependencies()
{
	missing=
	for package in rasdaemon sqlite3; do
		dpkg-query -W -f='${db:Status-Status}\n' "$package" 2>/dev/null | grep -qx 'installed' \
			|| missing="$missing $package"
	done
	if [ -n "$missing" ]; then
		[ "$install_packages" -eq 1 ] \
			|| die "required package(s) missing:$missing (omit --no-install-packages to install them)"
		say "Installing required package(s):$missing"
		# Deliberately do not run apt-get update; repository policy remains with the administrator.
		# Installing an already-present package is harmless and avoids unsafe word splitting.
		DEBIAN_FRONTEND=noninteractive apt-get install -y rasdaemon sqlite3
	fi
	systemctl enable --now rasdaemon.service
}

apply_configuration()
{
	need_root
	check_platform
	install_dependencies
	boot_method=$(detect_boot_method) || die 'boot configuration method became unavailable'
	case $boot_method in
		proxmox-boot-tool) configure_proxmox_boot_tool ;;
		grub) configure_grub ;;
		*) die "unsupported boot method: $boot_method" ;;
	esac
	say 'Configuration applied successfully.'
	say 'Reboot is required. This script does not reboot automatically.'
}

remove_token()
{
	line=$1
	token=$2
	result=
	for word in $line; do
		[ "$word" = "$token" ] && continue
		result="${result}${result:+ }$word"
	done
	printf '%s\n' "$result"
}

rollback_configuration()
{
	need_root
	[ -r "$state_dir/state" ] || die "no managed state found at $state_dir/state"
	boot_method=$(read_state_value boot_method)
	case $boot_method in
		proxmox-boot-tool)
			[ -f /etc/kernel/cmdline ] || die '/etc/kernel/cmdline is missing'
			current=$(tr '\n' ' ' < /etc/kernel/cmdline | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
			if [ "$(read_state_value added_force)" = 1 ]; then
				current=$(remove_token "$current" "$force_parameter")
			fi
			if [ "$(read_state_value added_blacklist)" = 1 ]; then
				current=$(remove_token "$current" "$blacklist_parameter")
			fi
			tmp=$(mktemp /etc/kernel/cmdline.XXXXXX)
			trap 'rm -f "$tmp"' EXIT HUP INT TERM
			printf '%s\n' "$current" > "$tmp"
			chmod 0644 "$tmp"
			mv "$tmp" /etc/kernel/cmdline
			trap - EXIT HUP INT TERM
			proxmox-boot-tool refresh
			;;
		grub)
			[ -e "$grub_snippet" ] && rm -f "$grub_snippet"
			update-grub
			;;
		*) die "unsupported saved boot method: $boot_method" ;;
	esac
	rm -f "$state_dir/state"
	say 'Managed configuration removed. Reboot is required.'
}

show_status()
{
	printf 'Running kernel: '
	uname -r
	printf 'Running command line: '
	cat /proc/cmdline
	if boot_method=$(detect_boot_method); then
		say "Boot method: $boot_method"
	else
		say 'Boot method: undetected'
	fi
	if [ -r /etc/kernel/cmdline ]; then
		printf 'Configured kernel command line: '
		cat /etc/kernel/cmdline
	fi
	if [ -r "$state_dir/state" ]; then
		say "Managed state: $state_dir/state"
		cat "$state_dir/state"
	else
		say 'Managed state: absent'
	fi
	for parameter in "$force_parameter" "$blacklist_parameter"; do
		if has_token "$(cat /proc/cmdline)" "$parameter"; then
			say "RUNNING: $parameter"
		else
			say "NOT RUNNING: $parameter"
		fi
	done
	if [ -r /sys/devices/system/edac/mc/mc0/mc_name ]; then
		printf 'EDAC mc0 driver: '
		cat /sys/devices/system/edac/mc/mc0/mc_name
	else
		say 'EDAC mc0 driver: unavailable'
	fi
	if systemctl is-active --quiet rasdaemon.service 2>/dev/null; then
		say 'rasdaemon: active'
	else
		say 'rasdaemon: inactive or unavailable'
	fi
}

[ "$#" -ge 1 ] || { usage; exit 2; }
action=$1
shift

case $action in
	status|rollback)
		[ "$#" -eq 0 ] || { usage; exit 2; }
		;;
	check|apply)
		while [ "$#" -gt 0 ]; do
			case $1 in
				--force) force_platform=1 ;;
				--no-install-packages)
					[ "$action" = apply ] || { usage; exit 2; }
					install_packages=0
					;;
				*) usage; exit 2 ;;
			esac
			shift
		done
		;;
	*) usage; exit 2 ;;
esac

case $action in
	check) check_platform ;;
	apply) apply_configuration ;;
	rollback) rollback_configuration ;;
	status) show_status ;;
esac
