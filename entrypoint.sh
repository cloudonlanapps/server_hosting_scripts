#!/bin/bash
set -e

if [ -z "$PROJECT_NAME" ]; then
    echo "ERROR: PROJECT_NAME environment variable is not set"
    exit 1
fi

echo "==> Waiting for PostgreSQL to be ready..."

# Wait for PostgreSQL to accept connections
until pg_isready -h db -U "$POSTGRES_USER" -d "$POSTGRES_DB" > /dev/null 2>&1; do
    echo "    Waiting for database..."
    sleep 2
done

# Additional wait for database to be fully ready
until PGPASSWORD="$POSTGRES_PASSWORD" psql -h db -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" > /dev/null 2>&1; do
    echo "    Database accepting connections, waiting for readiness..."
    sleep 1
done

echo "    PostgreSQL is ready."

echo "==> Running database migrations..."
uv run alembic upgrade head

echo "==> Bootstrapping sudo user..."
uv run ${PROJECT_NAME}_bootstrap "$BOOTSTRAP_PASSWORD"

echo "==> Starting server..."
exec uv run uvicorn ${PROJECT_NAME}_server.main:app --host 0.0.0.0 --port 8000
