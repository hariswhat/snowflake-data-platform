# 0005. A warehouse per workload, each with a resource monitor; serverless alerts

Date: 2026-11-12
Status: Accepted

## Context

Snowflake bills a warehouse per second while it runs, with a 60-second
minimum each time it resumes, and the warehouse stays up for AUTO_SUSPEND
seconds after its last query. Cost surprises usually come from one workload
growing unnoticed on a shared warehouse, or from small frequent jobs that
each pay the 60-second minimum.

## Decision

- Three warehouses per environment:
  - `TRANSFORM` (tasks and the dynamic table), XSMALL, 60-second
    auto-suspend;
  - `BI` (Power BI and analysts), sized per environment, 300-second
    auto-suspend so a dashboard session stays warm;
  - `ADHOC` (engineers), XSMALL.
- Each warehouse has its own resource monitor. TRANSFORM and ADHOC suspend
  at 100% of their quota. BI only notifies at 100% and suspends at 150%,
  because stopping reports mid-month is worse than an overspend someone
  approves.
- Every warehouse has a statement timeout, so one runaway query cannot burn
  the quota.
- The two alerts are serverless. On the TRANSFORM warehouse their 48 hourly
  checks a day could each pay the 60-second minimum. The cost model puts
  that at up to 25.2 credits a month (about half if both checks shared a
  resume), against 15.8 for the task graph itself. Serverless alerts bill
  for the compute they use instead; that is not estimated here.
- `cost/model.py` estimates credits per warehouse from the schedules in the
  SQL and from run-time estimates. A test checks that each monitor's quota
  covers its estimate.
- Sizes and quotas live in `deploy/envs/<env>.json`. V1.0.1 creates the
  warehouses and monitors once; the repeatable
  `R__warehouse_sizes_and_quotas.sql` applies the current values whenever
  they change.

## Consequences

- Resource monitors do not cover serverless work: Snowpipe, serverless
  alerts. Their notifications go to account administrators who opted in,
  and to users named in `NOTIFY_USERS` (runbook section 1). `OPS.CREDITS_BY_DAY` reports Snowpipe credits next to the
  warehouses. A budget on the account is the control for the rest
  (open issue 3).
- The run times in the model are placeholders until a month of
  `OPS.CREDITS_BY_DAY` exists. The model is the method, not a measurement
  (docs/cost-estimate.md).
- BI at SMALL for six hours a day dominates the estimate: 365 of 403 prd
  credits a month. Sizing BI correctly is worth more than any transform
  tuning.
