# snowflake-data-platform

A Snowflake platform for a fictional retailer, Ridgeline Outdoor Supply. It
covers:

- loading files from Azure Blob with Snowpipe;
- keeping customer history (SCD type 2) with streams and tasks, through late
  and out-of-order data;
- serving an aggregate from a dynamic table;
- governing access with database roles, tag-based masking and a row access
  policy;
- keeping cost inside resource monitors.

It deploys with schemachange. Every file the pipeline reads is written by
`generator/ridgeline.py`; every name, customer and number is synthetic.

The repository has not been deployed to a Snowflake account (open issue 1).
The transforms are tested by running them on DuckDB. The tests compare the
output against an independent Python model of the same rules. The
Snowflake-only objects are checked statically. ADR-0007 says what that does
and does not cover.

```
Azure Blob (orders hourly, customers and products daily)
  -> Snowpipe (typed COPY, payload + file name + row number)
  -> RAW tables + append-only streams
  -> task graph, hourly when a stream has rows
       T_DIM_PRODUCT (type 1) | T_DIM_CUSTOMER (SCD2)
       -> T_FACT_ORDER_LINE (point-in-time keys, newest status)
       -> T_DATA_QUALITY (7 checks)
  -> CORE  -> dynamic table DAILY_SALES (2 h lag)
  -> MART secure views (rows by region, PII masked)  -> Power BI
```

## What the generated data contains

`python -m generator.ridgeline --out landing --days 90 --scale 1.0`
(`docs/measured/landing-90d.json`):

| | |
|---|---:|
| Days | 90 |
| Landing files | 1,894 |
| Orders | 40,500 |
| Order lines | 80,867 |
| Order events | 158,634 |
| Customers / CRM rows | 3,000 / 4,548 |
| Customer attribute changes | 1,475 |
| Products / price changes | 400 / 360 |

Planted problems the pipeline has to handle:

| Problem | Count |
|---|---:|
| Order events sent twice | 812 |
| Orders whose status event arrives before the order | 401 |
| CRM rows re-sent after a newer one (stale) | 73 |
| Customers who reach the CRM export after their first order | 22 |
| Order lines for a product not in the catalogue | 151 |
| Cancelled orders | 2,002 |

## What the pipeline produces

`python -m sim.run --days 90 --scale 1.0` runs the task graph once per day
of files on DuckDB (`docs/measured/sim-90d.json`; CI fails if a run
differs):

| | |
|---|---:|
| Customer versions / current | 4,475 / 3,000 |
| Fact order lines | 80,867 |
| Orders | 40,500 |
| Stale CRM rows logged to `OPS.LATE_ARRIVAL` | 72 |
| Lines on the unknown customer after 90 days | 0 |
| Lines on the unknown product | 151 |
| Net sales excluding cancelled | 57,412,014.97 |
| Error-severity check failures, any day | 0 |

Every order line is in the fact once, despite 812 duplicate events.
Customers who arrived late were re-keyed. 72 of the 73 stale rows were
logged and skipped. The 73rd arrived in the same export as a newer row for
the same customer, so the newer one won within the batch (ADR-0003). The
151 lines for unknown products stay on -1, and a warning check reports
them.

The tests (`tests/test_pipeline.py`, at 30 days and a fifth of the scale)
compare CORE with `tests/expected.py`:

- customer versions;
- stale rows;
- statuses;
- amounts;
- the customer version each line points at;
- daily sales totals.

They also reload a day of files and check that CORE does not change.

## Cost

`python -m cost.model --env prd` estimates monthly credits per warehouse.
The run times in it are estimates (open issue 4):

| | prd credits / month | Monitor quota |
|---|---:|---:|
| Transform (task graph 15.8, dynamic table 12.0) | 27.8 | 40 |
| BI (SMALL, 6 h a day) | 365.0 | 400 |
| Ad hoc | 10.0 | 20 |

The two alerts are serverless. On the transform warehouse, their 48 checks
a day would cost 25.2 credits a month, more than the task graph. Snowpipe is
reported in `OPS.CREDITS_BY_DAY`, not estimated
([docs/cost-estimate.md](docs/cost-estimate.md)).

## Decisions

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-snowpipe-auto-ingest-with-typed-copy.md) | Snowpipe auto-ingest, typed at load, original record kept |
| [0002](docs/adr/0002-streams-and-tasks-with-a-dynamic-table-for-the-aggregate.md) | Streams and tasks for dimensions and facts; a dynamic table for the aggregate |
| [0003](docs/adr/0003-scd2-in-one-merge-and-late-arriving-data.md) | Customer history in one MERGE; late and out-of-order data handled explicitly |
| [0004](docs/adr/0004-access-roles-and-tag-based-masking.md) | Database roles for access, account roles for people; masking by tag, rows by region |
| [0005](docs/adr/0005-warehouse-per-workload-and-cost-controls.md) | A warehouse per workload with a resource monitor; serverless alerts |
| [0006](docs/adr/0006-schemachange-with-admin-and-database-split.md) | schemachange, account objects and database objects deployed separately |
| [0007](docs/adr/0007-test-snowflake-sql-on-duckdb.md) | Test the Snowflake SQL on DuckDB against an independent model |

Also:

- [C4 diagrams](docs/architecture/c4.md)
- [non-functional requirements](docs/architecture/nfr.md)
- [cost](docs/cost-estimate.md)
- [runbook](docs/runbook/README.md)
- [open issues](docs/open-issues.md)

## Layout

| Path | What |
|---|---|
| `generator/` | Landing files for the fictional retailer |
| `migrations/admin/` | Roles, warehouses, monitors, database, integrations (account level) |
| `migrations/database/` | Schemas, access roles, RAW, pipes, streams, CORE, policies (versioned); tasks, mart, OPS (repeatable) |
| `transform/` | The SQL each task runs, and the data quality checks; included into `R__tasks.sql` |
| `deploy/` | schemachange configs and per-environment values |
| `sim/` | Runs the migrations' tables and the transforms on DuckDB |
| `cost/` | Credit model and its inputs |
| `tests/` | Pipeline against the model; static checks of the migrations; cost |

## Run it

```bash
make setup     # Python 3.11+, pinned requirements, pre-commit hooks
make test      # pytest, under 20 s
make sim       # the full 90 days on DuckDB; prints the summary above
make cost
make lint      # ruff, sqlfluff on transform/
```

Deploying needs a Snowflake account and an Azure storage account. See
[runbook section 1](docs/runbook/README.md#1-first-time-setup-of-an-environment).

## Known limitations

- **Never run on Snowflake.** That covers pipes, tasks, policies, grants,
  alerts and the dynamic table. Snowflake behaviour that differs from
  DuckDB's would not show up in the tests.
- **Stale CRM rows are logged, not applied.** Correcting history is manual
  (runbook section 6).
- **Products are type 1.** Sales by category use today's category.
- **Late customers re-key automatically for 7 days.** After a longer
  outage, the re-key is run by hand. A stream unread for 14 days goes
  stale, and recovery is a reload from RAW (runbook section 5). Neither
  is detected automatically.
- **No hard limit on serverless spend.** Monitors cover warehouses only
  (open issue 3).
- **The cost model's run times and BI hours are estimates** until a month
  of `OPS.CREDITS_BY_DAY` exists.
- **Region access is a table of rows maintained by hand** (open issue 6).
- **Alerts are e-mail to one address.** There is no paging.

## What I'd change at 10x

At 10 times the generated volume (4,500 orders a day instead of 450, about
270,000 order lines a month), or ten sources instead of three:

- **The fact MERGE and re-key.** The fact would be clustered by
  `order_date`. The fact task would MERGE only the dates in its batch.
  Before tuning either, I would measure their run time in `OPS.TASK_RUN`.
- **Per-source task graphs.** One graph means one failing source stops
  everything after it. I would give each source its own stream and graph,
  plus a final graph for cross-source facts, triggered by its upstream
  streams (`WHEN SYSTEM$STREAM_HAS_DATA`).
- **Ingestion.** If the shop moved to a stream of events, Snowpipe
  Streaming would replace files. That only pays if freshness needs to be
  under the hour.
- **Configuration over code for sources.** Pipes, tables and streams
  generated from a source list, as in the metadata-driven ingestion
  repository. With three sources, writing them by hand is simpler.
- **Cost attribution by query tag.** Each task would set a `QUERY_TAG`, and
  credits would be attributed per transform from `QUERY_ATTRIBUTION_HISTORY`
  rather than per warehouse.
- **Testing.** I would keep the DuckDB suite for logic, and add a nightly
  run against a dev clone with a day of real-sized files, to cover what
  ADR-0007 cannot.
- **What I would not change:** the SCD2 MERGE, the transaction per task, and
  the access-role model. Those scale with data, not with effort.
