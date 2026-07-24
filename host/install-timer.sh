#!/usr/bin/env bash
# Install the rotation script and systemd user timer on the application host.
# Run as the service account that will own the token, not as root.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.akeyless-uid"
units="$HOME/.config/systemd/user"

# Resolve the akeyless CLI here, in the installer shell (which has it on PATH),
# and pin it for the service through a drop-in. systemd user services do not
# inherit the login shell PATH, so the script's PATH lookup would fail in-unit.
BIN="$(command -v akeyless || true)"
if [ -z "$BIN" ]; then
  echo "akeyless CLI not found on PATH; install it before running this." >&2
  exit 1
fi

mkdir -p "$dest/token" "$units"
chmod 700 "$dest" "$dest/token"

install -m 700 "$here/rotate-uid-token.sh" "$dest/rotate-uid-token.sh"
install -m 644 "$here/systemd/akeyless-uid-rotate.service" "$units/akeyless-uid-rotate.service"
install -m 644 "$here/systemd/akeyless-uid-rotate.timer" "$units/akeyless-uid-rotate.timer"

mkdir -p "$units/akeyless-uid-rotate.service.d"
cat > "$units/akeyless-uid-rotate.service.d/exec.conf" <<CONF
[Service]
Environment="AKEYLESS_BIN=$BIN"
CONF

systemctl --user daemon-reload
systemctl --user reset-failed akeyless-uid-rotate.service 2>/dev/null || true
systemctl --user enable --now akeyless-uid-rotate.timer

echo "Installed. Token directory: $dest/token"
echo "Pinned akeyless CLI for the service: $BIN"
echo "Place the bootstrap token at $dest/token/uid-token (0600) if you have not already."
systemctl --user list-timers akeyless-uid-rotate.timer --no-pager
