"""Run the pipeline's SQL on DuckDB, day by day, against generated files.

This is how the repo tests Snowflake SQL without a Snowflake account. What is
real and what is stood in for:

  * The table DDL is the migrations' own CREATE TABLE / CREATE SEQUENCE /
    INSERT statements, rendered with Jinja as schemachange would and
    translated from Snowflake SQL to DuckDB by sqlglot.
  * The transforms are the files in transform/, the same files the task
    definitions include, translated the same way.
  * Snowpipe is stood in for by Python that reads each landing file and
    inserts what the pipe's COPY would (typed columns, file name, row number).
  * A stream is stood in for by a table holding the rows added to its source
    table since the stream was last consumed. Each task runs in a
    transaction; the offset moves only if the transaction commits, which is
    how an append-only stream behaves.
  * Three translations sqlglot leaves to the caller are patched here:
    sequence NEXTVAL, and the TIMESTAMP_LTZ and VARIANT type names (DuckDB
    uses TIMESTAMPTZ and JSON). Anything else that does not translate fails
    the run.

What this cannot check: Snowflake-only objects (pipes, stages, tasks,
policies, grants). Those are parsed by tests/test_migrations.py and are
otherwise only exercised by a deployment.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

import duckdb
import jinja2
import sqlglot
import yaml

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "migrations" / "database"
TRANSFORM = ROOT / "transform"
DQ = TRANSFORM / "dq"
CONFIG = ROOT / "deploy" / "schemachange-database.yml"
SCHEMAS = ["RAW", "CORE", "MART", "OPS", "GOVERNANCE"]


def test_vars() -> dict:
    """The config's vars plus the dev environment's, as the workflow passes them."""
    import json

    v = yaml.safe_load(CONFIG.read_text())["vars"]
    return v | json.loads((ROOT / "deploy" / "envs" / "dev.json").read_text())


# task -> (transform file, streams it reads). The order is the task DAG's:
# the two dimension tasks after the root, the fact task after both.
TASKS = [
    ("T_DIM_PRODUCT", "product_upsert.sql", ["PRODUCT"]),
    ("T_DIM_CUSTOMER", "customer_scd2.sql", ["CUSTOMER"]),
    ("T_FACT_ORDER_LINE", "order_line.sql", ["ORDER_EVENT"]),
]


def render(path: Path, variables: dict | None = None) -> str:
    """Render as schemachange does: the root folder, and the modules folder
    (transform/) under the prefix modules/."""
    loader = jinja2.ChoiceLoader(
        [
            jinja2.FileSystemLoader(MIGRATIONS),
            jinja2.PrefixLoader({"modules": jinja2.FileSystemLoader(TRANSFORM)}),
        ]
    )
    env = jinja2.Environment(undefined=jinja2.StrictUndefined, loader=loader)
    return env.from_string(path.read_text()).render(**(variables or test_vars()))


def to_duckdb(sql: str) -> list[str]:
    out = []
    for stmt in sqlglot.transpile(sql, read="snowflake", write="duckdb"):
        stmt = re.sub(r"/\*.*?\*/", "", stmt, flags=re.S).strip()
        if not stmt:
            continue
        stmt = re.sub(r"\b(\w+)\.(\w+)\.NEXTVAL\b", r"nextval('\1.\2')", stmt, flags=re.I)
        stmt = re.sub(r"\bTIMESTAMPLTZ\b", "TIMESTAMPTZ", stmt)
        stmt = re.sub(r"\bVARIANT\b", "JSON", stmt)
        out.append(stmt)
    return out


def ddl_statements() -> list[str]:
    """The migrations' tables, sequences and seed rows, in file order."""
    keep = re.compile(r"^\s*(CREATE\s+(TABLE|SEQUENCE)|INSERT\s+INTO)\b", re.I)
    out = []
    for f in sorted(MIGRATIONS.glob("V*.sql"), key=lambda p: [int(x) for x in p.name[1:].split("__")[0].split(".")]):
        text = render(f)
        text = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("--"))
        for stmt in text.split(";"):
            if keep.match(stmt):
                out += to_duckdb(stmt)
    return out


@dataclass
class RunResult:
    day: date
    loaded: dict[str, int]
    dq: dict[str, int]


@dataclass
class Platform:
    con: duckdb.DuckDBPyConnection = field(default_factory=duckdb.connect)
    offsets: dict[str, int] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for s in SCHEMAS:
            self.con.execute(f"CREATE SCHEMA {s}")
        for stmt in ddl_statements():
            self.con.execute(stmt)
        for name in ("ORDER_EVENT", "CUSTOMER", "PRODUCT"):
            self.offsets[name] = 0
        self.transforms = {f: to_duckdb(render(TRANSFORM / f)) for _, f, _ in TASKS}
        self.checks = load_checks()

    # ---- Snowpipe stand-in ---------------------------------------------------

    def load_day(self, landing: Path, d: date) -> dict[str, int]:
        """What the three pipes' COPY statements insert for one day's files."""
        import pandas as pd

        loaded_at = datetime(d.year, d.month, d.day, 23, 59, 0)
        counts = {}
        rows = []
        for f in sorted((landing / "orders" / f"{d:%Y/%m/%d}").glob("*.json")):
            for n, line in enumerate(f.read_text().splitlines(), start=1):
                e = json.loads(line)
                rows.append(
                    {
                        "event_id": e["event_id"],
                        "event_type": e["event_type"],
                        "event_ts": e["event_ts"],
                        "order_id": e["order_id"],
                        "customer_id": e.get("customer_id"),
                        "channel": e.get("channel"),
                        "line_number": e.get("line_number"),
                        "product_code": e.get("product_code"),
                        "quantity": e.get("quantity"),
                        "unit_price": e.get("unit_price"),
                        "discount_pct": e.get("discount_pct"),
                        "payload": line,
                        "file_name": _rel(landing, f),
                        "file_row_number": n,
                        "loaded_at": loaded_at,
                    }
                )
        counts["ORDER_EVENT"] = self._insert("ORDER_EVENT", pd.DataFrame(rows))
        for kind, table in (("customers", "CUSTOMER"), ("products", "PRODUCT")):
            frames = []
            for f in sorted((landing / kind / f"{d:%Y/%m/%d}").glob("*.csv")):
                df = pd.read_csv(f, dtype=str, keep_default_na=False).replace("", None)
                df["file_name"] = _rel(landing, f)
                df["file_row_number"] = range(2, len(df) + 2)  # line 1 is the header
                df["loaded_at"] = loaded_at
                frames.append(df)
            counts[table] = self._insert(table, pd.concat(frames) if frames else pd.DataFrame())
        return counts

    def _insert(self, table: str, df) -> int:
        if df.empty:
            return 0
        cols = [r[0] for r in self.con.execute(f"DESCRIBE RAW.{table}").fetchall()]
        self.con.register("_batch", df)
        self.con.execute(f"INSERT INTO RAW.{table} SELECT {', '.join(cols)} FROM _batch")
        self.con.unregister("_batch")
        return len(df)

    # ---- stream and task stand-ins --------------------------------------------

    def _open_stream(self, name: str) -> int:
        top = self.con.execute(f"SELECT COALESCE(MAX(rowid) + 1, 0) FROM RAW.{name}").fetchone()[0]
        self.con.execute(f"DROP TABLE IF EXISTS RAW.{name}_STREAM")
        self.con.execute(
            f"CREATE TABLE RAW.{name}_STREAM AS SELECT * FROM RAW.{name} "
            f"WHERE rowid >= {self.offsets[name]} AND rowid < {top}"
        )
        return top

    def run_task(self, file: str, streams: list[str]) -> None:
        tops = {s: self._open_stream(s) for s in streams}
        self.con.execute("BEGIN TRANSACTION")
        try:
            for stmt in self.transforms[file]:
                self.con.execute(stmt)
        except Exception:
            self.con.execute("ROLLBACK")
            raise
        self.con.execute("COMMIT")
        self.offsets.update(tops)

    def run_dag(self) -> None:
        for _, file, streams in TASKS:
            self.run_task(file, streams)

    def run_checks(self) -> dict[str, int]:
        return {c.name: self.con.execute(f"SELECT COUNT(*) FROM ({c.sql})").fetchone()[0] for c in self.checks}

    def daily_sales(self) -> list[tuple]:
        (stmt,) = to_duckdb(render(TRANSFORM / "daily_sales.sql"))
        return self.con.execute(stmt).fetchall()


@dataclass
class Check:
    name: str
    severity: str
    sql: str


def load_checks() -> list[Check]:
    out = []
    for f in sorted(DQ.glob("*.sql")):
        text = render(f)
        m = re.search(r"--\s*severity:\s*(error|warn)", text)
        (stmt,) = to_duckdb(text)
        out.append(Check(f.stem, m.group(1) if m else "error", stmt))
    return out


def _rel(landing: Path, f: Path) -> str:
    return f.relative_to(landing).as_posix()


def landing_days(landing: Path) -> list[date]:
    days = {date(int(p.parts[-3]), int(p.parts[-2]), int(p.parts[-1])) for p in landing.glob("*/*/*/*") if p.is_dir()}
    return sorted(days)


def run(landing: Path) -> tuple[Platform, list[RunResult]]:
    p = Platform()
    results = []
    for d in landing_days(landing):
        loaded = p.load_day(landing, d)
        p.run_dag()
        results.append(RunResult(d, loaded, p.run_checks()))
    return p, results
