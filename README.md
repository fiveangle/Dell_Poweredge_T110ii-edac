# Dell PowerEdge T110 II GHES/EDAC toolkit

This toolkit configures a Dell PowerEdge T110 II to record firmware-first corrected-memory events through Linux EDAC and rasdaemon:

```text
firmware/APEI GHES -> ghes_edac -> ras:mc_event -> rasdaemon -> ras-mc-ctl
```

It is intended for a freshly installed, fully updated Debian 13-based host such as Proxmox VE 9.x. Run the acceptance test after installation and after any kernel change that could affect EDAC or GHES behavior.

## Requirements

- Dell PowerEdge T110 II with ECC memory
- Fully updated Debian 13-based installation with working package repositories
- A configured `proxmox-boot-tool` or GRUB bootloader (field-tested only with Proxmox VE 9.x using UEFI and `proxmox-boot-tool`)
- Root shell
- No running or automatically starting guests during the acceptance test

The configuration script installs `rasdaemon` and `sqlite3` when needed. It does not run `apt-get update`; update package metadata according to local policy first.

**NOTES**: This toolkit may enable rasdaemon reporting of firmware-detected ECC errors on other systems with compatible firmware-first GHES support, but no other platform has been validated. **Use `--force` on platforms other than the PowerEdge T110 II only at your own risk.** In the tested kernel, `ghes_edac` is not normally enabled on this Dell platform, while the native `ie31200_edac` driver claims the EDAC memory controller. This toolkit blacklists `ie31200_edac` and force-enables the existing firmware-first GHES-to-EDAC reporting path. Validate any vendor management or monitoring software separately after making this change.

Tested on Dell PowerEdge T110 II:
- _Kernel_: `Linux 7.0.14-4-pve #1 SMP PREEMPT_DYNAMIC PMX 7.0.14-4 (2026-07-07T07:27Z) GNU/Linux`
- _Dell BMC/IPMI firmware versions_: `1.70, 1.92, and 1.95`
- _Bootloader_: `proxmox-boot-tool (UEFI)`

_**Use on any other configuration at your own risk !**_

## Included scripts

- `configure-ghes-edac.sh` — compatibility check, installation, status, and rollback
- `verify-ghes-edac.sh` — read-only post-reboot verification
- `acceptance-test-ghes-edac.sh` — guarded end-to-end correctable-ECC test
- `einj_correctable_test.sh` — low-level helper used by the acceptance test
- `ecc_preflight.sh` — optional read-only ECC and ACPI EINJ inventory

## Safety behavior

The deployment manages only these kernel parameters:

```text
ghes.edac_force_enable=1
modprobe.blacklist=ie31200_edac
```

It preserves the installer-generated kernel command line, detects `proxmox-boot-tool` or GRUB, makes timestamped backups under `/var/backups/ghes-edac/`, and never reboots automatically.

Error injection is disabled during normal operation. The acceptance test is a dry run by default and requires an exact confirmation phrase before injecting one ACPI EINJ type `0x8` correctable-memory event. It never selects an uncorrectable error type.

## 1. Preflight and installation

From the toolkit directory, run:

```sh
./configure-ghes-edac.sh check
./configure-ghes-edac.sh status
```

Do not continue if the compatibility check fails. Apply the configuration with:

```sh
./configure-ghes-edac.sh apply
```

On an unvalidated platform, both preflight and deployment require an explicit override:

```sh
./configure-ghes-edac.sh check --force
./configure-ghes-edac.sh apply --force
```

`--force` bypasses only the Dell PowerEdge T110 II DMI check. ACPI HEST/EINJ tables, GHES/EDAC kernel support, a supported bootloader, and systemd are still required. Review the detected native EDAC driver and boot configuration before proceeding.

This command:

1. Validates the platform, ACPI tables, and running kernel configuration.
2. Installs `rasdaemon` and `sqlite3` if missing.
3. Enables and starts `rasdaemon.service`.
4. Adds the two managed kernel parameters without replacing other parameters.
5. Refreshes all configured Proxmox ESPs or the GRUB configuration.

If you desire to handle package installation separately, use:

```sh
./configure-ghes-edac.sh apply --no-install-packages
```

That mode fails if either required package is absent.

Review the result before rebooting:

```sh
./configure-ghes-edac.sh status
```

For a `proxmox-boot-tool` installation, also inspect:

```sh
proxmox-boot-tool status
cat /etc/kernel/cmdline
```

Then reboot the host manually:

```sh
reboot
```

## 2. Post-reboot verification

Keep all guests stopped and run:

```sh
./verify-ghes-edac.sh
```

The verifier makes no changes. It checks that:

- Both managed kernel parameters are active.
- `ghes_edac` owns EDAC memory controller `mc0`.
- `ie31200_edac` is not loaded. Validate any vendor monitoring tools that expect the native EDAC driver separately.
- Rasdaemon is active and monitoring its private `ras:mc_event` tracepoint.
- EDAC counters and rasdaemon's SQLite database are readable.

Rasdaemon may take about five minutes to finish probing unavailable tracepoints (CXL) after boot. The verifier waits up to 360 seconds by default. To allow more time:

```sh
./verify-ghes-edac.sh --wait-seconds 600
```

Do not proceed to injection unless verification passes.

## 3. Correctable-ECC acceptance test

Run the dry test first:

```sh
./acceptance-test-ghes-edac.sh
```

This repeats the post-reboot verification but does not load EINJ or inject an error.

To inject exactly one correctable-memory event:

```sh
./acceptance-test-ghes-edac.sh \
  --execute \
  --confirm 'INJECT ONE CORRECTABLE ECC ERROR'
```

The acceptance test succeeds only when:

- EDAC `ce_count` increases by exactly one.
- EDAC `ue_count` remains unchanged.
- GHES reports that hardware corrected the error.
- Rasdaemon inserts a new `mc_event` database row.

Review the stored event with:

```sh
ras-mc-ctl --errors
```

The T110ii server's firmware may report a generic APEI location rather than a specific DIMM. A valid event can therefore appear as `unknown memory`, increment `ce_noinfo_count`, and leave per-DIMM counters unchanged.

Once the test passes, the host is ready for workloads. Do not automate error injection during routine deployment or boot.

## Status and rollback

Show current and configured state at any time:

```sh
./configure-ghes-edac.sh status
```
The standard rasdaemon utility should report the same event(s):

```text
# ras-mc-ctl --summary
Memory controller events summary:
        Corrected on DIMM Label(s): 'unknown memory' location: 0:-1:-1:-1 errors: 1
```
        
To remove only the configuration recorded as managed by this toolkit:

```sh
./configure-ghes-edac.sh rollback
./configure-ghes-edac.sh status
reboot
```

Rollback refreshes the detected bootloader but does not reboot. Backups remain in `/var/backups/ghes-edac/`.

## Automation

Preflight and installation are safe to invoke from a provisioning script:

```sh
./configure-ghes-edac.sh check && ./configure-ghes-edac.sh apply
```

An administrator-controlled reboot must separate installation from verification. All scripts return zero on success and nonzero on failure.

Do not include `acceptance-test-ghes-edac.sh --execute` in unattended configuration management.

## Proxmox reference

Proxmox documents `/etc/kernel/cmdline` with `proxmox-boot-tool refresh` for synchronized ESP installations and `/etc/default/grub` with `update-grub` for GRUB installations:

<https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf>

Enjoy !

-=dave
