# 0007. Test the Snowflake SQL on DuckDB, against an independent model

Date: 2026-11-12
Status: Accepted

## Context

Most mistakes in a pipeline like this are logic, not syntax: a stale row
applied as a change, a status overwritten by an older event, a line keyed
to the wrong customer version. Running every change against a Snowflake
account costs credits, needs credentials in CI, and is slow to set up from a
fresh clone.

## Decision

- **The transforms run on DuckDB.** sqlglot translates them from Snowflake
  SQL. The DDL comes from the migrations themselves.
- **A simulation stands in for what DuckDB lacks.** Snowpipe is a loader
  that inserts what each pipe's COPY would. A stream is a table holding rows
  added since the last committed run. The simulation runs the task graph
  once per day of generated files.
- **An independent model.** `tests/expected.py` works out in plain Python,
  from the landing files, what CORE should hold: customer versions, stale
  rows, statuses, lines and the version each line points at. The tests
  compare the two. They also reload a day and check that CORE does not
  change.
- **Snowflake-only scripts are checked statically.** Every script renders
  for every environment and parses. Pipe columns match the tables and the
  generator's files. The task graph matches the simulation's order. Every
  warehouse has a monitor. Every schema is granted through an access role.
  The MART views run on DuckDB.

## Consequences

- The tests run in a few seconds without an account, and the full 90 days
  run in CI.
- Three translations sqlglot does not do are patched in `sim/engine.py`:
  sequence `NEXTVAL`, `TIMESTAMP_LTZ` and `VARIANT`. Any other construct
  that does not translate fails the run. That rules out Snowflake features
  in the transforms that DuckDB lacks (for example `FLATTEN`), which ADR-0001
  avoided.
- What this cannot catch: Snowflake behaviour that differs from DuckDB's,
  such as MERGE's handling of a target row matched twice (an error in both
  here), task scheduling, stream staleness, policies, grants, and pipes. The
  first deployment to dev is the real check of those (open issue 1).
- The model agreeing with the SQL proves they implement the same rules. It
  does not prove the rules are what the business wants.
