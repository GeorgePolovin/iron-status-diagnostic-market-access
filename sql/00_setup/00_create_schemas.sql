-- Source schemas
CREATE SCHEMA IF NOT EXISTS nhanes;
CREATE SCHEMA IF NOT EXISTS meps;
CREATE SCHEMA IF NOT EXISTS synthea;

-- Project-created schemas
CREATE SCHEMA IF NOT EXISTS reference;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS mart;

-- Confirm creation
SELECT schema_name
FROM information_schema.schemata
WHERE schema_name IN (
    'nhanes',
    'meps',
    'synthea',
    'reference',
    'analytics',
    'mart'
)
ORDER BY schema_name;