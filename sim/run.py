"""Generate landing files and run the pipeline over them on DuckDB, one task
graph run per day of files, then print what it produced.

    python -m sim.run --days 90 --scale 1.0
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

from generator.ridgeline import Config, generate

from .engine import load_checks, run


def summary(landing: Path) -> dict:
    p, results = run(landing)
    q = p.con.execute

    def count(sql: str) -> int:
        return q(f"SELECT COUNT(*) FROM {sql}").fetchone()[0]

    last = results[-1].dq
    severities = {c.name: c.severity for c in load_checks()}
    return {
        "days_run": len(results),
        "raw_rows": {
            t: q(f"SELECT COUNT(*) FROM RAW.{t}").fetchone()[0] for t in ("ORDER_EVENT", "CUSTOMER", "PRODUCT")
        },
        "dim_customer_rows": count("CORE.DIM_CUSTOMER WHERE customer_key <> -1"),
        "dim_customer_current": q(
            "SELECT COUNT(*) FROM CORE.DIM_CUSTOMER WHERE is_current AND customer_key <> -1"
        ).fetchone()[0],
        "dim_product_rows": count("CORE.DIM_PRODUCT WHERE product_key <> -1"),
        "fact_order_lines": count("CORE.FACT_ORDER_LINE"),
        "orders": count("CORE.ORDER_STATUS"),
        "late_customer_rows_skipped": count("OPS.LATE_ARRIVAL"),
        "lines_on_unknown_customer": q("SELECT COUNT(*) FROM CORE.FACT_ORDER_LINE WHERE customer_key = -1").fetchone()[
            0
        ],
        "lines_on_unknown_product": count("CORE.FACT_ORDER_LINE WHERE product_key = -1"),
        "net_sales_excl_cancelled": float(
            q("SELECT SUM(net_amount) FROM CORE.FACT_ORDER_LINE WHERE status <> 'CANCELLED'").fetchone()[0]
        ),
        "dq_last_run": {k: {"severity": severities[k], "failing_rows": v} for k, v in last.items()},
        "dq_error_failures_any_run": sum(v for r in results for k, v in r.dq.items() if severities[k] == "error"),
    }


def main() -> int:
    a = argparse.ArgumentParser()
    a.add_argument("--days", type=int, default=90)
    a.add_argument("--scale", type=float, default=1.0)
    a.add_argument("--seed", type=int, default=7)
    a.add_argument("--landing", type=Path, help="use existing files instead of generating")
    args = a.parse_args()
    if args.landing:
        out = summary(args.landing)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            generate(Path(tmp), Config(args.days, args.scale, args.seed))
            out = summary(Path(tmp))
    print(json.dumps(out, indent=2))
    return 1 if out["dq_error_failures_any_run"] else 0


if __name__ == "__main__":
    sys.exit(main())
