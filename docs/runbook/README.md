# Runbook

`<ENV>` is `DEV` or `PRD`. Statements run as `RL_<ENV>_DEPLOYER` unless a
section says otherwise. None of this has been run against a real account yet
(open issue 1). Treat the first run of each section as a test of the
section.

1. [First-time setup of an environment](#1-first-time-setup-of-an-environment)
2. [Daily checks and alerts](#2-daily-checks-and-alerts)
3. [Deploying changes](#3-deploying-changes)
4. [Changing a pipe](#4-changing-a-pipe)
5. [A stopped task graph, stale streams, reload from RAW](#5-a-stopped-task-graph-stale-streams-reload-from-raw)
6. [Back-dating customer history](#6-back-dating-customer-history)
7. [Granting access](#7-granting-access)

## 1. First-time setup of an environment

Prerequisites:

- A Snowflake account on Enterprise edition or higher (tag-based masking).
- An Azure storage account (`storage_account` in `deploy/envs/<env>.json`)
  with a container `landing` and a storage queue (`landing_queue`).
- An Event Grid subscription for `Microsoft.Storage.BlobCreated` on the
  container, delivering to the queue.

Once per account, as ACCOUNTADMIN, before the first admin deployment:

```sql
-- Change history for the admin deployment, and a warehouse for
-- schemachange's own queries. Created by hand because the admin scripts are
-- what create everything else.
CREATE DATABASE IF NOT EXISTS RIDGELINE_ADMIN;
CREATE WAREHOUSE IF NOT EXISTS WH_RIDGELINE_ADMIN
    WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 INITIALLY_SUSPENDED = TRUE;

-- Service users, key-pair auth only. Paste the public keys.
CREATE USER IF NOT EXISTS SVC_RIDGELINE_ADMIN TYPE = SERVICE RSA_PUBLIC_KEY = '<key>';
GRANT ROLE ACCOUNTADMIN TO USER SVC_RIDGELINE_ADMIN;
```

In GitHub:

- Repository variable `SNOWFLAKE_ACCOUNT`. Until it is set, `deploy.yml`
  runs CI only.
- Environments `admin-dev`, `admin-prd`, `dev` and `prd`. Required reviewers
  on `admin-*` and `prd`.
- Secret `SNOWFLAKE_ADMIN_PRIVATE_KEY` on the `admin-*` environments, and
  `SNOWFLAKE_PRIVATE_KEY` on `dev` and `prd` (one key pair per environment).

Then, per environment:

1. Run the **admin** workflow for the environment. It creates the roles,
   warehouses, monitors, database and integrations.
2. Create the deploy user and give it the deploy role. As SECURITYADMIN:

   ```sql
   CREATE USER IF NOT EXISTS SVC_RIDGELINE_<ENV>_DEPLOY TYPE = SERVICE
       RSA_PUBLIC_KEY = '<key>' DEFAULT_ROLE = RL_<ENV>_DEPLOYER;
   GRANT ROLE RL_<ENV>_DEPLOYER TO USER SVC_RIDGELINE_<ENV>_DEPLOY;
   ```

3. Give Snowflake access to Azure. As ACCOUNTADMIN:
   - `DESC STORAGE INTEGRATION SI_<ENV>_LANDING;` Open
     `AZURE_CONSENT_URL` and consent for the tenant. Then give the app
     named in `AZURE_MULTI_TENANT_APP_NAME` the **Storage Blob Data Reader**
     role on the container.
   - `DESC NOTIFICATION INTEGRATION NI_<ENV>_LANDING;` Consent the same
     way. Then give its app the **Storage Queue Data Message Processor**
     role on the queue.
4. Have the owner of `alert_email` verify that address in Snowsight.
   `SYSTEM$SEND_EMAIL` sends only to verified addresses. Resource monitor
   notifications go only to account administrators who opted in, and to
   users named on the monitor. As ACCOUNTADMIN, name the on-call users
   (they also need verified e-mail addresses):

   ```sql
   ALTER RESOURCE MONITOR RM_<ENV>_TRANSFORM SET NOTIFY_USERS = (<user>, <user>);
   ALTER RESOURCE MONITOR RM_<ENV>_BI SET NOTIFY_USERS = (<user>, <user>);
   ALTER RESOURCE MONITOR RM_<ENV>_ADHOC SET NOTIFY_USERS = (<user>, <user>);
   ```
5. Run **deploy**: a push to `main`, or run it by hand. It creates the
   schemas, tables, pipes, streams, tasks, views and alerts, and resumes
   the task graph and the alerts.
6. Load files already in the container. A pipe only sees new blobs from
   its creation on:

   ```sql
   ALTER PIPE RAW.PIPE_PRODUCT REFRESH;
   ALTER PIPE RAW.PIPE_CUSTOMER REFRESH;
   ALTER PIPE RAW.PIPE_ORDER_EVENT REFRESH;
   ```

   `REFRESH` queues files staged in the last 7 days only. Older files need
   a one-off `COPY INTO RAW.<T>` with the same SELECT as the pipe's
   definition (V1.1.1), on `WH_<ENV>_ADHOC`. Restrict it with `PATTERN`
   to folders older than 7 days. A pipe's load history and a COPY's are
   kept separately, so a file in both ranges would load twice.
7. Add region mappings (section 7).

Check: `SELECT SYSTEM$PIPE_STATUS('RAW.PIPE_ORDER_EVENT');` shows
`executionState = RUNNING`. `SHOW TASKS IN SCHEMA CORE;` shows every task
`started`. After the next :15, `OPS.TASK_RUN` has a graph run.

## 2. Daily checks and alerts

The alerts e-mail on-call within an hour of a failed task or a file not
loaded. With no alert, a glance is enough:

```sql
-- Last day's graph runs; every task SUCCEEDED or SKIPPED
SELECT task_name, state, COUNT(*) FROM OPS.TASK_RUN
WHERE scheduled_time >= DATEADD(DAY, -1, CURRENT_TIMESTAMP())
GROUP BY 1, 2 ORDER BY 1, 2;

-- Data quality, last run
SELECT check_name, severity, failing_rows FROM OPS.DQ_RESULT
WHERE run_id = (SELECT run_id FROM OPS.DQ_RESULT ORDER BY checked_at DESC LIMIT 1)
ORDER BY severity, check_name;

-- Stale CRM rows skipped since yesterday (section 6 if one matters)
SELECT * FROM OPS.LATE_ARRIVAL WHERE logged_at >= DATEADD(DAY, -1, CURRENT_TIMESTAMP());

-- Order events kept out of the fact (a required field missing)
SELECT * FROM OPS.REJECTED_EVENT WHERE logged_at >= DATEADD(DAY, -1, CURRENT_TIMESTAMP());
```

A rejected event is the shop's to fix. When it re-sends the order with the
field filled in and a new event id, the line is loaded normally.

`OPS.TASK_RUN` reads ACCOUNT_USAGE and can be a few hours behind. For the
last hour, use `OPS.TASK_FAILURE`.

### "task failed"

1. `SELECT * FROM OPS.TASK_FAILURE ORDER BY scheduled_time DESC;`
2. **T_DATA_QUALITY**: the data is in CORE, but a check found rows. Find
   which with the DQ query above, and run the check's SQL from
   `transform/dq/<name>.sql` to see the rows. Fix the cause in a
   transform, and correct CORE with a reviewed script. The next run
   rechecks.
3. **Any other task**: its transaction rolled back, and its stream still
   holds the rows. Fix the cause and merge. The next hourly run processes
   the same rows plus the new ones. Nothing needs rerunning by hand.
4. After three failures in a row, the root suspends itself. A deploy
   resumes it only if it changes `R__tasks.sql` or a transform. After any
   other fix (data, a versioned script), resume it by hand:
   `SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('CORE.T_ROOT');`
5. If the graph was down for more than 14 days, or the fact task failed
   for more than 7 while the customer task ran, see section 5.

### "file not loaded"

1. `SELECT * FROM OPS.PIPE_LOAD_ERROR;` shows the file and the first
   error.
2. A file that does not match the agreed format is rejected whole
   (`SKIP_FILE`). Ask the source team to fix it and write it again under a
   **new name**. Snowpipe keeps 14 days of load history by file name and
   does not load a name it has seen again.
3. If the format changed on purpose, change the pipe (section 4).

## 3. Deploying changes

- **Database objects**: merge to `main`. `deploy.yml` runs CI, deploys
  dev, then waits for approval to deploy prd.
- **The task graph**: `R__tasks.sql` reruns whenever its rendered text
  changes, which includes any transform it includes. It suspends the root,
  recreates every task, and resumes the graph. A graph run already in
  progress finishes on the old definitions. Expect one skipped hour at
  most. A deploy that does not change it leaves the graph as it was,
  suspended or not.
- **The dynamic table**: `R__mart.sql` recreates `CORE.DAILY_SALES`, and
  its first refresh after that is a full one.
- **Account objects**: merge, then run **admin** for each environment.
  - A warehouse size or a monitor quota is a change to
    `deploy/envs/<env>.json`. `R__warehouse_sizes_and_quotas.sql` applies
    it.
  - Anything else (a new role, a new warehouse) is a new versioned script
    in `migrations/admin`.
- **A policy body**: a new versioned script with `ALTER ... SET BODY`
  (CONTRIBUTING).

There is no rollback. Revert the commit for a repeatable script, or write
a new versioned script for anything else.

## 4. Changing a pipe

A pipe's COPY cannot be altered; the pipe is replaced. A replaced pipe
starts with no queue and no load history, so the steps make sure no file is
missed or loaded twice. To add a column:

1. Pause the pipe and note the time:
   `ALTER PIPE RAW.PIPE_<T> SET PIPE_EXECUTION_PAUSED = TRUE;`
2. Wait until `SELECT SYSTEM$PIPE_STATUS('RAW.PIPE_<T>');` shows
   `pendingFileCount` 0. Files arriving now are not loaded.
3. Deploy a new versioned script that adds the column to `RAW.<T>`
   (`ALTER TABLE ... ADD COLUMN`) and replaces the pipe
   (`CREATE OR REPLACE PIPE ...` with the new SELECT). The table and its
   stream keep their data and offset. The new pipe starts running.
4. Load what arrived since step 1:
   `ALTER PIPE RAW.PIPE_<T> REFRESH MODIFIED_AFTER = '<time from step 1>';`
   This only reaches back 7 days. A longer pause needs a one-off COPY
   (section 1, step 6).
5. Backfill the new column for old rows from `payload` if needed (orders
   only; CSV sources have no payload).
6. Check `SYSTEM$PIPE_STATUS` again and, after the next file,
   `OPS.PIPE_LOAD_ERROR`.

If rows do load twice (a refresh without `MODIFIED_AFTER`, or a manual
`COPY ... FORCE = TRUE`), RAW has duplicates and CORE does not change: the
transforms deduplicate, and `test_reprocessing_a_day_changes_nothing`
checks that.

## 5. A stopped task graph, stale streams, reload from RAW

**Down for up to 14 days.** Resume (section 2, step 4). The next run
processes everything in the streams in one batch. Every customer change in
it becomes a version, in timestamp order. The customer task writes those
versions just before the fact task runs, so the fact's re-key covers them.

**The fact task failed for more than 7 days while the customer task ran.**
This can happen if the root was resumed by hand repeatedly. The re-key only
looks at customer versions written in the last 7 days, so run it once
without the window, as an engineer, on `WH_<ENV>_ADHOC`:

```sql
UPDATE CORE.FACT_ORDER_LINE AS f
SET customer_key = c.customer_key, updated_at = CURRENT_TIMESTAMP()
FROM CORE.DIM_CUSTOMER AS c
WHERE c.customer_id = f.customer_id
  AND f.order_ts >= c.valid_from
  AND f.order_ts < c.valid_to
  AND f.customer_key <> c.customer_key;
```

Then check that `fact_customer_key_resolves` returns no rows.

**Stream stale (down for more than 14 days).** `SHOW STREAMS IN SCHEMA
RAW;` shows `stale = true`. A stale stream cannot be read and has to be
recreated, and a new stream starts empty. RAW still has every row, so:

1. Suspend the root: `ALTER TASK CORE.T_ROOT SUSPEND;`
2. Note `MAX(loaded_at)` per RAW table from before the outage, then
   recreate the three streams (`CREATE OR REPLACE STREAM ...` as in
   V1.1.1).
3. Run each transform once by hand, with `RAW.<T>_STREAM` replaced by
   `(SELECT * FROM RAW.<T> WHERE loaded_at > '<noted time>')`. Order:
   product, customer, order. The transforms are idempotent, so including
   too much is safe; too little is not.
4. Run the re-key without its window (above), then the DQ checks.
5. Resume: `SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('CORE.T_ROOT');`

Open issue 7 tracks detecting this before it happens.

## 6. Back-dating customer history

A stale CRM row in `OPS.LATE_ARRIVAL` is not applied, on purpose
(ADR-0003). If the business confirms the old value should have been
history (for example, a region move that was entered late):

1. Agree, in writing, the attribute values and the period they were valid.
2. In one transaction:
   - end the version that covers the start of the period at the period's
     start;
   - insert the corrected version with a new key from
     `CORE.SEQ_CUSTOMER_KEY`;
   - insert a copy of the earlier version for the remainder, if the
     period ends before the next version;
   - set `changed_at = CURRENT_TIMESTAMP()` on every row touched.
3. Run the re-key without its window (section 5), so lines in the period
   point at the corrected version.
4. Run `dim_customer_one_current_version`,
   `dim_customer_versions_do_not_overlap` and `fact_customer_key_resolves`.
   All must return no rows.
5. The dynamic table refreshes within two hours.

## 7. Granting access

People get functional roles. Never grant objects directly. Managed access
stops object owners other than the schema owner from granting, but
SECURITYADMIN can still grant, so this is a rule for admins to keep. As
SECURITYADMIN:

| Need | Grant |
| --- | --- |
| Read MART, own regions only | `RL_<ENV>_ANALYST`, plus a mapping below |
| Read MART, all regions | `RL_<ENV>_ANALYST_ALL_REGIONS` |
| See email and name unmasked | `RL_<ENV>_PII_READER`, in addition |
| Engineer (RAW, CORE, OPS) | `RL_<ENV>_ENGINEER` |

Region mappings are rows. A regional team gets its own account role,
granted `RL_<ENV>_ANALYST`, and a row per region:

```sql
-- as SECURITYADMIN
CREATE ROLE IF NOT EXISTS RL_<ENV>_ANALYST_WEST;
GRANT ROLE RL_<ENV>_ANALYST TO ROLE RL_<ENV>_ANALYST_WEST;
-- as RL_<ENV>_DEPLOYER
INSERT INTO GOVERNANCE.REGION_ACCESS (role_name, region) VALUES ('RL_<ENV>_ANALYST_WEST', 'WEST');
```

Regions in the generated data: `NORTHEAST`, `SOUTHEAST`, `MIDWEST`,
`WEST`. Review the table with the role grants each quarter
(open issue 6).
