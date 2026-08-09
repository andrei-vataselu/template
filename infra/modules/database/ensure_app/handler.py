"""Ensure least-privilege Postgres role `app` exists (runs in VPC; uses master once).

Privilege model:
  - CONNECT on database
  - USAGE + CREATE on schema public — CREATE is required because the API
    bootstraps tables at runtime via CREATE TABLE IF NOT EXISTS
    (apps/backend/src/db/postgresStore.ts). Prefer moving DDL to a one-shot
    migration job later, then REVOKE CREATE ON SCHEMA public FROM app.
  - DML only on tables (SELECT/INSERT/UPDATE/DELETE) — not ALL
  - USAGE, SELECT on sequences (nextval) — not ALL
  - DEFAULT PRIVILEGES mirror the above for future objects owned by master
"""

from __future__ import annotations

import json
import secrets
import ssl
import urllib.request

import boto3
import pg8000.native


RDS_CA_URL = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
CA_PATH = "/tmp/rds-global-bundle.pem"


def _load_secret(arn: str) -> dict:
    client = boto3.client("secretsmanager")
    raw = client.get_secret_value(SecretId=arn)["SecretString"]
    return json.loads(raw)


def _ssl_context() -> ssl.SSLContext:
    urllib.request.urlretrieve(RDS_CA_URL, CA_PATH)
    ctx = ssl.create_default_context(cafile=CA_PATH)
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    return ctx


def _quote_ident(name: str) -> str:
    if not name.replace("_", "").isalnum():
        raise ValueError(f"refusing unsafe identifier: {name!r}")
    return name


def _dollar_quote(value: str) -> str:
    """SQL string literal that cannot break out of quoting."""
    while True:
        tag = "pwd" + secrets.token_hex(8)
        if tag not in value:
            return f"${tag}${value}${tag}$"


def handler(event, _context):
    master_arn = event["master_secret_arn"]
    app_arn = event["app_secret_arn"]

    master = _load_secret(master_arn)
    app = _load_secret(app_arn)

    app_user = _quote_ident(app["username"])
    dbname = _quote_ident(app.get("dbname") or "app")
    host = app["host"]
    port = int(app.get("port") or 5432)
    app_password_sql = _dollar_quote(app["password"])

    conn = pg8000.native.Connection(
        user=master["username"],
        password=master["password"],
        host=host,
        port=port,
        database=dbname,
        ssl_context=_ssl_context(),
    )
    try:
        exists = conn.run(
            "SELECT 1 FROM pg_roles WHERE rolname = :u",
            u=app_user,
        )
        if exists:
            conn.run(f"ALTER ROLE {app_user} WITH LOGIN PASSWORD {app_password_sql}")
        else:
            conn.run(f"CREATE ROLE {app_user} LOGIN PASSWORD {app_password_sql}")

        conn.run(f"GRANT CONNECT ON DATABASE {dbname} TO {app_user}")

        # Drop broad grants from earlier ensure_app revisions, then re-grant least privilege.
        conn.run(f"REVOKE ALL ON SCHEMA public FROM {app_user}")
        conn.run(f"REVOKE ALL ON ALL TABLES IN SCHEMA public FROM {app_user}")
        conn.run(f"REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM {app_user}")
        conn.run(
            f"ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM {app_user}"
        )
        conn.run(
            f"ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM {app_user}"
        )

        # CREATE kept for runtime schema bootstrap (see module docstring).
        conn.run(f"GRANT USAGE, CREATE ON SCHEMA public TO {app_user}")
        conn.run(
            f"GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO {app_user}"
        )
        conn.run(f"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {app_user}")
        conn.run(
            f"ALTER DEFAULT PRIVILEGES IN SCHEMA public "
            f"GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {app_user}"
        )
        conn.run(
            f"ALTER DEFAULT PRIVILEGES IN SCHEMA public "
            f"GRANT USAGE, SELECT ON SEQUENCES TO {app_user}"
        )
    finally:
        conn.close()

    return {"ok": True, "user": app_user, "host": host}
