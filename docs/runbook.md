# Runbook

How the three defensive pillars work, in enough detail to operate and extend the template. Node names below match `workflow/signed-ai-intake-template.json` exactly.

---

## Pillar 1 - Signature-verified webhook ingestion

**Goal:** nothing untrusted enters the pipeline. An unsigned or tampered request is rejected at the edge with `401`, before the LLM or any downstream node runs.

**Flow:** `Webhook (POST /secure-intake)` -> `HMAC Signature Guard` -> `Signature Valid?` (IF) -> reject or proceed.

**Mechanism:**
1. The `Webhook` node runs with the **Raw Body** option ON. This is required: the HMAC must be computed over the *exact bytes* the sender signed. Re-serializing parsed JSON would change whitespace/key order and break verification.
2. `HMAC Signature Guard` (Code node) recomputes `HMAC-SHA256(WEBHOOK_SIGNING_SECRET, rawBody)` and compares it to the `x-webhook-signature: sha256=<hex>` header.
3. Comparison uses `crypto.timingSafeEqual` with a length guard - constant-time, so it leaks no information through response timing.
4. The secret is read from `$env.WEBHOOK_SIGNING_SECRET`. If it is missing, the node throws rather than failing open.
5. `Signature Valid?` routes `true` -> `LLM Extraction`, `false` -> `Respond 401 (reject)`.

**Test it:**
```bash
WEBHOOK_SIGNING_SECRET=yoursecret ./examples/sign_and_send.sh \
    http://localhost:5678/webhook/secure-intake examples/sample-payload.json
```
Flip one character of the secret or the body and you get `401 invalid_signature`.

---

## Pillar 2 - LLM output validated against a strict JSON schema

**Goal:** a hallucinated, truncated, or extra-field LLM response is caught and dead-lettered - never written to a database or forwarded to another system.

**Flow:** `LLM Extraction` (HTTP Request) -> `Validate Against JSON Schema` (Code node) -> `Downstream Action`.

**Mechanism:**
1. `LLM Extraction` calls an OpenAI-compatible `/chat/completions` endpoint, asking for a JSON object and setting `response_format: { type: "json_object" }`. The API key is sent as a `Bearer` header from `$env.LLM_API_KEY`; no credential is hardcoded. The node has `retryOnFail` (3 tries) for transient 5xx/network errors.
2. `Validate Against JSON Schema` parses `choices[0].message.content` and checks it against the contract in [`examples/intake.schema.json`](../examples/intake.schema.json): required keys, enum membership, string length, numeric range, and `additionalProperties: false` (unknown keys are rejected).
3. The check is dependency-free plain JavaScript (Ponytail rung 3 - standard language features over a new npm package). Swap in `ajv` if you prefer a formal JSON-Schema engine; the schema file is already in Draft 2020-12.
4. **Any** failure (`throw`) stops the execution, which hands it to `On Workflow Error` -> the dead-letter path. Malformed output cannot leak downstream.

---

## Pillar 3 - Dead-letter failure queue + replay

See [`dead-letter-and-replay.md`](dead-letter-and-replay.md) for the full detail. In short:

- `On Workflow Error` (Error Trigger) catches a failure anywhere in the workflow.
- `Build Dead-Letter Record` assembles one structured, self-contained record (workflow, execution id + clickable URL, failing node, error message, replay instructions).
- `Alert: Slack / Telegram` posts it to `$env.ALERT_WEBHOOK_URL`. This node is `onError: continueRegularOutput` so a flaky alert channel never swallows the original error.

---

## Secrets and least privilege

- Every secret is read via `{{ $env.NAME }}` or a `Bearer` header sourced from env. Grep the workflow JSON: there are no literal keys, tokens, or URLs with credentials.
- `.env` is git-ignored; only `.env.example` (placeholders) ships.
- The `docker-compose.yml` injects env from `.env` and exposes only n8n's own port.
- For env access in expressions, self-hosted n8n must have `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` (the default). If your instance sets it to `true`, move the values into n8n **Credentials** / **Variables** instead and reference those.

---

## One required manual step after import

An Error Trigger only fires for a workflow that is registered as its own error handler. After importing and activating:

1. Open the workflow -> **Settings** (three dots) -> **Error Workflow**.
2. Select **this same workflow**.

Without this, `On Workflow Error` never runs and failures are not dead-lettered.
