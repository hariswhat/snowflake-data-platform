# Cost estimate

Credits, not money: credits times the contract's price per credit gives
money, and that price depends on edition, region and contract. The numbers
come from `python -m cost.model --env <env>`. Their output is kept in
`docs/measured/cost-prd.txt` and `cost-dev.txt`, and a test fails if they go
stale.

## Method

A warehouse bills per second while it runs. It bills at least 60 seconds
each time it resumes, and it keeps running for AUTO_SUSPEND seconds after
the last query. A workload that wakes a warehouse N times a day for d
seconds costs:

    N x max(60, d + auto_suspend) seconds x credits per hour / 3600

The model assumes no two workloads share a resume. For scheduled work, that
makes it an upper bound.

Inputs (`cost/inputs.yml`):

- **Facts.** Credits per hour by size, the 60-second minimum, and values
  read from this repo's SQL and generator: the schedule, auto-suspend, and
  hours with files. `test_inputs_match_the_sql` checks the SQL values
  against the scripts.
- **Estimates.** Task graph run time, dynamic table refresh time and count,
  BI active hours, ad hoc hours. Nobody has measured these (open issue 4).

## Monthly credits

| Line | dev | prd | Where it runs |
| --- | ---: | ---: | --- |
| Task graph (18 runs a day, 45 s + 60 s suspend) | 15.8 | 15.8 | WH_TRANSFORM, XSMALL |
| Dynamic table refresh (18 a day, 20 s + 60 s) | 12.0 | 12.0 | WH_TRANSFORM |
| BI (1 h a day dev, 6 h a day prd) | 32.5 | 365.0 | WH_BI, XSMALL dev, SMALL prd |
| Ad hoc | 20.0 | 10.0 | WH_ADHOC, XSMALL |
| **Total, warehouses** | **80.3** | **402.8** | |
| Not incurred: the two alerts on WH_TRANSFORM, upper bound | 25.2 | 25.2 | serverless instead |

Monitor quotas (`deploy/envs/<env>.json`, applied by
`migrations/admin/R__warehouse_sizes_and_quotas.sql`) against these:

| Monitor | dev quota | prd quota | prd estimate |
| --- | ---: | ---: | ---: |
| RM_<env>_TRANSFORM | 40 | 40 | 27.8 |
| RM_<env>_BI | 40 | 400 | 365.0 |
| RM_<env>_ADHOC | 30 | 20 | 10.0 |

`test_resource_monitor_quotas_cover_the_estimate` fails if an estimate
exceeds its quota.

## Not in the model

- **Snowpipe.** It is serverless, and its rate is per file and per compute
  second, which depends on file size and the contract. It is reported by
  source in `OPS.CREDITS_BY_DAY` instead of estimated. At 1,894 files over
  90 days (`docs/measured/landing-90d.json`), about 21 files a day, it is
  expected to be small next to BI. That has not been measured.
- **Serverless alerts.** Two alerts at 24 checks a day each. Billed as
  serverless compute; not modelled.
- **Storage.** RAW keeps every file's rows. At this volume it is a rounding
  error in credits, but Time Travel (7 days in prd) and Fail-safe add to it.
- **Cloud services.** Billed only above 10% of daily warehouse credits.
  Hourly `WHEN` checks on the root task run in cloud services.

## What drives the cost

BI is 365 of 402.8 prd credits. Halving BI hours or running BI at XSMALL
moves the total more than any change to the transforms. The first month's
`OPS.CREDITS_BY_DAY` decides whether SMALL is needed (open issue 4).

The alerts decision (ADR-0005): on the transform warehouse, 48 checks a day
could each pay the 60-second minimum. That is at most 25.2 credits a month,
and about half that if the two alerts shared each resume, against the task
graph's 15.8. Serverless alerts bill for the compute they use. Their cost
is not estimated here, and the first month of metering decides whether the
choice was right.

## Checking the estimate

After a month in prd:

```sql
SELECT source, SUM(credits) AS credits
FROM RIDGELINE_PRD.OPS.CREDITS_BY_DAY
WHERE usage_date >= DATEADD(DAY, -30, CURRENT_DATE())
GROUP BY source
ORDER BY credits DESC;
```

Replace the estimates in `cost/inputs.yml` with what this shows, rerun the
model, and adjust the monitor quotas.
