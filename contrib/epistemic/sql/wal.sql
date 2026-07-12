-- wal.sql: verify the custom WAL resource manager is registered.
CREATE EXTENSION IF NOT EXISTS epistemic;
SELECT rm_name FROM pg_get_wal_resource_managers() WHERE rm_id = 128;
