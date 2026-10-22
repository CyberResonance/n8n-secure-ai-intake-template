#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sign_and_send.sh - compute an HMAC-SHA256 signature over the raw request
# body and POST it to the /secure-intake webhook, exactly as a real signed
# upstream would. This is the client side of PILLAR 1.
#
# Usage:
#   WEBHOOK_SIGNING_SECRET=... ./sign_and_send.sh \
#       http://localhost:5678/webhook/secure-intake examples/sample-payload.json
#
# The signature is computed over the EXACT bytes that are sent, so the n8n
# Webhook node must have "Raw Body" enabled (it is, in the template).
# ---------------------------------------------------------------------------
set -euo pipefail

URL="${1:?Usage: sign_and_send.sh <webhook-url> <payload.json>}"
PAYLOAD_FILE="${2:?Usage: sign_and_send.sh <webhook-url> <payload.json>}"
SECRET="${WEBHOOK_SIGNING_SECRET:?Set WEBHOOK_SIGNING_SECRET in your environment}"

BODY="$(cat "$PAYLOAD_FILE")"

# HMAC-SHA256(secret, raw_body) -> lowercase hex
SIG="$(printf '%s' "$BODY" \
  | openssl dgst -sha256 -hmac "$SECRET" \
  | sed 's/^.* //')"

echo "Signature: sha256=${SIG}"

curl -sS -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "x-webhook-signature: sha256=${SIG}" \
  --data-raw "$BODY"
echo
