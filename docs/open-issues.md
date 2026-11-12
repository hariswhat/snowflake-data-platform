# Open issues

Known gaps, in the order they should be closed. The numbers are referenced
from ADRs and code comments, so they do not change when an issue closes.

## 1. Never deployed to Snowflake

Everything Snowflake-only is checked statically: it renders, it parses with
sqlglot's Snowflake dialect, and its names and columns line up. It has not
run. That covers pipes, stages, streams, tasks, the dynamic table, policies,
grants, alerts and integrations. The transforms have run only on DuckDB.

Close by: a trial account (Enterprise, for tag-based masking), the admin
and database deployments to dev, and a week of generated files uploaded to
the container. Then record what differed here.

## 2. Monitoring views over INFORMATION_SCHEMA table functions

`OPS.TASK_FAILURE` and `OPS.PIPE_LOAD_ERROR` are views over `TASK_HISTORY`
and `COPY_HISTORY` table functions, so the alerts see failures without the
ACCOUNT_USAGE delay. Not verified:

- what these functions return inside a view queried by a serverless alert,
  running as the alert's owner;
- that `COPY_HISTORY` reports a file a pipe skipped with `status <> 'Loaded'`.

If either fails, the fallback is ACCOUNT_USAGE views, with up to a few
hours' delay on alerts.

## 3. Serverless spend has no hard limit

Resource monitors cover warehouses only. Snowpipe and the serverless alerts
are visible in `OPS.CREDITS_BY_DAY` (Snowpipe) or the account's metering
views, but nothing stops them. Close by: a Snowflake budget on the account,
or a custom budget on the database, with a notification.

## 4. The cost estimate is placeholders

`cost/inputs.yml` estimates run times, refresh counts and BI hours. The
model is a method until a month of `OPS.CREDITS_BY_DAY` replaces the
estimates (docs/cost-estimate.md).

## 5. History corrections are manual

Only forward changes become customer history. A stale CRM row is logged to
`OPS.LATE_ARRIVAL` and skipped. Back-dating a version is the manual
procedure in runbook section 6. Products are type 1, so sales by category
use today's category. Making products type 2 is the change if category
history matters.

## 6. Region access needs an owner

`GOVERNANCE.REGION_ACCESS` is empty after deployment. Rows are inserted by
an engineer (runbook section 7), not by a script. The table is a grant
list and needs the same owner and periodic review as role grants. An
empty table means analysts without `_ALL_REGIONS` see no rows.

## 7. Re-key window and stream staleness are fixed limits

- The fact task re-keys lines for customer versions changed in the last 7
  days. A graph stopped longer needs the re-key run by hand.
- A stream not consumed within 14 days goes stale.

Both are in runbook section 5, and neither is detected automatically. A
check on the oldest unconsumed stream offset (`STALE_AFTER` in `SHOW
STREAMS`) would warn before it happens.

## 8. One alert recipient, e-mail only

Alerts go to one address per environment, which must be a verified user's
e-mail. There is no paging integration and no escalation.
