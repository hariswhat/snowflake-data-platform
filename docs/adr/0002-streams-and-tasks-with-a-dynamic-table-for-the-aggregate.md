# 0002. Streams and tasks for dimensions and facts; a dynamic table for the aggregate

Date: 2026-11-12
Status: Accepted

## Context

Between RAW and what reports read, the platform keeps history (customer
changes as SCD type 2), applies events that arrive late and out of order,
and computes a daily aggregate. Options:

- **Streams and tasks.** A stream on each RAW table tracks what has not been
  processed, and a graph of tasks runs MERGE statements.
- **Dynamic tables.** Declarative and refreshed by Snowflake. But each
  refresh recomputes the table's query from its inputs, so a dynamic table
  can only show state derived from the data it reads. SCD type 2 history,
  where a version's end depends on the order changes arrived in, is not
  something a query over RAW can produce once RAW holds stale rows.
- **dbt on a schedule.** Snapshots give SCD 2, but it is another tool and
  scheduler for a team that deploys SQL with schemachange (ADR-0006).

## Decision

- Append-only streams on the three RAW tables.
- A task graph:
  - `T_ROOT` runs hourly, only when a stream has rows (`WHEN SYSTEM$STREAM_HAS_DATA`).
  - The product and customer tasks run after it.
  - The fact task runs after both, so new customers and products exist
    before lines look them up.
  - A data quality task runs last.
- Each transform runs in one explicit transaction. All its statements see
  the same stream rows, and the stream moves forward only if all of them
  succeed.
- A dynamic table, `CORE.DAILY_SALES`, for the aggregate, with a target lag
  of 2 hours, read through a secure view.

## Consequences

- A failed task leaves its stream where it was, and the next scheduled run
  processes the same rows plus the new ones. No rerun bookkeeping. The cost
  is that a bug that fails every run stops that branch of the graph. After
  three consecutive failures the root suspends itself
  (`SUSPEND_TASK_AFTER_NUM_FAILURES`), and the alert fires on the first.
- The `WHEN` clause is evaluated without a warehouse. An hour with no new
  files costs nothing.
- Tasks and the dynamic table share the transform warehouse. The dynamic
  table's refreshes are a separate cost line (ADR-0005).
- Changing a task means suspending the root, recreating and resuming the
  graph. `R__tasks.sql` does that on every deploy that changes a transform.
- Streams have a staleness limit (the table's data retention, extended up to
  14 days by default). A graph suspended for longer than that loses its
  stream offsets and needs a reload from RAW (runbook section 5).
