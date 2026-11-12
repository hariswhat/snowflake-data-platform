"""The numbers in README.md and docs/ come from commands in this repo.

The landing counts and the cost tables are regenerated here. The pipeline
summary takes too long for the unit suite; CI regenerates it and diffs it
against docs/measured/sim-90d.json.
"""

import json
import subprocess
import sys

import pytest

from cost.model import monthly_credits
from generator.ridgeline import Config, generate
from sim.engine import ROOT

README = (ROOT / "README.md").read_text()
MEASURED = ROOT / "docs" / "measured"
LANDING = json.loads((MEASURED / "landing-90d.json").read_text())
SIM = json.loads((MEASURED / "sim-90d.json").read_text())


def fmt(n) -> str:
    return f"{n:,.2f}" if isinstance(n, float) else f"{n:,}"


def test_landing_counts_are_current(tmp_path):
    assert generate(tmp_path, Config(days=90, scale=1.0, seed=7)) is not None
    assert json.loads((tmp_path / "_counts.json").read_text()) == LANDING


@pytest.mark.parametrize("env", ["dev", "prd"])
def test_cost_output_is_current(env):
    out = subprocess.run(
        [sys.executable, "-m", "cost.model", "--env", env], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout
    assert out == (MEASURED / f"cost-{env}.txt").read_text()


@pytest.mark.parametrize(
    "row, values",
    [
        ("| Landing files |", [LANDING["files"]]),
        ("| Orders |", [LANDING["orders"]]),
        ("| Order lines |", [LANDING["order_lines"]]),
        ("| Order events |", [LANDING["order_events"]]),
        ("| Customers / CRM rows |", [LANDING["customers"], LANDING["customer_rows"]]),
        ("| Customer attribute changes |", [LANDING["customer_changes"]]),
        ("| Products / price changes |", [LANDING["products"], LANDING["price_changes"]]),
        ("| Order events sent twice |", [LANDING["duplicate_events"]]),
        ("| Orders whose status event arrives before the order |", [LANDING["status_before_created_orders"]]),
        ("| CRM rows re-sent after a newer one (stale) |", [LANDING["out_of_order_customer_rows"]]),
        ("| Customers who reach the CRM export after their first order |", [LANDING["late_customers"]]),
        ("| Order lines for a product not in the catalogue |", [LANDING["unknown_product_lines"]]),
        ("| Cancelled orders |", [LANDING["cancelled_orders"]]),
        ("| Customer versions / current |", [SIM["dim_customer_rows"], SIM["dim_customer_current"]]),
        ("| Fact order lines |", [SIM["fact_order_lines"]]),
        ("| Stale CRM rows logged", [SIM["late_customer_rows_skipped"]]),
        ("| Lines on the unknown customer after 90 days |", [SIM["lines_on_unknown_customer"]]),
        ("| Lines on the unknown product |", [SIM["lines_on_unknown_product"]]),
        ("| Net sales excluding cancelled |", [SIM["net_sales_excl_cancelled"]]),
        ("| Error-severity check failures, any day |", [SIM["dq_error_failures_any_run"]]),
    ],
)
def test_readme_tables_match_the_measurements(row, values):
    lines = [ln for ln in README.splitlines() if ln.startswith(row)]
    assert lines, row
    for line in lines:  # "Orders" is in both tables, from the generator and the pipeline
        assert line.rstrip(" |").endswith(" / ".join(fmt(v) for v in values)), line


def test_readme_cost_table_matches_the_model():
    c = monthly_credits("prd")
    transform = c["transform: task graph"] + c["transform: dynamic table refresh"]
    assert f"task graph {c['transform: task graph']}, dynamic table {c['transform: dynamic table refresh']}" in README
    assert f"| {transform:.1f} |" in README
    assert f"| {c['bi']:.1f} |" in README
    assert f"| {c['adhoc']:.1f} |" in README
    assert f"cost up to {c['not incurred: alerts on the transform warehouse']} credits a month" in README


def test_pipeline_and_model_agree_with_the_planted_counts():
    assert SIM["late_customer_rows_skipped"] == LANDING["out_of_order_customer_rows"]
    assert SIM["fact_order_lines"] == LANDING["order_lines"]
    assert SIM["orders"] == LANDING["orders"]
    assert SIM["lines_on_unknown_product"] == LANDING["unknown_product_lines"]
