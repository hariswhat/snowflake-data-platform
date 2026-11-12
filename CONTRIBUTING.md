# Contributing

Conventions for this repository: how to change a transform, a table, a
policy or a check, and code style.

## Changing a transform

1. Edit the file in `transform/`. The same file is included into
   `R__tasks.sql` and run by the tests, so there is one copy.
2. If the business rule changed, change `tests/expected.py` first, and see
   the test fail.
3. `make test`, then `make sim`. If the summary changes on purpose,
   regenerate `docs/measured/sim-90d.json` and update the README tables:

   ```bash
   python -m sim.run --days 90 --scale 1.0 > docs/measured/sim-90d.json
   ```

4. Use only constructs that translate to DuckDB, or add the translation to
   `to_duckdb` in `sim/engine.py` with a comment (ADR-0007).

## Changing a table, pipe or stream

A new versioned script in `migrations/database`, `V<major>.<minor>.<patch>__<what>.sql`,
numbered after the last one. Never edit a versioned script that has been
deployed: schemachange will not run it again. A pipe change follows runbook
section 4. If the change adds a column to RAW, also change the generator
and `load_day` in `sim/engine.py`. `test_pipes_read_what_the_generator_writes`
checks that the three agree.

## Changing a policy

Masking and row access policies cannot be replaced while attached. Write a
new versioned script with `ALTER MASKING POLICY ... SET BODY ->` or
`ALTER ROW ACCESS POLICY ... SET BODY ->`, not an edit to V1.1.3.

## Adding a data quality check

1. `transform/dq/<name>.sql`: a SELECT that returns the failing rows, with
   a `-- severity: error` or `-- severity: warn` line.
2. Add it to `vars.dq_checks` in `deploy/schemachange-database.yml`.
   `test_dq_config_matches_the_check_files` fails if the two differ.
3. An error check fails the task and alerts. Use it only for something that
   must stop the line.

## Account objects

Roles, warehouses, monitors and integrations are in `migrations/admin` and
are deployed by hand (ADR-0006). A new warehouse needs a resource monitor
and auto-suspend; `test_every_warehouse_has_a_monitor_and_auto_suspend`
checks both. Change sizes and quotas in `deploy/envs/<env>.json`. The
repeatable `R__warehouse_sizes_and_quotas.sql` applies them on the next
admin deployment. Then rerun `python -m cost.model` for both environments
into `docs/measured/cost-<env>.txt`.

## Style

- Python: `ruff` for lint and format, line length 120.
- SQL: keywords upper case, identifiers upper case for objects and lower
  case for columns, leading commas. sqlfluff with the `snowflake` dialect
  lints `transform/` (`.sqlfluff`).
- Object names: `RL_<env>_*` account roles, `AR_*` database roles,
  `WH_<env>_*` warehouses, `RM_<env>_*` monitors, `T_*` tasks.

## Commits

- Imperative subject, about 50 characters, no trailing period.
- Body explains why, wrapped at 72.

## Documentation

- ADRs cover context, decision and consequences, including the costs the
  decision accepts.
- Numbers in the README come from a command in this repo, and
  `tests/test_readme.py` checks them.
