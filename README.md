# nvidia-kernel-guard

**Every installed kernel gets its NVIDIA driver. No more black screens after a kernel switch.**

You install `linux-cachyos-bore` next to `linux-cachyos`. The new kernel boots.
Your display manager can't light the GPU because the matching
`linux-cachyos-bore-nvidia-open` was never installed. Black screen on every
monitor, and the console getty was already claimed by the display manager —
so there's not even a shell to fix it from. This tool makes that failure
mode impossible.

## How it works

| Layer | What it does |
|---|---|
| `nkg audit` | Maps every installed kernel package to its driver package (`<kernel>-nvidia-open`, with repo probing so it tracks new flavors automatically). Detects **missing** drivers *and* **version skew** (driver installed but not matching the kernel). Reports gaps, exits non-zero. `--json` for scripting. |
| `nkg fix` | Installs every missing/skewed driver package, rebuilds all initramfs images, verifies modules for the running kernel. |
| pacman hook | On any kernel/driver install/upgrade/remove (glob targets: `linux*`, `*nvidia*`), warns **in your face** mid-transaction if a gap opened, and records it. A systemd path unit then runs `nkg autofix`, which installs the missing drivers post-transaction (when `HOOK_AUTOFIX=yes`, the default) — never inside the pacman db lock. |
| boot service | At every boot, verifies the *running* kernel actually has nvidia modules on disk. If not: loud journal entry + `wall` broadcast telling you exactly what to run. |

## Kernel discovery

Kernels are enumerated from **two independent sources**, merged and deduplicated:

1. **pacman**: packages named `linux*` that ship `/boot/vmlinuz-*`.
2. **`/usr/lib/modules/*/vmlinuz`**: catches kernels whose image lives in the
   modules dir (UKI / systemd-boot layouts). The flavor is resolved via the
   `pkgbase` file, falling back to `pacman -Qo`. Orphaned module dirs (stale
   versions with no owning package) are skipped.

## Driver states

| State | Meaning |
|---|---|
| `covered` | driver package installed, version matches kernel |
| `covered-dkms` | `nvidia-open-dkms` installed (builds for every kernel) |
| `skewed` | driver installed but version ≠ kernel version — reinstall |
| `missing-repo` | not installed, but a prebuilt package exists in the repos |
| `missing-unknown` | no prebuilt package known — suggests `nvidia-open-dkms` |

## Install

```bash
git clone https://github.com/toxicwind/nvidia-kernel-guard
cd nvidia-kernel-guard
sudo ./install.sh
```

This installs `/usr/bin/nkg`, the pacman hook, the boot audit service, and the
post-transaction auto-fix path unit. An existing `/etc/nvidia-kernel-guard.conf`
is never clobbered.

## Usage

```bash
nkg audit                 # human-readable coverage table
nkg audit --json          # machine-readable
nkg audit --boot          # also verify the RUNNING kernel has modules
nkg fix                   # install missing/skewed drivers + mkinitcpio -P (asks first)
nkg fix --yes             # no prompt (automation)
```

Config lives at `/etc/nvidia-kernel-guard.conf`:

```ini
DRIVER_FLAVOR=open        # open (nvidia-open, default) or proprietary (nvidia)
AUTO_FIX=no               # yes = `nkg fix` never prompts
HOOK_AUTOFIX=yes          # yes = pacman hook auto-installs missing drivers post-transaction
```

## Tests

Mock-based suite — runs anywhere, no root, no GPU:

```bash
bash tests/run.sh         # 11 tests: missing driver, version skew, multi-flavor,
                          # modules-dir enumeration, orphan skip, dkms fallback,
                          # proprietary flavor, hook warn/clear, autofix gate,
                          # boot check, no-kernel error
```

CI runs shellcheck + the suite on every push.

## The mapping logic

For a kernel package `linux-<flavor>`, the guard probes the repos in order:

1. `linux-<flavor>-nvidia-open` (or `-nvidia` when `DRIVER_FLAVOR=proprietary`)
2. stock-arch special cases (`linux` → `nvidia-open`, `linux-lts` → `nvidia-lts`)
3. if nothing prebuilt exists → tells you to use `nvidia-open-dkms` (the universal fallback that builds for every kernel)

Because it probes instead of hardcoding, new kernel flavors (CachyOS adds them regularly) are handled with zero updates.

## Why not just use DKMS?

`nvidia-open-dkms` *is* a valid answer — one package, builds for every kernel.
Trade-offs:

- **DKMS**: universal, but compiles on every kernel update (slow on big updates, needs headers for every kernel, build can fail).
- **nvidia-kernel-guard + prebuilt**: zero compile time, uses your distro's tested modules, and the guard closes the "forgot the new flavor" gap that prebuilt packages have.

Use the guard if you like prebuilt modules and multiple kernel flavors. Use DKMS if you'd rather compile. The guard will tell you when DKMS is your only option.

## The incident that built this

2026-09-20: a kernel cutover to `linux-cachyos-bore` on an RTX 3090 box.
`sddm` (which `Conflicts=getty@tty1.service`) couldn't render the greeter —
no driver for the new kernel — so: black screen on DP-1/DP-2, no console
fallback. Fixed by installing `linux-cachyos-bore-nvidia-open` and rebuilding
the initramfs. This repo exists so that class of outage can't recur silently.

## Requirements

- Arch-based distro (Arch, CachyOS, EndeavourOS, …)
- `pacman`, `mkinitcpio`, `systemd`
- sudo for `fix` / install

## License

MIT — see [LICENSE](LICENSE).
