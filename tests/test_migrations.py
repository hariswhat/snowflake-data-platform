"""Checks on the Snowflake-only scripts, which DuckDB cannot run: they render
for every environment, parse, and agree with each other and with the
generator and the simulation."""

import json
import logging
import re
from pathlib import Path

import pytest
import sqlglot
import yaml

from sim.engine import CONFIG, DQ, MIGRATIONS, ROOT, SCHEMAS, TASKS, TRANSFORM, load_checks, render, to_duckdb
from sim.sqlsplit import split

logging.getLogger("sqlglot").setLevel(logging.ERROR)
ADMIN = ROOT / "migrations" / "admin"
ENVS = ["dev", "prd"]


def env_vars(env: str) -> dict:
    return yaml.safe_load(CONFIG.read_text())["vars"] | json.loads(
        (ROOT / "deploy" / "envs" / f"{env}.json").read_text()
    )


# sqlglot does not parse a row access policy inside CREATE VIEW; the clause is
# removed before parsing or running a view on DuckDB. The governance test
# checks it is there.
RAP_CLAUSE = re.compile(r"\n\s*WITH ROW ACCESS POLICY \S+ ON \([^)]*\)")


def without_policy(stmt: str) -> str:
    return RAP_CLAUSE.sub("", stmt)


def statements(folder: Path, env: str = "dev") -> list[tuple[str, str]]:
    return [(f.name, s) for f in sorted(folder.glob("*.sql")) for s in split(render(f, env_vars(env)))]


@pytest.mark.parametrize("env", ENVS)
@pytest.mark.parametrize("folder", [ADMIN, MIGRATIONS], ids=["admin", "database"])
def test_every_script_renders_and_parses(folder, env):
    """StrictUndefined: a variable missing from the environment's file fails here."""
    for name, stmt in statements(folder, env):
        expr = sqlglot.parse_one(without_policy(stmt), read="snowflake")
        if re.match(r"(CREATE (OR REPLACE )?(TABLE|SECURE VIEW|VIEW)|INSERT|MERGE|UPDATE|SELECT)\b", stmt, re.I):
            assert not isinstance(expr, sqlglot.exp.Command), (name, stmt[:80])


def test_versioned_scripts_are_named_and_ordered():
    for folder in (ADMIN, MIGRATIONS):
        versions = []
        for f in folder.glob("*.sql"):
            m = re.fullmatch(r"(V(\d+)\.(\d+)\.(\d+)|R)__[a-z0-9_]+\.sql", f.name)
            assert m, f.name
            if m.group(2):
                versions.append(tuple(int(x) for x in m.groups()[1:]))
        assert len(versions) == len(set(versions))


def _tables(schema: str) -> dict[str, list[str]]:
    out = {}
    for _, s in statements(MIGRATIONS):
        m = re.match(rf"CREATE TABLE IF NOT EXISTS {schema}\.(\w+)\s*\((.*)\)\s*$", s, re.S | re.I)
        if m:
            out[m.group(1)] = [c.strip().lstrip(", ").split()[0].lower() for c in m.group(2).split("\n") if c.strip()]
    return out


def test_every_raw_table_has_a_pipe_and_a_stream_with_matching_columns():
    stmts = [s for _, s in statements(MIGRATIONS)]
    for table, cols in _tables("RAW").items():
        pipe = next(s for s in stmts if re.search(rf"CREATE PIPE .*COPY INTO RAW\.{table}\s*\(", s, re.S))
        copied = re.search(rf"COPY INTO RAW\.{table}\s*\((.*?)\)", pipe, re.S).group(1)
        assert [c.strip() for c in copied.split(",")] == cols, table
        select = re.search(r"SELECT(.*?)FROM @", pipe, re.S).group(1)
        assert len(_top_level_commas(select)) + 1 == len(cols), table
        assert any(re.match(rf"CREATE STREAM .* ON TABLE RAW\.{table} APPEND_ONLY = TRUE", s) for s in stmts), table


def _top_level_commas(text: str) -> list[int]:
    depth, out = 0, []
    for i, ch in enumerate(text):
        depth += ch == "("
        depth -= ch == ")"
        if ch == "," and depth == 0:
            out.append(i)
    return out


def test_pipes_read_what_the_generator_writes(tmp_path):
    from generator.ridgeline import Config, generate

    generate(tmp_path, Config(days=3, scale=0.05))
    keys = set()
    for f in tmp_path.glob("orders/*/*/*/*.json"):
        for line in f.read_text().splitlines():
            keys |= set(json.loads(line))
    stmts = [s for _, s in statements(MIGRATIONS)]
    order_pipe = next(s for s in stmts if "CREATE PIPE IF NOT EXISTS RAW.PIPE_ORDER_EVENT" in s)
    assert set(re.findall(r"\$1:(\w+)", order_pipe)) == keys
    for pipe, kind in (("PIPE_CUSTOMER", "customers"), ("PIPE_PRODUCT", "products")):
        text = next(s for s in stmts if f"RAW.{pipe}" in s)
        header = next(tmp_path.glob(f"{kind}/*/*/*/*.csv")).read_text().splitlines()[0].split(",")
        assert max(int(n) for n in re.findall(r"\$(\d+)", text)) == len(header), pipe


def test_task_graph_matches_the_simulation():
    tasks = {}
    for _, s in statements(MIGRATIONS):
        m = re.match(r"CREATE OR REPLACE TASK CORE\.(\w+)(.*?)\bAS\b", s, re.S)
        if m:
            after = re.search(r"AFTER ([\w., ]+?)\n", m.group(2))
            tasks[m.group(1)] = (
                sorted(a.strip().removeprefix("CORE.") for a in after.group(1).split(",")) if after else []
            )
    assert tasks == {
        "T_ROOT": [],
        "T_DIM_PRODUCT": ["T_ROOT"],
        "T_DIM_CUSTOMER": ["T_ROOT"],
        "T_FACT_ORDER_LINE": ["T_DIM_CUSTOMER", "T_DIM_PRODUCT"],
        "T_DATA_QUALITY": ["T_FACT_ORDER_LINE"],
    }
    text = (MIGRATIONS / "R__tasks.sql").read_text()
    for task, file, _ in TASKS:
        body = text.split(f"CREATE OR REPLACE TASK CORE.{task}")[1].split("CREATE OR REPLACE TASK")[0]
        assert f'{{% include "modules/{file}" %}}' in body, task
        assert "BEGIN TRANSACTION;" in body and "COMMIT;" in body, task


def test_dq_config_matches_the_check_files():
    configured = [(c["name"], c["severity"]) for c in yaml.safe_load(CONFIG.read_text())["vars"]["dq_checks"]]
    assert configured == [(c.name, c.severity) for c in load_checks()]
    assert sorted(n for n, _ in configured) == sorted(f.stem for f in DQ.glob("*.sql"))


def test_every_warehouse_has_a_monitor_and_auto_suspend():
    stmts = [s for _, s in statements(ADMIN)]
    whs = [
        re.match(r"CREATE WAREHOUSE IF NOT EXISTS (\w+)", s).group(1) for s in stmts if s.startswith("CREATE WAREHOUSE")
    ]
    assert whs
    for wh in whs:
        create = next(s for s in stmts if s.startswith(f"CREATE WAREHOUSE IF NOT EXISTS {wh}"))
        assert "AUTO_SUSPEND" in create and "STATEMENT_TIMEOUT_IN_SECONDS" in create, wh
        assert any(re.match(rf"ALTER WAREHOUSE {wh} SET RESOURCE_MONITOR = RM_\w+", s) for s in stmts), wh


def test_every_schema_is_granted_through_an_access_role():
    stmts = [s for _, s in statements(MIGRATIONS)]
    schemas = [
        re.match(r"CREATE SCHEMA IF NOT EXISTS (\w+)", s).group(1) for s in stmts if s.startswith("CREATE SCHEMA")
    ]
    for schema in schemas:
        if schema == "GOVERNANCE":
            continue  # policies are applied by the owner, not read by anyone
        assert any(re.match(rf"GRANT USAGE ON SCHEMA {schema} TO DATABASE ROLE AR_", s) for s in stmts), schema
        assert any(re.match(rf"GRANT SELECT ON FUTURE \w+ IN SCHEMA {schema} TO DATABASE ROLE AR_", s) for s in stmts)
    # functional roles get access roles, never objects
    assert not [s for s in stmts if re.match(r"GRANT \w+ ON (TABLE|VIEW|SCHEMA)\b.* TO ROLE ", s)]


def test_mart_views_run_on_the_pipeline_output(pipeline):
    con = pipeline[0].con
    text = render(MIGRATIONS / "R__mart.sql")
    for stmt in split(text):
        if stmt.startswith("CREATE OR REPLACE DYNAMIC TABLE"):
            query = stmt.split("\nAS\n", 1)[1]
            for sql in to_duckdb("CREATE OR REPLACE VIEW CORE.DAILY_SALES AS " + query):
                con.execute(sql)
        elif stmt.startswith("CREATE OR REPLACE SECURE VIEW"):
            for sql in to_duckdb(without_policy(stmt)):
                con.execute(sql)
    for view in ("MART.DAILY_SALES", "MART.ORDER_LINE", "MART.CUSTOMER"):
        assert con.execute(f"SELECT COUNT(*) FROM {view}").fetchone()[0] > 0, view
    lines = con.execute("SELECT COUNT(*) FROM CORE.FACT_ORDER_LINE").fetchone()[0]
    assert con.execute("SELECT COUNT(*) FROM MART.ORDER_LINE").fetchone()[0] == lines


def test_transforms_are_the_same_files_the_tasks_include():
    assert sorted(f for _, f, _ in TASKS) == sorted(
        p.name for p in TRANSFORM.glob("*.sql") if p.name != "daily_sales.sql"
    )


def test_change_history_is_outside_the_managed_schemas():
    # schemachange creates the history table's schema before any script runs;
    # in a managed-access schema that would pre-empt V1.1.0's CREATE SCHEMA.
    wf = (ROOT / ".github" / "workflows" / "deploy-env.yml").read_text()
    (table,) = re.findall(r'--change-history-table "([^"]+)"', wf)
    schema = table.split(".")[1]
    assert schema not in SCHEMAS


def test_governance_covers_every_mart_view_and_schema():
    stmts = [s for _, s in statements(MIGRATIONS)]
    views = [s for s in stmts if s.startswith("CREATE OR REPLACE SECURE VIEW MART.")]
    assert len(views) == 3
    for v in views:
        head = v.split("\nAS\n", 1)[0]
        assert "WITH ROW ACCESS POLICY GOVERNANCE.RAP_REGION ON (region)" in head, head
    # nothing in MART is a plain view or a table, which would bypass the policy
    assert not [s for s in stmts if re.match(r"CREATE (OR REPLACE )?(VIEW|TABLE) (IF NOT EXISTS )?MART\.", s)]
    for s in stmts:
        if s.startswith("CREATE SCHEMA"):
            assert "WITH MANAGED ACCESS" in s, s
    tagged = {
        (m.group(1), m.group(2).lower())
        for s in stmts
        if (m := re.match(r"ALTER TABLE (\w+\.\w+) MODIFY COLUMN (\w+) SET TAG GOVERNANCE\.PII", s))
    }
    assert tagged == {(t, c) for t in ("CORE.DIM_CUSTOMER", "RAW.CUSTOMER") for c in ("email", "full_name")}


def test_row_policy_argument_is_not_a_mapping_column():
    """An argument named like a column of the mapping table is shadowed by
    that column inside the policy's subquery, and the filter always passes."""
    stmts = [s for _, s in statements(MIGRATIONS)]
    (policy,) = [s for s in stmts if s.startswith("CREATE ROW ACCESS POLICY")]
    (arg,) = re.findall(r"AS \((\w+) VARCHAR\)", policy)
    (mapping,) = [s for s in stmts if s.startswith("CREATE TABLE IF NOT EXISTS GOVERNANCE.REGION_ACCESS")]
    columns = re.findall(r"^\s*,?\s*(\w+) VARCHAR", mapping, re.M)
    assert columns and arg not in columns
