## Secret Manager + EventBridge + RabbitMQ (Stage)

This module creates:

- **Four AWS Secrets Manager secrets** (separate resources):
  - `db` (rotated by the Lambda),
  - `keycloak` (stored; rotation optional),
  - `sendgrid` (static credentials),
  - `webhook` (ngrok / webhook credentials).
- **Lambda function** that:
  - rotates **DB** using an **alternating user** (zero-downtime),
  - (optionally) can be extended to rotate **Keycloak** when `expires_at` is due,
  - publishes to **RabbitMQ** with a **standard payload** that includes **which sections were updated**.
- **EventBridge rule** that triggers the Lambda on a schedule.

High-level flow:

EventBridge (schedule) → Lambda (rotate db and/or keycloak) → Secrets Manager + RabbitMQ (payload includes `updated_sections`).

---

## 1. Secret layout (separate Secrets)

The module now creates four separate Secrets Manager resources. Each secret holds a small JSON object with the following expected shapes (initial placeholders are created by Terraform; populate with real values after `apply` using `aws secretsmanager put-secret-value`).

- `stage/app/db-credentials` (DB secret used by the Lambda)

```json
{
  "active_user": "A",
  "users": {
    "A": { "username": "app_user_A", "password": "xxx", "expires_at": "2026-03-01T00:00:00Z" },
    "B": { "username": "app_user_B", "password": "yyy", "expires_at": "2026-03-15T00:00:00Z" }
  }
}
```

- `stage/app/keycloak-client` (Keycloak client data — rotation is optional / unmodified by default)

```json
{ "client_id": "app-client", "client_secret": "zzz", "expires_at": "2026-02-20T00:00:00Z" }
```

- `stage/app/sendgrid` (SendGrid config)

```json
{ "api_key": "SG.xxx", "from_email": "noreply@example.com", "webhook_verification_key": "..." }
```

- `stage/app/webhook` (Webhook / ngrok credentials)

```json
{ "ngrok": { "auth_token": "xxx", "expires_at": null } }
```

Notes:
- The Lambda's `SECRET_ID` environment variable is set to the DB secret created by the module; the Lambda will only read/put values for that DB secret. The module creates initial placeholder values for all four secrets; populate them after `apply`.
- If you want the Lambda to also rotate Keycloak, extend `lambda_rotation/rotation_handler.py` to read/write the Keycloak secret and update the module accordingly.

---

## 2. RabbitMQ standard (exchange, routing key, payload)

| Item | Value | Notes |
|------|--------|--------|
| **Exchange** | `secret-rotation` (configurable via `rabbitmq_exchange`) | Topic exchange, durable |
| **Routing key (main)** | `rotation` (configurable via `rabbitmq_routing_key`) | One message per run with full payload |
| **Routing key (per section)** | `rotation.db`, `rotation.keycloak` | Same payload published to these when that section was updated (so queues can bind to only db or only keycloak) |

**Message payload** (only sections that were actually rotated are listed in `updated_sections`; `details` contains only those sections):

Example when only **db** was rotated:

```json
{
  "event": "SECRET_ROTATED",
  "secret_id": "stage/app/credentials",
  "timestamp": "2026-02-11T12:00:00Z",
  "updated_sections": ["db"],
  "details": {
    "db": { "active_user": "B", "rotated_user": "B" }
  }
}
```

Example when **db** and **keycloak** were both rotated:

```json
{
  "event": "SECRET_ROTATED",
  "secret_id": "stage/app/credentials",
  "timestamp": "2026-02-11T12:00:00Z",
  "updated_sections": ["db", "keycloak"],
  "details": {
    "db": { "active_user": "B", "rotated_user": "B" },
    "keycloak": { "expires_at": "2026-03-13T12:00:00Z" }
  }
}
```

- **db** is rotated every run (alternating user); **keycloak** only when `expires_at` is past or within `keycloak_rotation_grace_days`. So you get `["db"]` or `["db", "keycloak"]`; `details` only includes keys for rotated sections.

Consumers should:
- Bind to `rotation` to receive every rotation event and use `updated_sections` to decide what to refresh.
- Or bind to `rotation.db` / `rotation.keycloak` to receive only events when that section was updated.

---

## 3. What gets created

- Four `aws_secretsmanager_secret` resources with initial `aws_secretsmanager_secret_version` values:
  - `aws_secretsmanager_secret.db` (name `var.db_secret_name`) — rotated by the Lambda
  - `aws_secretsmanager_secret.keycloak` (name `var.keycloak_secret_name`) — placeholder stored
  - `aws_secretsmanager_secret.sendgrid` (name `var.sendgrid_secret_name`) — placeholder stored
  - `aws_secretsmanager_secret.webhook` (name `var.webhook_secret_name`) — placeholder stored
- `aws_lambda_function.rotation_notifier` — rotation + notification Lambda (configured to operate on the DB secret)
- `aws_cloudwatch_event_rule.rotation_schedule` — schedule rule triggering Lambda
- `aws_cloudwatch_event_target.rotation_target` + `aws_lambda_permission.allow_events` — EventBridge → Lambda wiring

The Lambda behaviour:

- **DB**: Rotates the **inactive** user's password (A↔B), sets `expires_at`, then switches `active_user` to that user (zero‑downtime).
- **Keycloak**: the module stores a Keycloak secret object, but rotation of Keycloak is only performed if you extend the Lambda to read/write that separate secret and trigger rotation logic; by default the Lambda only rotates the DB secret.
- The Lambda publishes a RabbitMQ message with `updated_sections` listing only the sections actually rotated (e.g. `[
"db"]`).

---

## 4. Terraform entrypoint (stage)

For **stage**, use the root at:

```bash
cd infra/envs/stage/secret_manager
```

Files there:

- `backend.tf` – S3 backend for **staging-secret-manager** state (no DynamoDB lock).
- `variables.tf` – stage-specific values (secret name, RabbitMQ URL, schedule).
- `main.tf` – calls `modules/secret_manager`.
- `outputs.tf` – re-exports module outputs (secret arn, lambda name, etc.).

---

rabbitmq_url        = "amqp://admin:StrongP@ssw0rd2026!@<your-ec2-ip>:5672/"
## 5. Required variables (stage)

In `infra/envs/stage/secret_manager/variables.tf`:

- `db_secret_name` (default `stage/app/db-credentials`) — name of the DB secret the Lambda will operate on
- `keycloak_secret_name` (default `stage/app/keycloak-client`) — name for Keycloak client data
- `sendgrid_secret_name` (default `stage/app/sendgrid`) — name for SendGrid secret
- `webhook_secret_name` (default `stage/app/webhook`) — name for webhook/ngrok secret
- `rotation_schedule_expression` — EventBridge schedule, e.g. `rate(30 days)` or `rate(5 minutes)` for testing
- `rabbitmq_url` (**required, no default**) — full AMQP connection string
- `rabbitmq_exchange` (default `secret-rotation`)
- `rabbitmq_routing_key` (default `rotation`)

Recommended `terraform.tfvars` at `infra/envs/stage/secret_manager/terraform.tfvars` (example):

```hcl
db_secret_name               = "stage/app/db-credentials"
keycloak_secret_name         = "stage/app/keycloak-client"
sendgrid_secret_name         = "stage/app/sendgrid"
webhook_secret_name          = "stage/app/webhook"

rotation_schedule_expression = "rate(30 days)"

rabbitmq_url        = "amqp://admin:StrongP@ssw0rd2026!@<your-ec2-ip>:5672/"
rabbitmq_exchange   = "secret-rotation"
rabbitmq_routing_key = "rotation"
```

Add this tfvars file to `.gitignore` if it contains real credentials.

---

## 6. Build the Lambda package

From the module directory:

```bash
cd infra/modules/secret_manager/lambda_rotation
python3 -m venv venv
source venv/bin/activate    # Windows: venv\Scripts\activate
pip install -r requirements.txt -t .
zip -r ../lambda_rotation.zip .
deactivate
cd ..
```

`lambda_rotation.zip` must live in `infra/modules/secret_manager/` (the module root), as referenced by Terraform.

---

## 7. Apply Terraform (stage secret manager)

From the secret manager root:

```bash
cd infra/envs/stage/secret_manager

# First time
terraform init

# Check the plan
terraform plan

# Apply
terraform apply
```

This will:

- Create the secret (with placeholder value).
- Create the IAM role and Lambda.
- Create the EventBridge schedule rule wired to the Lambda.

Outputs of interest (module exports):

- `db_secret_arn` / `db_secret_name` — DB secret identifiers
- `keycloak_secret_arn` / `keycloak_secret_name` — Keycloak secret identifiers
- `sendgrid_secret_arn` / `sendgrid_secret_name` — SendGrid secret identifiers
- `webhook_secret_arn` / `webhook_secret_name` — Webhook secret identifiers
- `lambda_function_name` — the Lambda name you can see in the AWS console.

---

## 8. When to put the secret value

Right after Terraform apply, the secret exists with a placeholder. Set your **real** values once (use the schema from §1):

```bash
aws secretsmanager put-secret-value \
  --secret-id stage/app/credentials \
  --secret-string '{
    "db": {
      "active_user": "A",
      "users": {
        "A": { "username": "app_user_A", "password": "real_password_A", "expires_at": "2026-03-01T00:00:00Z" },
        "B": { "username": "app_user_B", "password": "real_password_B", "expires_at": "2026-03-15T00:00:00Z" }
      }
    },
    "keycloak": { "client_id": "app-client", "client_secret": "real_secret", "expires_at": "2026-02-20T00:00:00Z" }
  }'
```

Replace `stage/app/credentials` if you changed `secret_name`, and use real usernames/passwords. After that, the Lambda will rotate **db** (alternating user) and **keycloak** (when due) and publish only the **updated_sections** in RabbitMQ.

---

## 9. How the Lambda works (simple view)

`lambda_rotation/rotation_handler.py` does:

1. `get_secret_value(SECRET_ID)` → parse JSON.
2. Generate a new random password.
3. Replace `password` in the JSON and write it back with `put_secret_value`.
4. Connect to RabbitMQ using `RABBITMQ_URL`.
5. Declare the topic exchange `RABBITMQ_EXCHANGE`.
6. Publish a small JSON event:

   ```json
   {
     "event": "SECRET_ROTATED",
     "secret_id": "stage/app/credentials",
     "timestamp": "2026-02-11T10:00:00Z"
   }
   ```

Any service with a queue bound to that exchange/routing key will see the message.

---

## 10. How to trigger the Lambda and test it

There are **two easy ways** to see if everything works.

### Option A – Use a fast schedule during testing

1. In `infra/envs/stage/secret_manager/terraform.tfvars`, set:

   ```hcl
   rotation_schedule_expression = "rate(1 minute)"
   ```

2. `terraform apply` from `infra/envs/stage/secret_manager`.
3. Watch Lambda logs in CloudWatch:

   ```bash
   aws logs tail /aws/lambda/secret-rotation-notifier-stage --follow
   ```

4. Check your RabbitMQ exchange/queues:
   - You should see `SECRET_ROTATED` messages arriving every minute.
5. When you’re done testing, change back to something like `rate(30 days)` and apply again.

### Option B – Manually invoke the Lambda

From the AWS console:

1. Find the Lambda named like `secret-rotation-notifier-stage`.
2. Click **Test**, create a simple empty test event (e.g. `{}`).
3. Invoke it.

The handler ignores the event body, so this will:

- Rotate the secret once.
- Publish a RabbitMQ message once.

You can also trigger from CLI:

```bash
aws lambda invoke \
  --function-name secret-rotation-notifier-stage \
  /tmp/out.json
```

---

## 11. What your services need to do

On the consumer side (your services/pods):

- Connect to RabbitMQ.
- Declare/bind a queue to the **same exchange** and **routing key**:
  - Exchange: `secret-rotation` (default).
  - Routing key: `rotation` (default).
- When they receive `SECRET_ROTATED` events, they should:
  - Fetch the latest credentials from AWS Secrets Manager using `secret_arn` / `secret_name`.
  - Refresh any cached DB connections or configs.

This means **no direct coupling** to rotation logic – they just react to the message.

---

## 12. Summary

- **Terraform root** for this task: `infra/envs/stage/secret_manager`.  
- **Module**: `infra/modules/secret_manager`.  
- **Flow**: EventBridge schedule → Lambda → Secrets Manager + RabbitMQ.  
- **You configure**:
  - `secret_name`
  - `rotation_schedule_expression`
  - `rabbitmq_url` (+ exchange & routing key)
  - Initial secret value (via `aws secretsmanager put-secret-value`).  

After that, rotation is automatic on the schedule you choose, and all services listening to the RabbitMQ topic exchange will be notified whenever the secret rotates.

# How to Run – Secret Manager (Stage)

You have **two separate Terraform roots** for stage:

| Root | What it manages | State (backend) |
|------|------------------|-----------------|
| **`infra/envs/stage/`** | VPC and shared network | S3: `staging.tfstate` + DynamoDB lock |
| **`infra/envs/stage/secret_manager/`** | Secret Manager only | S3: `staging-secret-manager.tfstate`, **no DynamoDB** (avoids cycle/lock issues) |

Run the **stage** root first (so VPC exists), then the **secret_manager** root (it reads stage state for VPC id and subnets).

---

## 1. Where to run (two places)

- **VPC / main stage:** `cd infra/envs/stage` → `terraform init` / `plan` / `apply`
- **Secret Manager:** `cd infra/envs/stage/secret_manager` → `terraform init` / `plan` / `apply`

Do **not** run Terraform from `infra/modules/secret_manager/` — that is only the module. You apply it from `envs/stage/secret_manager/`.

---

## 2. Credentials and variables

### AWS credentials (same for both roots)

Use one of these for **both** `stage` and `stage/secret_manager`:

**Option A – Profile**

```bash
aws configure --profile your-profile
# Then:
export AWS_PROFILE=your-profile
```

**Option B – Environment variables**

```bash
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="us-east-1"
```

Store in `~/.aws/credentials` or in env; **do not commit** secrets.

---

### Terraform variables

**Main stage (VPC)** – in `infra/envs/stage/terraform.tfvars`:

```hcl
aws_region         = "us-east-1"
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
```

**Secret Manager** – in `infra/envs/stage/secret_manager/terraform.tfvars`:

```hcl
# Required
secret_manager_redis_host              = "your-elasticache.xxxxx.cache.amazonaws.com"
secret_manager_redis_security_group_id = "sg-xxxxxxxx"
secret_manager_alert_email             = "you@example.com"

# Optional (defaults shown)
# secret_manager_db_secret_name = "stage/database/credentials"
# secret_manager_rotation_days  = 30
# secret_manager_redis_port     = 6379
# secret_manager_redis_channel  = "secret_rotation"
# secret_manager_lambda_zip_path = "../../../modules/secret_manager/lambda_rotation.zip"
```

Add `terraform.tfvars` to `.gitignore` if they contain sensitive or env-specific values.

---

## 3. One-time: build Lambda package

Build the zip that the secret manager module uses:

```bash
cd infra/modules/secret_manager/lambda_rotation
python3 -m venv venv
source venv/bin/activate   # Windows: venv\Scripts\activate
pip install -r requirements.txt -t .
zip -r ../lambda_rotation.zip .
deactivate
cd ..
```

**Result:** `infra/modules/secret_manager/lambda_rotation.zip`. The `secret_manager` root uses it via `secret_manager_lambda_zip_path` (default path is correct when run from `envs/stage/secret_manager`).

---

## 4. Deploy (order matters)

**Step 1 – Main stage (VPC)**

```bash
cd infra/envs/stage
terraform init
terraform plan
terraform apply
```

Uses backend: S3 bucket `zero-app-staging`, key `terraform/state/staging.tfstate`, with DynamoDB lock.  
After this, the state has `vpc_id` and `private_subnet_ids` outputs.

**Step 2 – Secret Manager (separate state, no DynamoDB)**

```bash
cd infra/envs/stage/secret_manager
terraform init
terraform plan
terraform apply
```

Uses backend: same bucket, key `terraform/state/staging-secret-manager.tfstate`, **no** `dynamodb_table` (avoids cycle/lock issues).  
This root reads the stage state via `terraform_remote_state` to get VPC and subnets; it only manages secret manager resources.

Save the outputs (`secret_arn`, `backend_instance_profile_name`, etc.) for the app and for setting the DB password.

---

## 5. Set the database password (one time)

Use the same AWS credentials; secret id must match your `secret_manager_db_secret_name` (default: `stage/database/credentials`):

```bash
aws secretsmanager put-secret-value \
  --secret-id stage/database/credentials \
  --secret-string '{
    "username": "admin",
    "password": "YOUR_REAL_PASSWORD",
    "host": "your-db.region.rds.amazonaws.com",
    "port": 3306,
    "dbname": "mydb"
  }'
```

---

## 6. Run the backend service (continuous)

Your app should read the secret from Secrets Manager and subscribe to the Redis channel for rotation. Use the `secret_arn` from the **secret_manager** root outputs.

**Example env vars:**

```bash
export SECRET_ARN="arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:stage/database/credentials-XXXXX"
export REDIS_HOST="your-elasticache.cache.amazonaws.com"
export REDIS_PORT="6379"
export REDIS_TLS="true"
# Then run your app
```

**EC2:** Use the instance profile from output `backend_instance_profile_name` (e.g. `secret-rotation-backend-profile-stage`) so the instance can read the secret without embedding keys.

---

## 7. Quick reference

| What | Where |
|------|--------|
| Run Terraform for **VPC** | `infra/envs/stage` |
| Run Terraform for **Secret Manager** | `infra/envs/stage/secret_manager` |
| Stage state | S3: `staging.tfstate` + DynamoDB lock |
| Secret Manager state | S3: `staging-secret-manager.tfstate`, no DynamoDB |
| AWS credentials | `~/.aws/credentials` or env vars |
| VPC variables | `infra/envs/stage/terraform.tfvars` |
| Secret Manager variables | `infra/envs/stage/secret_manager/terraform.tfvars` |
| Lambda zip | Build in `infra/modules/secret_manager/lambda_rotation/` → `../lambda_rotation.zip` |

---

## 8. End-to-end flow

1. Set AWS credentials (profile or env).  
2. Create `infra/envs/stage/terraform.tfvars` (VPC).  
3. Create `infra/envs/stage/secret_manager/terraform.tfvars` (Redis, alert email).  
4. Build `lambda_rotation.zip` in `infra/modules/secret_manager/lambda_rotation/`.  
5. From `infra/envs/stage`: `terraform init` → `terraform apply` (VPC).  
6. From `infra/envs/stage/secret_manager`: `terraform init` → `terraform apply` (Secret Manager).  
7. Set DB password: `aws secretsmanager put-secret-value --secret-id stage/database/credentials ...`.  
8. Run your backend with `SECRET_ARN` and Redis env vars; on EC2 use the backend instance profile from secret_manager outputs.

After that, rotation runs on schedule; the Lambda publishes to Redis and your backend reloads the secret when it receives the event.
