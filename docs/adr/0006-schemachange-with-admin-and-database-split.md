# 0006. schemachange, with account objects and database objects deployed separately

Date: 2026-11-12
Status: Accepted

## Context

The SQL in this repo creates two kinds of objects. Account objects (roles,
warehouses, resource monitors, integrations, the database) need
SECURITYADMIN, SYSADMIN or ACCOUNTADMIN. Database objects (tables, pipes,
streams, tasks, policies, views) need only the database's owner role. A
deployment that can do the first can do anything in the account.

## Decision

- **schemachange** deploys both: versioned scripts (`V…__`) run once, and
  repeatable scripts (`R__…`) run again whenever their rendered text
  changes.
- **Two roots, two pipelines.**
  - `migrations/admin` is deployed by hand (`admin.yml`), per environment,
    with a privileged user and required reviewers.
  - `migrations/database` is deployed on every merge (`deploy.yml`): to dev,
    then to prd after approval. It runs as `RL_<env>_DEPLOYER`, which owns
    the database and nothing else.
- **Tasks, the mart and OPS views are repeatable.** They are replaced
  wholesale, so their script is their current definition. Tables, pipes,
  streams and policies are versioned, because replacing them loses data,
  load history, offsets or attachments.
- **Transforms are Jinja includes.** `R__tasks.sql` includes the files in
  `transform/`, so the SQL the tests run (ADR-0007) is byte for byte the SQL
  the tasks run. schemachange checksums the rendered script, so changing a
  transform redeploys the tasks.
- Environment values (sizes, quotas, storage account) live in
  `deploy/envs/<env>.json` and are passed with `--vars`. Values common to
  every environment live in the config's `vars`.

## Consequences

- A deploy of database objects can never create a warehouse or grant an
  account role. The cost is a second, manual pipeline for account changes.
- Recreating the task graph on every transform change briefly suspends it.
  A run in progress finishes first (runbook section 3).
- schemachange keeps no rollback. A bad versioned script is fixed by a new
  one, and a bad repeatable by reverting the commit.
- schemachange 4.0 is pinned. Its connection settings come from a
  `connections.toml` written by the workflow from secrets (key-pair auth).
