"""Security-critical Secrets Manager rotation handler for CockroachDB + RabbitMQ.

Rotates DB credentials, persists updated secrets, and publishes rotation events.
"""

import json
import logging
import os
import string
import secrets as secrets_module
from datetime import datetime, timezone, timedelta

import boto3
import pika
import psycopg2
from psycopg2 import sql

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client("secretsmanager")

SECRET_ID = os.environ["SECRET_ID"]
RABBITMQ_URL = os.environ["RABBITMQ_URL"]
RABBITMQ_EXCHANGE = os.environ.get("RABBITMQ_EXCHANGE", "secret-rotation")
RABBITMQ_ROUTING_KEY = os.environ.get("RABBITMQ_ROUTING_KEY", "rotation")


def _required_env(name: str) -> str:
    """Return a required environment variable value or raise RuntimeError.

    Args:
        name: Environment variable name.
    Returns:
        The non-empty environment variable value.
    Raises:
        RuntimeError: If the variable is missing or empty.
    """
    value = os.environ.get(name)
    if value:
        return value
    raise RuntimeError(f"Missing required environment variable: {name}")


DB_ADMIN_USER = _required_env("DB_ADMIN_USER")
DB_ADMIN_PASSWORD = _required_env("DB_ADMIN_PASSWORD")
# Standard: DB user credentials expire this many days from rotation
DB_EXPIRY_DAYS = 30


def _generate_password(length: int = 32) -> str:
    """Generate a secure random password"""
    alphabet = string.ascii_letters + string.digits + "!@#$%^&*()-_=+"
    return "".join(secrets_module.choice(alphabet) for _ in range(length))


def _connect_to_cockroachdb(host: str, port: int, database: str, user: str, password: str):
    """
    Connect to CockroachDB using psycopg2.
    CockroachDB is PostgreSQL-compatible.
    """
    try:
        connection = psycopg2.connect(
            host=host,
            port=port,
            database=database,
            user=user,
            password=password,
            sslmode='require',  # CockroachDB requires SSL
            connect_timeout=10
        )
        logger.info(f"Successfully connected to CockroachDB as {user}")
        return connection
    except psycopg2.Error as e:
        logger.error(f"Failed to connect to CockroachDB: {e}")
        raise


def _change_cockroachdb_password(connection, username: str, new_password: str):
    """
    Actually change the password in CockroachDB.
    Uses ALTER USER SQL command.
    """
    try:
        with connection.cursor() as cursor:
            # Compose username as SQL identifier to avoid SQL injection.
            alter_sql = sql.SQL("ALTER USER {} WITH PASSWORD %s").format(
                sql.Identifier(username)
            )
            cursor.execute(alter_sql, (new_password,))
            connection.commit()

        logger.info(f"Successfully changed password for user {username} in CockroachDB")

    except psycopg2.Error as e:
        logger.error(f"Failed to change password in CockroachDB: {e}")
        connection.rollback()
        raise


def _rotate_db(data: dict) -> tuple[dict, list[str], dict]:
    """
    Alternating user: rotate the inactive user's password and flip active_user.
    ACTUALLY connects to CockroachDB and changes the password.
    Returns (updated_data, updated_sections, details).
    """
    db = data.get("db") or {}
    if not isinstance(db, dict):
        logger.error(
            "Secret misconfigured: db must be a mapping",
            extra={"db_type": type(db).__name__},
        )
        raise ValueError("db must be a mapping")

    users = db.get("users") or {}
    if not isinstance(users, dict):
        logger.error(
            "Secret misconfigured: db.users must be a mapping",
            extra={"users_type": type(users).__name__},
        )
        raise ValueError("db.users must be a mapping")

    user_a = users.get("A")
    user_b = users.get("B")
    if not isinstance(user_a, dict) or not isinstance(user_b, dict):
        logger.error(
            "Secret misconfigured: db.users.A and db.users.B must be non-null mappings",
            extra={
                "present_user_keys": list(users.keys()),
                "user_a_type": type(user_a).__name__ if user_a is not None else "NoneType",
                "user_b_type": type(user_b).__name__ if user_b is not None else "NoneType",
            },
        )
        raise ValueError("db.users.A and db.users.B must be non-null mappings")

    # Determine which user is currently active and which to rotate
    active = (db.get("active_user") or "A").strip().upper()
    if active not in ("A", "B"):
        active = "A"
    inactive = "B" if active == "A" else "A"

    logger.info(f"Active user: {active}, Rotating user: {inactive}")

    # Get connection details
    host = db.get("host")
    port = db.get("port", 26257)  # CockroachDB default port
    database = db.get("database", "defaultdb")
    
    if not host:
        logger.error("db.host is required")
        raise ValueError("db.host is required")

    # Generate new password
    new_password = _generate_password()
    expires = (datetime.now(timezone.utc) + timedelta(days=DB_EXPIRY_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Get inactive user's username
    inactive_username = users[inactive].get("username")
    if not inactive_username:
        logger.error(f"Inactive user {inactive} missing username")
        raise ValueError(f"Inactive user {inactive} username missing")

    # Step 1: Connect to CockroachDB using admin credentials.
    connection = _connect_to_cockroachdb(
        host=host,
        port=port,
        database=database,
        user=DB_ADMIN_USER,
        password=DB_ADMIN_PASSWORD
    )

    try:
        # Step 2: Change the inactive user's password
        _change_cockroachdb_password(connection, inactive_username, new_password)
        
        # Step 3: Test the new password by connecting with inactive user
        logger.info(f"Testing new password for {inactive_username}")
        test_connection = _connect_to_cockroachdb(
            host=host,
            port=port,
            database=database,
            user=inactive_username,
            password=new_password
        )
        test_connection.close()
        logger.info(f"Successfully verified new password for {inactive_username}")
        
    except Exception as e:
        logger.error(f"Failed to rotate password for {inactive_username}: {e}")
        raise
    
    finally:
        connection.close()

    # Step 4: Update the secret data
    users[inactive] = {
        **users[inactive],
        "password": new_password,
        "expires_at": expires,
    }
    
    data["db"] = {
        **db,
        "active_user": inactive,  # Switch to newly rotated user
        "users": users,
    }

    details = {
        "active_user": inactive,
        "rotated_user": inactive,
        "username": inactive_username,
        "expires_at": expires
    }
    
    logger.info(f"DB rotation complete: switched to user {inactive} ({inactive_username})")
    return data, ["db"], {"db": details}


def _publish_to_rabbitmq(payload: dict, updated_sections: list[str]):
    """
    Publish rotation event to RabbitMQ following the standard routing pattern.
    
    RabbitMQ Standard (README §2):
    - Exchange: secret-rotation (topic, durable)
    - Routing key (main): rotation – one message per run with full payload
    - Routing key (per section): rotation.db, rotation.keycloak – same payload, per-section routing
    """
    connection = None
    try:
        params = pika.URLParameters(RABBITMQ_URL)
        connection = pika.BlockingConnection(params)
        channel = connection.channel()
        
        # Declare exchange (idempotent)
        channel.exchange_declare(
            exchange=RABBITMQ_EXCHANGE,
            exchange_type="topic",
            durable=True,
        )
        
        body = json.dumps(payload).encode("utf-8")
        
        # 1. Publish main message with routing key "rotation"
        channel.basic_publish(
            exchange=RABBITMQ_EXCHANGE,
            routing_key=RABBITMQ_ROUTING_KEY,  # "rotation"
            body=body,
            properties=pika.BasicProperties(
                delivery_mode=2,  # Make message persistent
                content_type="application/json"
            )
        )
        logger.info(f"Published to {RABBITMQ_EXCHANGE} with routing key '{RABBITMQ_ROUTING_KEY}'")
        
        # 2. Publish per-section messages with routing keys "rotation.db", "rotation.keycloak"
        for section in updated_sections:
            section_routing_key = f"{RABBITMQ_ROUTING_KEY}.{section}"
            channel.basic_publish(
                exchange=RABBITMQ_EXCHANGE,
                routing_key=section_routing_key,
                body=body,
                properties=pika.BasicProperties(
                    delivery_mode=2,
                    content_type="application/json"
                )
            )
            logger.info(f"Published to {RABBITMQ_EXCHANGE} with routing key '{section_routing_key}'")
        
        logger.info(f"RabbitMQ publish complete for sections: {updated_sections}")
        
    except Exception as e:
        logger.error(f"Failed to publish to RabbitMQ: {e}")
        # Don't fail the entire rotation if notification fails
        logger.warning("Rotation succeeded but RabbitMQ notification failed")
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                logger.warning("Failed to close RabbitMQ connection cleanly")

def lambda_handler(event, context):
    """
    Main Lambda handler for DB-only secret rotation.

    Workflow:
    1. Load current secret from Secrets Manager
    2. Rotate DB (alternating users with actual password change)
    3. Store updated secret
    4. Publish notification to RabbitMQ
    """
    logger.info("Starting DB secret rotation")

    # Load current secret
    current = secrets_client.get_secret_value(SecretId=SECRET_ID)
    try:
        data = json.loads(current["SecretString"])
    except (KeyError, json.JSONDecodeError) as e:
        logger.error("Secret is not valid JSON")
        raise ValueError("Secret must be JSON with db section") from e

    updated_sections = []
    details = {}

    # 1 Rotate DB (alternating user zero-downtime)
    try:
        data, db_sections, db_details = _rotate_db(data)
        updated_sections.extend(db_sections)
        details.update(db_details)
    except Exception as e:
        logger.error(f"DB rotation failed: {e}")
        raise

    if not updated_sections:
        logger.info("No sections rotated this run")
        return {"status": "ok", "updated_sections": []}

    # 2 Store updated secret
    try:
        secrets_client.put_secret_value(
            SecretId=SECRET_ID,
            SecretString=json.dumps(data),
        )
    except Exception as e:
        logger.error("Failed to persist rotated credentials to Secrets Manager")
        raise RuntimeError(
            "DB password was rotated but secret update failed; manual reconciliation required."
        ) from e
    logger.info(f"Stored updated secret; rotated sections: {updated_sections}")

    # 3 Publish to RabbitMQ
    timestamp = datetime.now(timezone.utc).isoformat()
    payload = {
        "event": "SECRET_ROTATED",
        "secret_id": SECRET_ID,
        "timestamp": timestamp,
        "updated_sections": updated_sections,
        "details": details,
    }

    _publish_to_rabbitmq(payload, updated_sections)

    logger.info(f"DB rotation complete. Updated sections: {updated_sections}")
    return {
        "status": "ok",
        "updated_sections": updated_sections,
        "timestamp": timestamp
    }
