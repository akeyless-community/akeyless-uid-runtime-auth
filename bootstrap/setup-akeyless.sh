#!/usr/bin/env bash
# One-time bootstrap, run by an Akeyless admin from a trusted workstation.
#
# Creates the Universal Identity auth method, a least-privilege role bound to it,
# a demo secret, and the first child token that gets planted on the application
# host. This is the ONLY step that uses an admin credential and the ONLY manual
# step in the whole flow. Everything after this runs on the host with no admin
# key and no human login.
#
# Prerequisites:
#   - akeyless CLI on PATH, authenticated as an admin profile (see --profile).
#   - Edit the variables below to match your environment.
set -euo pipefail

# ---- edit these -------------------------------------------------------------
ADMIN_PROFILE="${ADMIN_PROFILE:-admin}"        # an existing admin CLI profile
GATEWAY_URL="${GATEWAY_URL:-https://your-gateway.example.com}"
AUTH_METHOD="${AUTH_METHOD:-/demo/uid-auth}"
ROLE_NAME="${ROLE_NAME:-/demo/reader}"
SECRET_PATH_PREFIX="${SECRET_PATH_PREFIX:-/demo}" # role gets read+list on this subtree
DEMO_SECRET="${DEMO_SECRET:-/demo/db-password}"
JWT_TTL_MIN="${JWT_TTL_MIN:-60}"               # child-token lifetime; rotate well under this
TOKEN_OUT="${TOKEN_OUT:-./uid-token}"          # where to write the bootstrap token locally
# -----------------------------------------------------------------------------

p=(--profile "$ADMIN_PROFILE")

echo ">> creating demo secret $DEMO_SECRET"
akeyless create-secret --name "$DEMO_SECRET" \
  --value "replace-me-in-your-environment" "${p[@]}" || echo "   (already exists, skipping)"

echo ">> creating Universal Identity auth method $AUTH_METHOD (jwt-ttl ${JWT_TTL_MIN}m, deny-inheritance on)"
create_out="$(akeyless auth-method create universal-identity --name "$AUTH_METHOD" \
  --jwt-ttl "$JWT_TTL_MIN" --deny-inheritance true "${p[@]}")"
echo "$create_out"
ACCESS_ID="$(printf '%s' "$create_out" | grep -oE 'p-[A-Za-z0-9]+' | head -1)"

echo ">> creating role $ROLE_NAME with read+list on ${SECRET_PATH_PREFIX}/*"
akeyless create-role --name "$ROLE_NAME" "${p[@]}" || echo "   (already exists, skipping)"
akeyless set-role-rule --role-name "$ROLE_NAME" --path "${SECRET_PATH_PREFIX}/*" \
  --capability read --capability list "${p[@]}"

echo ">> associating $AUTH_METHOD to $ROLE_NAME"
akeyless assoc-role-am --role-name "$ROLE_NAME" --am-name "$AUTH_METHOD" "${p[@]}"

# UID tokens are standard base64 and may contain / + = ; include those
# characters or the extracted token is silently truncated at the first one.
echo ">> generating the one-time bootstrap token"
umask 077
akeyless uid-generate-token --auth-method-name "$AUTH_METHOD" "${p[@]}" \
  | grep -oE 'u-[A-Za-z0-9+/=]+' | head -1 > "$TOKEN_OUT"

cat <<EOF

Done.
  Auth method access id : $ACCESS_ID
  Bootstrap token       : written to $TOKEN_OUT (0600)

Next steps on the application host:
  1. Copy $TOKEN_OUT to the host at \$HOME/.akeyless-uid/token/uid-token (0600).
  2. Configure the host CLI profile:
       akeyless configure --profile app-uid \\
         --access-id $ACCESS_ID \\
         --access-type universal_identity \\
         --gateway-url $GATEWAY_URL
  3. Install the rotation timer (see host/install-timer.sh).
EOF
