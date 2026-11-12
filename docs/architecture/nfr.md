# Non-functional requirements

Targets are what the design is built for. **Measured** means a script in
this repo produced the number. Nothing here has been measured on Snowflake
(open issue 1).

| Area | Requirement | How the design meets it | Status |
| --- | --- | --- | --- |
| Freshness | An order event is in CORE within 75 minutes of its file landing | Snowpipe loads within minutes. The graph runs at :15 past each hour, so the worst case is a file landing just after a run starts | Target; not measured |
| Freshness | Daily sales within 2 hours of CORE | Dynamic table `TARGET_LAG = '2 hours'` | Target |
| Correctness | One current version per customer, no overlapping versions, every line's customer key resolves, one row per order line, fact status equals order status | Five error-severity checks (of eight) in `T_DATA_QUALITY` after every graph run; the task fails if any finds rows | Measured on DuckDB: 0 failing rows on all 90 days (`docs/measured/sim-90d.json`) |
| Correctness | CORE equals an independent model of the business rules | `tests/expected.py`, compared in `tests/test_pipeline.py` | Measured on DuckDB at test scale |
| Idempotence | Reloading files changes nothing in CORE | Insert-once fact, newest-event status, hash-compared SCD2 | Measured: `test_reprocessing_a_day_changes_nothing` |
| Late data | Lines of a customer who reaches the CRM export after the order re-key on the next run | Re-key of customer versions written in the last 7 days, `transform/order_line.sql` | Measured on DuckDB: 22 customers 1 to 2 days late, 0 lines on unknown customer after 90 days |
| Late data | Stale CRM rows never become history, and each is logged once | `source_updated_at` comparison; logged to `OPS.LATE_ARRIVAL` unless loaded before | Measured on DuckDB: 73 of 73 planted rows logged; a reload adds none |
| Late data | A stopped graph keeps every customer change when it resumes | Every newer row in a batch applied in order | Measured on DuckDB: `test_a_stopped_graph_keeps_every_customer_version` |
| Robustness to bad records | One incomplete order event does not stop the fact task | Kept out of the fact, written to `OPS.REJECTED_EVENT`, warning check | `test_an_incomplete_order_event_is_rejected_not_fatal` |
| Recovery | A failed task loses no data | Each task is one transaction; stream offset moves only on commit | Simulated on DuckDB; not tested on Snowflake |
| Recovery | Restart after an outage of up to 14 days without reload | Stream staleness limit: retention extended to 14 days | Snowflake default; runbook section 5 beyond that |
| Security | Nobody reads PII unless granted `RL_<env>_PII_READER` (the deploy role is, to run the transforms) | Tag-based masking on `email`, `full_name` in RAW and CORE | Static check: all four columns tagged; policy not run (needs Snowflake) |
| Security | Analysts see only their regions | `RAP_REGION` on every MART view | Static check: every MART view has the policy |
| Security | No engineer or analyst can grant on objects | Managed access schemas; one owner role. SECURITYADMIN and MANAGE GRANTS still can | Static checks: every schema managed; no object granted to an account role |
| Security | No passwords in CI | Key-pair auth; keys in GitHub environment secrets | Workflows |
| Cost | prd under 403 credits a month at current estimates | Warehouse per workload, monitors, serverless alerts | Estimate, not measured (`docs/cost-estimate.md`) |
| Cost | No warehouse exceeds its monitor quota unnoticed | TRANSFORM and ADHOC suspend at 100%; BI notifies at 100% and suspends at 150%; notifications to `NOTIFY_USERS` (runbook section 1) | `test_resource_monitor_quotas_cover_the_estimate` |
| Operability | On-call is told about a failed task or load within an hour | Two serverless alerts, hourly, over what completed since the last successful check | Not tested on Snowflake |
| Deployability | A fresh clone runs every test without a Snowflake account | DuckDB simulation | Measured: CI |
| Retention | RAW keeps everything loaded; Time Travel 7 days in prd, 1 in dev | `retention_days` per environment | Configuration |

Scale tested: 90 days, 40,500 orders, 80,867 order lines, 158,634 order
events (`docs/measured/landing-90d.json`). The full run took about 20
seconds on DuckDB in the CI-sized container it was developed in. That says nothing about
Snowflake run times.
