-- KNDB engine — first-boot bootstrap for the ProvSQL image.
-- The inriavalda/provsql image ships a pre-initialized PGDATA and so ignores
-- POSTGRES_USER / POSTGRES_DB env vars from docker-compose. This script runs
-- against the default `postgres` superuser to create the kndb role and db
-- with the extensions loaded. Idempotent.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kndb') THEN
    CREATE ROLE kndb LOGIN SUPERUSER PASSWORD 'kndb';
  END IF;
END $$;

SELECT 'CREATE DATABASE kndb OWNER kndb'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'kndb')
\gexec
