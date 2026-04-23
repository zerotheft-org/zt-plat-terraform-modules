import json
import boto3
import psycopg2
import hashlib
import os
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3')
secretsmanager = boto3.client('secretsmanager')


def get_db_connection():
    """
    Create a CRDB connection using credentials loaded from Secrets Manager.

    Params: none (uses environment variables for secret id and DB name).
    Returns: psycopg2 connection object.
    """
    secret = secretsmanager.get_secret_value(
        SecretId=os.environ['DB_SECRET_NAME']
    )
    creds = json.loads(secret['SecretString'])

    try:
        db = creds['db']
        # Use active_user to pick which user credentials to connect with
        active_user = db['active_user']
        user_creds = db['users'][active_user]
    except KeyError as exc:
        raise ValueError(f"Invalid DB secret structure; missing key: {exc}") from exc

    return psycopg2.connect(
        host=db['host'],
        port=db.get('port', 26257),
        database=os.environ['DB_NAME'],
        user=user_creds['username'],
        password=user_creds['password'],
        sslmode='verify-full',
        sslrootcert='/var/task/cockroachdb-ca.crt'
    )


def get_current_schema(conn):
    """
    Queries three things:
    - columns: every column in every table (name, type, nullable, default)
    - indexes: every index definition
    - users: every DB user and their privileges
    """
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT
                table_name,
                column_name,
                data_type,
                is_nullable,
                column_default
            FROM information_schema.columns
            WHERE table_schema = 'public'
            ORDER BY table_name, column_name
        """)
        columns = cursor.fetchall()

        cursor.execute("""
            SELECT
                tablename,
                indexname,
                indexdef
            FROM pg_indexes
            WHERE schemaname = 'public'
            ORDER BY tablename, indexname
        """)
        indexes = cursor.fetchall()

        cursor.execute("""
            SELECT
                usename,
                usesuper,
                usecreatedb
            FROM pg_user
            ORDER BY usename
        """)
        users = cursor.fetchall()
    finally:
        cursor.close()

    return {
        "columns":     [list(r) for r in columns],
        "indexes":     [list(r) for r in indexes],
        "users":       [list(r) for r in users],
        "captured_at": datetime.utcnow().isoformat()
    }


def load_baseline():
    """
    Loads the saved baseline from S3.
    Returns None if no baseline exists yet (first run).
    """
    try:
        response = s3.get_object(
            Bucket=os.environ['S3_BUCKET'],
            Key=os.environ['S3_BASELINE_KEY']
        )
        return json.loads(response['Body'].read())
    except s3.exceptions.NoSuchKey:
        return None


def save_baseline(schema):
    """Saves current schema as the new baseline in S3."""
    s3.put_object(
        Bucket=os.environ['S3_BUCKET'],
        Key=os.environ['S3_BASELINE_KEY'],
        Body=json.dumps(schema, indent=2),
        ContentType='application/json'
    )


def compute_hash(schema):
    """
    Hashes the schema for fast comparison.
    Excludes captured_at so timestamps do not cause false positives.
    """
    comparable = {k: v for k, v in schema.items() if k != 'captured_at'}
    return hashlib.sha256(
        json.dumps(comparable, sort_keys=True).encode()
    ).hexdigest()


def find_differences(baseline, current):
    """
    Compares baseline vs current.
    Returns a list of human-readable change descriptions.
    """
    diffs = []

    # Column changes
    baseline_cols = {f"{r[0]}.{r[1]}": r for r in baseline['columns']}
    current_cols  = {f"{r[0]}.{r[1]}": r for r in current['columns']}

    for key in set(current_cols) - set(baseline_cols):
        diffs.append(f"NEW COLUMN: {key}")
    for key in set(baseline_cols) - set(current_cols):
        diffs.append(f"DROPPED COLUMN: {key}")
    for key in set(baseline_cols) & set(current_cols):
        if baseline_cols[key][2] != current_cols[key][2]:
            diffs.append(
                f"TYPE CHANGE: {key} "
                f"{baseline_cols[key][2]} -> {current_cols[key][2]}"
            )

    # Index changes
    baseline_idx = {r[1]: r for r in baseline['indexes']}
    current_idx  = {r[1]: r for r in current['indexes']}

    for key in set(current_idx) - set(baseline_idx):
        diffs.append(f"NEW INDEX: {key}")
    for key in set(baseline_idx) - set(current_idx):
        diffs.append(f"DROPPED INDEX: {key}")

    # User changes
    baseline_users = {r[0] for r in baseline['users']}
    current_users  = {r[0] for r in current['users']}

    for u in current_users - baseline_users:
        diffs.append(f"NEW USER: {u}")
    for u in baseline_users - current_users:
        diffs.append(f"DROPPED USER: {u}")

    return diffs


def handler(event, context):
    """
    Lambda entrypoint for schema drift checks against the stored baseline.

    Params: event (unused), context (Lambda runtime context).
    Returns: dict with status and optional diffs metadata.
    """
    env  = os.environ['ENVIRONMENT']
    conn = None

    try:
        conn           = get_db_connection()
        current_schema = get_current_schema(conn)
        baseline       = load_baseline()

        # First ever run — save baseline and exit cleanly
        if baseline is None:
            save_baseline(current_schema)
            logger.info("No baseline found. Saved current schema as baseline.")
            return {"status": "baseline_created"}

        # No drift — hashes match
        if compute_hash(baseline) == compute_hash(current_schema):
            logger.info("Schema drift check passed. No changes detected.")
            return {"status": "clean"}

        # Drift detected — log as ERROR so metric filter picks it up
        diffs     = find_differences(baseline, current_schema)
        diff_text = diffs if diffs else ["Hash mismatch — manual inspection required"]

        logger.error(json.dumps({
            "event":       "SCHEMA_DRIFT_DETECTED",
            "environment": env,
            "diffs":       diff_text,
            "detected_at": current_schema['captured_at'],
            "baseline_at": baseline['captured_at']
        }))

        return {"status": "drift_detected", "diffs": diff_text}

    finally:
        if conn:
            conn.close()
