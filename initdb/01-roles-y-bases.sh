#!/bin/bash
# Corre UNA sola vez, cuando el volumen pgdata está vacío.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    CREATE ROLE odoo      LOGIN PASSWORD '${ODOO_PG_PASSWORD}' CREATEDB;
    CREATE ROLE nodered_w LOGIN PASSWORD '${NODERED_PG_PASSWORD}';
    CREATE ROLE dash_r    LOGIN PASSWORD '${DASH_PG_PASSWORD}';

    CREATE DATABASE odoo    OWNER odoo;
    CREATE DATABASE nodered OWNER nodered_w;
SQL

# --- Base nodered: extensión + permisos de solo lectura para Dash y Odoo ---
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname nodered <<-SQL
    CREATE EXTENSION IF NOT EXISTS timescaledb;
    CREATE EXTENSION IF NOT EXISTS postgres_fdw;

    GRANT CONNECT ON DATABASE nodered TO dash_r, odoo;
    GRANT USAGE   ON SCHEMA public    TO dash_r, odoo;

    -- Solo lectura, también sobre lo que se cree después
    ALTER DEFAULT PRIVILEGES FOR ROLE nodered_w IN SCHEMA public
        GRANT SELECT ON TABLES TO dash_r, odoo;
SQL

# --- Base odoo: Dash puede leer, nada más ---
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname odoo <<-SQL
    CREATE EXTENSION IF NOT EXISTS postgres_fdw;

    GRANT CONNECT ON DATABASE odoo TO dash_r;
    GRANT USAGE   ON SCHEMA public TO dash_r;

    ALTER DEFAULT PRIVILEGES FOR ROLE odoo IN SCHEMA public
        GRANT SELECT ON TABLES TO dash_r;
SQL

echo "Roles y bases creados: odoo, nodered"
