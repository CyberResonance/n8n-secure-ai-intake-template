# Dead-letter queue and replay

A dead-letter queue (DLQ) is what separates a toy workflow from a production one: when a step fails, the work is not silently lost - it is captured, surfaced, and can be re-run after a fix.

## How failures are captured

`On Workflow Error` (Error Trigger) fires on any unhandled error in the workflow - a non-2xx from the LLM after retries, a schema validation `throw`, a bad expression, anything. It receives n8n's standard error payload (`workflow`, `execution`, `execution.error`).

`Build Dead-Letter Record` turns that into one self-contained JSON record:

```json
{
  "deadLetteredAt": "2026-10-21T10:00:00.000Z",
  "workflow":  { "id": "...", "name": "Signed AI Intake Template (CyberResonance)" },
  "execution": { "id": "123", "url": "https://n8n.example.com/workflow/.../executions/123", "lastNode": "Validate Against JSON Schema" },
  "error":     { "message": "Schema validation failed: category must be ...", "node": "Validate Against JSON Schema" },
  "replay":    "Open execution URL -> Retry -> \"Retry from failed node\", OR re-POST the original signed payload to /secure-intake ..."
}
```

`Alert: Slack / Telegram` posts a readable version to `ALERT_WEBHOOK_URL`.

- **Slack:** an Incoming Webhook accepts `{ "text": "..." }` as-is (the template's default).
- **Telegram:** point `ALERT_WEBHOOK_URL` at `https://api.telegram.org/bot<TOKEN>/sendMessage` and change the Alert node body to `{ "chat_id": "<id>", "text": ... }`.

## The two replay paths

**1. Native n8n retry (no code).** With `EXECUTIONS_DATA_SAVE_ON_ERROR=all` (set in `docker-compose.yml`), the failed execution is retained with all its data. From **Executions**, open the failed run and choose **Retry** -> **Retry from failed node**. n8n re-runs from the point of failure using the saved input - ideal for transient errors or after you fix a downstream node.

**2. Payload replay (idempotent re-submit).** The DLQ record (and your upstream's own logs) contain the original request. Because the HMAC signature is computed over the raw body, the *same body + same signature* stays valid on re-POST. After fixing the root cause, re-send with the example client:

```bash
WEBHOOK_SIGNING_SECRET=yoursecret ./examples/sign_and_send.sh \
    http://localhost:5678/webhook/secure-intake examples/sample-payload.json
```

This path is best when the whole execution should run again from the top (e.g. the LLM prompt or schema was changed).

## Making the queue durable (production note)

The template's DLQ sink is an alert - enough to prove the pattern and to never lose visibility of a failure. For production, add a persistent sink as a second branch off `Build Dead-Letter Record` so records survive and can be queried/replayed in bulk:

- **Postgres / Redis** (the CyberResonance stack) - insert the record as a row / push to a list.
- **Airtable / a file on the mounted volume** - simplest durable option for small volumes.

Keep it least-privilege: the sink credential should only be able to write to the DLQ store, nothing else.
