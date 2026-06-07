# Stage 7 — SNS → n8n Alerting Bridge Setup

This document is the step-by-step runbook for connecting the AWS SNS security
alert topic to your local n8n instance via ngrok. Complete every step in order.

---

## Architecture recap

```
CloudWatch Alarm (WAF BlockedRequests ≥ 50)
        │
        ▼
   SNS Topic  (devsecops-prod-security-alerts)
        │  HTTPS POST
        ▼
  ngrok tunnel  ──────────────────────────────────────────────────▶  local n8n
  (public URL)                                                     (Docker, port 5678)
```

AWS SNS requires a publicly reachable HTTPS endpoint. ngrok provides a temporary
tunnel from the public internet to your local Docker network. The n8n Webhook
trigger node receives the SNS POST and starts the SOC orchestration workflow.

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| n8n | any recent | already running in Docker on port 5678 |
| ngrok | v3+ | `brew install ngrok` or download from ngrok.com |
| AWS CLI | v2 | authenticated with your deployment credentials |
| jq | any | for parsing CLI output on the command line |

---

## Step 1 — Start ngrok tunnel for n8n

Open a dedicated terminal and keep it running throughout the project:

```bash
ngrok http 5678
```

Copy the **Forwarding** HTTPS URL from the ngrok output, e.g.:

```
Forwarding  https://a1b2-203-0-113-42.ngrok-free.app  →  http://localhost:5678
```

> **Free-tier ngrok note:** The URL changes every time ngrok restarts. If ngrok
> restarts, you must re-run the Terraform steps below to update the SNS
> subscription with the new URL.

---

## Step 2 — Create the n8n Webhook trigger node

1. Open n8n at **http://localhost:5678**
2. Create a new workflow: **"DevSecOps SOC Response"**
3. Add a **Webhook** trigger node with these settings:
   - **HTTP Method:** `POST`
   - **Path:** `sns-alert`  (or any slug you choose)
   - **Authentication:** None  (SNS signs its own requests; see verification note below)
   - **Response Mode:** `Immediately`

4. The resulting **Production URL** will be:
   ```
   https://a1b2-203-0-113-42.ngrok-free.app/webhook/sns-alert
   ```

5. **Activate the workflow** (toggle in top-right corner). The webhook only
   receives live traffic when the workflow is active.

---

## Step 3 — Update terraform.tfvars and apply

Edit your `terraform/terraform.tfvars`:

```hcl
n8n_webhook_url = "https://a1b2-203-0-113-42.ngrok-free.app/webhook/sns-alert"
```

Apply the change (this creates or updates the SNS HTTPS subscription):

```bash
cd terraform
terraform apply -target=aws_sns_topic_subscription.n8n_webhook
```

Terraform will create the subscription. AWS immediately sends a
`SubscriptionConfirmation` POST to your webhook. Move to Step 4 now.

---

## Step 4 — Confirm the SNS subscription

### What happens automatically

When `terraform apply` finishes, AWS POSTs a `SubscriptionConfirmation` body
(see `n8n/samples/sns_subscription_confirmation.json`) to your n8n webhook URL.

### How to confirm

**Option A — via n8n test panel (recommended)**

1. In n8n, open the Webhook node and click **"Listen for test event"**
2. Re-run `terraform apply` (or manually re-trigger below) so the confirmation
   is sent while n8n is listening
3. The test panel shows the received body — copy the value of `SubscribeURL`
4. Visit that URL in a browser, or run:
   ```bash
   curl -s "PASTE_SUBSCRIBE_URL_HERE" | cat
   ```
5. AWS responds with `<ConfirmSubscriptionResponse>` — subscription is now active

**Option B — via AWS CLI**

```bash
# Check current subscription status
SNS_TOPIC_ARN=$(terraform -chdir=terraform output -raw sns_topic_arn)

aws sns list-subscriptions-by-topic \
  --topic-arn "$SNS_TOPIC_ARN" \
  --query 'Subscriptions[?Protocol==`https`].[SubscriptionArn,Endpoint]' \
  --output table
```

If `SubscriptionArn` shows `PendingConfirmation`, delete the subscription and
re-create it once n8n is active:

```bash
# Delete pending subscription
SUB_ARN="arn:aws:sns:us-east-1:ACCOUNT_ID:devsecops-prod-security-alerts:SUBSCRIPTION_ID"
aws sns unsubscribe --subscription-arn "$SUB_ARN"

# Re-subscribe (SNS immediately sends a fresh confirmation request)
aws sns subscribe \
  --topic-arn "$SNS_TOPIC_ARN" \
  --protocol https \
  --notification-endpoint "https://YOUR_NGROK_URL.ngrok-free.app/webhook/sns-alert"
```

### Verify the subscription is confirmed

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$SNS_TOPIC_ARN" \
  --query 'Subscriptions[?Protocol==`https`].SubscriptionArn' \
  --output text
# Should return a full ARN, not "PendingConfirmation"
```

---

## Step 5 — Test the bridge manually

Send a fake alarm to verify the full SNS → ngrok → n8n path before running the
actual attack simulation:

```bash
SNS_TOPIC_ARN=$(terraform -chdir=terraform output -raw sns_topic_arn)

aws sns publish \
  --topic-arn "$SNS_TOPIC_ARN" \
  --subject "TEST: devsecops-prod-waf-blocked-requests ALARM" \
  --message file://n8n/samples/cloudwatch_alarm_payload.json
```

In n8n, the workflow should trigger and the Webhook node's execution log should
show the received body. If nothing appears:
- Confirm the workflow is **active** (not in test/paused mode)
- Confirm ngrok is still running and the URL hasn't changed
- Check the ngrok web UI at **http://localhost:4040** to see incoming requests

---

## Step 6 — Understanding the SNS payload in n8n

SNS wraps the CloudWatch alarm data in an **outer envelope**. The actual alarm
details live inside `body.Message` as a **JSON-encoded string** (double-serialised).

Your n8n workflow must parse it in two stages. Add a **Code** node immediately
after the Webhook trigger:

```javascript
// n8n Code node — parse the double-encoded SNS/CloudWatch payload
const body = $input.first().json.body;

// Parse the outer SNS envelope
const sns = typeof body === 'string' ? JSON.parse(body) : body;

// Parse the inner CloudWatch alarm JSON string
const alarm = JSON.parse(sns.Message);

// Extract useful fields
const alarmName    = alarm.AlarmName;
const alarmState   = alarm.NewStateValue;       // "ALARM" or "OK"
const stateReason  = alarm.NewStateReason;
const stateTime    = alarm.StateChangeTime;
const accountId    = alarm.AWSAccountId;
const region       = alarm.Region;

// Extract WAF rule dimension (useful for the Splunk query)
const dimensions   = alarm.Trigger?.Dimensions ?? [];
const webAclName   = dimensions.find(d => d.name === 'WebACL')?.value ?? 'unknown';
const ruleName     = dimensions.find(d => d.name === 'Rule')?.value  ?? 'unknown';

return [{
  json: {
    alarmName,
    alarmState,
    stateReason,
    stateTime,
    accountId,
    region,
    webAclName,
    ruleName,
    rawAlarm: alarm,
  }
}];
```

The output of this Code node feeds directly into the next stage:
**Stage 9 (n8n SOC Orchestration)** — where it queries Splunk, creates the
Outline incident report, and sends the Human-in-the-loop email.

---

## Payload reference

### Incoming SNS notification (what n8n receives)

```
POST /webhook/sns-alert
Content-Type: application/json

{
  "Type":       "Notification",
  "TopicArn":   "arn:aws:sns:us-east-1:...:devsecops-prod-security-alerts",
  "Subject":    "ALARM: \"devsecops-prod-waf-blocked-requests\" in US East ...",
  "Message":    "{ ...CloudWatch alarm JSON string (see alarm.NewStateValue)... }",
  "Timestamp":  "2026-06-06T14:33:00.123Z",
  ...
}
```

Full annotated examples in:
- `n8n/samples/cloudwatch_alarm_payload.json` — live alarm notification
- `n8n/samples/sns_subscription_confirmation.json` — one-time confirmation request

### Key fields extracted after double-parse

| Field | Path | Example value |
|---|---|---|
| Alarm state | `alarm.NewStateValue` | `"ALARM"` |
| Trigger reason | `alarm.NewStateReason` | `"Threshold Crossed: 87.0 ≥ 50"` |
| WAF Web ACL name | `alarm.Trigger.Dimensions[WebACL]` | `"devsecops-prod-web-acl"` |
| Triggered rule | `alarm.Trigger.Dimensions[Rule]` | `"RateLimitRule"` |
| Timestamp | `alarm.StateChangeTime` | `"2026-06-06T14:33:00.000+0000"` |
| AWS account | `alarm.AWSAccountId` | `"123456789012"` |

> **Note:** The alarm payload does **not** contain the attacker's IP address —
> only the rule that fired. The attacker IP is retrieved in Stage 9 by querying
> Splunk for the top source IP in the WAF blocked-requests index.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| n8n webhook shows no traffic | Workflow not activated | Click the toggle to activate |
| Subscription stuck at PendingConfirmation | n8n wasn't running when terraform applied | Follow Option B in Step 4 |
| ngrok shows 502 Bad Gateway | n8n Docker container not running | `docker ps` to check; `docker start n8n` |
| SNS publish succeeds but n8n gets nothing | Wrong webhook URL in tfvars | Re-apply after updating n8n_webhook_url |
| n8n receives request but body is empty | n8n webhook response mode | Set Response Mode to "Immediately" |
