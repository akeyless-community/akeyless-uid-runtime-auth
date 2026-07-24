#!/usr/bin/env bash
# Rotate the Universal Identity token in place.
#
# Reads the current child token, asks Akeyless for its successor, and atomically
# replaces the on-disk token. After a successful rotation the previous token is
# permanently invalid, so a copy stolen between rotations stops working and the
# theft becomes visible as an authentication failure in the Akeyless audit log.
#
# Run on a timer whose interval is comfortably shorter than the auth method's
# jwt-ttl, so the child token is always refreshed before it can expire.
set -euo pipefail

# systemd user services do not inherit the login shell PATH, so rely on an
# absolute path pinned by install-timer.sh (AKEYLESS_BIN) and only fall back to
# PATH lookup for interactive use.
AKEYLESS="${AKEYLESS_BIN:-$(command -v akeyless 2>/dev/null || true)}"
if [ -z "$AKEYLESS" ] || [ ! -x "$AKEYLESS" ]; then
  echo "akeyless CLI not found. Set AKEYLESS_BIN to its absolute path." >&2
  exit 1
fi

TOKEN_FILE="${UID_TOKEN_FILE:-$HOME/.akeyless-uid/token/uid-token}"

umask 077
current="$(cat "$TOKEN_FILE")"
tmp="$(mktemp "${TOKEN_FILE}.new.XXXXXX")"
trap 'shred -u "$tmp" 2>/dev/null || rm -f "$tmp"' EXIT

# uid-rotate-token routes to the issuing gateway via the token itself and writes
# only the new token to the -o file. It exits non-zero on failure, so reaching
# the mv means the rotation succeeded.
"$AKEYLESS" uid-rotate-token --uid-token "$current" -o "$tmp" --json >/dev/null
mv -f "$tmp" "$TOKEN_FILE"
trap - EXIT
echo "$(date -Is) rotated uid token in $TOKEN_FILE"
