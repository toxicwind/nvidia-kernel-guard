#!/usr/bin/env bash
# Install nvidia-kernel-guard: /usr/bin/nkg, pacman hook, boot audit service,
# post-transaction auto-fix path unit.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "run as root (sudo ./install.sh)" >&2
    exit 1
fi

install -Dm755 "$SRC/bin/nkg" /usr/bin/nkg
install -Dm644 "$SRC/hooks/nvidia-kernel-guard.hook" /etc/pacman.d/hooks/nvidia-kernel-guard.hook
install -Dm644 "$SRC/systemd/nvidia-kernel-guard.service" /usr/lib/systemd/system/nvidia-kernel-guard.service
install -Dm644 "$SRC/systemd/nvidia-kernel-guard-autofix.service" /usr/lib/systemd/system/nvidia-kernel-guard-autofix.service
install -Dm644 "$SRC/systemd/nvidia-kernel-guard.path" /usr/lib/systemd/system/nvidia-kernel-guard.path
# Don't clobber an existing config (it may carry local choices).
if [[ ! -f /etc/nvidia-kernel-guard.conf ]]; then
    install -Dm644 "$SRC/config/nvidia-kernel-guard.conf" /etc/nvidia-kernel-guard.conf
else
    echo "keeping existing /etc/nvidia-kernel-guard.conf"
fi

systemctl daemon-reload
systemctl enable --now nvidia-kernel-guard.service || true
systemctl enable --now nvidia-kernel-guard.path || true

echo "installed. Current coverage:"
/usr/bin/nkg audit || true
