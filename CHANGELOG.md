# Changelog

Changes to this repository, newest first. Dates are commit dates.

## 2026-11-12 (review fixes)

A review of the SQL against Snowflake's behaviour, and of the docs against
the code, found these. Versioned scripts were corrected in place, which is
only acceptable because nothing has been deployed yet (open issue 1).

- Customer history lost changes when one run covered several CRM exports
  (a stopped graph): only the newest row per customer was applied. Every
  newer row is now applied in order. A test runs four days per batch
  against the model. All 73 planted stale rows are now logged; before,
  one was lost inside its batch.
- Reloading CRM files logged every reloaded row as stale. Rows loaded
  before are no longer logged, and the reload test checks the log too.
- A status tie on event time between two runs went to whichever event
  arrived first; it now goes to the later step, as within a run.
- An ORDER_CREATED event missing a required field would fail the fact task
  on every run. It now goes to `OPS.REJECTED_EVENT`, with a warning check.
- The row access policy's argument had the same name as the mapping
  table's column. Inside the subquery the column wins, so any mapped role
  would have seen every region. The argument is now `row_region`, and a
  test checks the names differ.
- The deploy role could not put the masking policy on the tag without
  `APPLY MASKING POLICY` on the account; granted, and its reach recorded
  as open issue 9.
- The failed-task alert compared scheduled times, so a task that failed
  after a check but was scheduled before it was never reported. Both
  alerts now compare completion times.
- The admin deployment had no warehouse for schemachange's own queries.
- Changing a size or quota in `deploy/envs/<env>.json` had no effect after
  the first deployment. A repeatable admin script now applies them.
- Email and name in RAW are tagged and masked too. The deploy role reads
  them unmasked, to copy them to CORE.
- Engineers are granted MONITOR on the tasks, for `OPS.TASK_FAILURE`.
- Docs:
  - the re-key window, which is about when versions were written;
  - the pipe change procedure, which now pauses, drains and refreshes from
    the pause time;
  - what managed access does and does not prevent;
  - the alerts cost, which is an upper bound;
  - resource monitor notifications.

## 2026-11-12

- Generator for a fictional retailer's landing files, with planted
  duplicates, stale CRM rows, late customers, status-before-order events
  and unknown products.
- Account and database migrations for schemachange. Snowpipe auto-ingest
  from Azure Blob, streams and a task graph, SCD type 2 customers, a type 1
  product dimension, and point-in-time fact keys with a 7-day re-key. Also
  a dynamic table for daily sales, tag-based masking, a row access policy
  by region, and secure MART views.
- Monitoring views, two serverless alerts and a credit model.
- Tests on DuckDB against an independent model; static checks of every
  migration; CI and deployment workflows.
- Docs: ADRs 0001 to 0007, C4, NFRs, cost estimate, runbook, open issues.
- Fixes found while writing the docs:
  - The database change history moved from `OPS` to its own schema.
    schemachange creates the history table's schema before any script
    runs, which would have created `OPS` without managed access.
  - The row access policy is now part of each MART view's CREATE. Before,
    it was a separate ALTER, which left a replaced view readable without
    the policy until the ALTER ran.
