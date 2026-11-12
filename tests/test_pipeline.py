"""The DuckDB run of the transforms against the plain-Python expectation."""

from datetime import datetime
from decimal import Decimal

import expected
import pytest

from sim.engine import load_checks


@pytest.fixture(scope="module")
def con(pipeline):
    return pipeline[0].con


@pytest.fixture(scope="module")
def want_customers(landing):
    return expected.customers(landing)


@pytest.fixture(scope="module")
def want_orders(landing):
    return expected.orders(landing)


def test_no_error_check_fails_on_any_day(pipeline):
    errors = {c.name for c in load_checks() if c.severity == "error"}
    for r in pipeline[1]:
        assert {k: v for k, v in r.dq.items() if k in errors and v} == {}, r.day


def test_customer_versions(con, want_customers):
    want, _ = want_customers
    rows = con.execute(
        "SELECT customer_id, valid_from, valid_to, email, full_name, region, loyalty_tier, "
        "CAST(signup_date AS VARCHAR) FROM CORE.DIM_CUSTOMER WHERE customer_key <> -1 "
        "ORDER BY customer_id, valid_from"
    ).fetchall()
    got: dict[str, list] = {}
    for cid, vf, vt, *attrs in rows:
        got.setdefault(cid, []).append((vf, vt, tuple(attrs)))
    assert set(got) == set(want)
    for cid, c in want.items():
        assert got[cid] == [(v.valid_from, v.valid_to, v.attrs) for v in c.versions], cid


def test_stale_crm_rows_are_logged_not_applied(con, want_customers):
    _, late = want_customers
    assert late > 0
    assert con.execute("SELECT COUNT(*) FROM OPS.LATE_ARRIVAL").fetchone()[0] == late


def test_one_line_per_order_line_with_amounts(con, want_orders):
    lines, _ = want_orders
    got = {
        (o, ln): amt
        for o, ln, amt in con.execute("SELECT order_id, line_number, net_amount FROM CORE.FACT_ORDER_LINE").fetchall()
    }
    assert set(got) == set(lines)
    assert all(got[k] == lines[k].net_amount for k in lines)


def test_status_is_the_newest_event(con, want_orders):
    _, status = want_orders
    got = dict(con.execute("SELECT order_id, status FROM CORE.ORDER_STATUS").fetchall())
    assert got == status
    line_status = con.execute("SELECT order_id, status FROM CORE.FACT_ORDER_LINE GROUP BY order_id, status").fetchall()
    assert all(status[o] == s for o, s in line_status)


def test_lines_point_at_the_customer_version_valid_at_order_time(con, want_customers, want_orders):
    customers, _ = want_customers
    lines, _ = want_orders
    got = {
        (o, ln): (cid, vf)
        for o, ln, cid, vf in con.execute(
            "SELECT f.order_id, f.line_number, c.customer_id, c.valid_from FROM CORE.FACT_ORDER_LINE f "
            "JOIN CORE.DIM_CUSTOMER c ON c.customer_key = f.customer_key"
        ).fetchall()
    }
    on_later_version = 0
    for k, line in lines.items():
        v = expected.version_at(customers[line.customer_id], line.order_ts)
        assert got[k] == (line.customer_id, v.valid_from), k
        on_later_version += v.valid_from > datetime(1900, 1, 1)
    assert on_later_version > 0, "no line sits on a later customer version; the test data lost its point"


def test_planted_cases_occurred(landing):
    import json

    counts = json.loads((landing / "_counts.json").read_text())
    for k in (
        "duplicate_events",
        "status_before_created_orders",
        "late_customers",
        "out_of_order_customer_rows",
        "unknown_product_lines",
        "cancelled_orders",
    ):
        assert counts.get(k, 0) > 0, k


def test_daily_sales_adds_up(pipeline, want_orders):
    lines, status = want_orders
    total = sum(r[5] for r in pipeline[0].daily_sales())
    lines_ok = [line for line in lines.values() if status[line.order_id] != "CANCELLED"]
    # the dynamic table joins to the product dimension, so lines on the unknown
    # product are in it too, under category UNKNOWN
    assert total == sum((line.net_amount for line in lines_ok), Decimal("0"))


def test_reprocessing_a_day_changes_nothing(landing):
    """Loading the same files twice (Snowpipe's 14-day file memory expired, or a
    manual COPY with FORCE) must not change CORE."""
    from sim.engine import Platform, landing_days

    p = Platform()
    days = landing_days(landing)[:5]
    for d in days:
        p.load_day(landing, d)
        p.run_dag()
    snapshot = _core(p), _late(p)
    p.load_day(landing, days[-1])
    p.run_dag()
    # CORE is unchanged, and the reloaded CRM rows are not logged as stale
    assert (_core(p), _late(p)) == snapshot


def test_a_stopped_graph_keeps_every_customer_version(landing):
    """Four days of files in one run (the graph was stopped) give the same
    versions as the model applying those four days as one batch: no change
    in the middle of the batch is lost."""
    from sim.engine import Platform, landing_days

    days = landing_days(landing)
    batches = [days[:1]] + [days[i : i + 4] for i in range(1, len(days), 4)]
    p = Platform()
    for batch in batches:
        for d in batch:
            p.load_day(landing, d)
        p.run_dag()
    want, late = expected.customers(landing, batches)
    rows = p.con.execute(
        "SELECT customer_id, valid_from, valid_to, email, full_name, region, loyalty_tier, "
        "CAST(signup_date AS VARCHAR) FROM CORE.DIM_CUSTOMER WHERE customer_key <> -1 "
        "ORDER BY customer_id, valid_from"
    ).fetchall()
    got: dict[str, list] = {}
    for cid, vf, vt, *attrs in rows:
        got.setdefault(cid, []).append((vf, vt, tuple(attrs)))
    assert got == {cid: [(v.valid_from, v.valid_to, v.attrs) for v in c.versions] for cid, c in want.items()}
    assert _late(p) == late
    # some customer changed more than once within a batch, so the case occurred
    assert any(
        sum(1 for v in c.versions if b[0] <= v.valid_from.date() <= b[-1]) > 1 for c in want.values() for b in batches
    )
    errors = {c.name for c in load_checks() if c.severity == "error"}
    assert {k: v for k, v in p.run_checks().items() if k in errors and v} == {}


def _late(p):
    return p.con.execute("SELECT COUNT(*) FROM OPS.LATE_ARRIVAL").fetchone()[0]


def _core(p):
    q = p.con.execute
    return (
        q("SELECT customer_id, valid_from, valid_to, hash_diff FROM CORE.DIM_CUSTOMER ORDER BY ALL").fetchall(),
        q(
            "SELECT order_id, line_number, customer_key, product_key, status, net_amount "
            "FROM CORE.FACT_ORDER_LINE ORDER BY ALL"
        ).fetchall(),
        q("SELECT * FROM CORE.ORDER_STATUS ORDER BY ALL").fetchall(),
    )


@pytest.mark.parametrize("first, second", [("PAID", "SHIPPED"), ("SHIPPED", "PAID")])
def test_status_tie_across_batches_goes_to_the_later_step(first, second):
    """Two events for one order with the same event_ts, in separate runs:
    the later step wins whichever arrives first, as it does within a batch."""
    import pandas as pd

    from sim.engine import Platform

    p = Platform()
    ts = "2026-01-05 10:00:00"
    for n, event_type in enumerate([first, second], start=1):
        row = dict.fromkeys(
            ["customer_id", "channel", "line_number", "product_code", "quantity", "unit_price", "discount_pct"]
        )
        row |= {
            "event_id": f"E{n}",
            "event_type": event_type,
            "event_ts": ts,
            "order_id": "O1",
            "payload": "{}",
            "file_name": f"orders/f{n}.json",
            "file_row_number": 1,
            "loaded_at": datetime(2026, 1, 5, 11, n),
        }
        p._insert("ORDER_EVENT", pd.DataFrame([row]))
        p.run_dag()
    assert p.con.execute("SELECT status FROM CORE.ORDER_STATUS WHERE order_id = 'O1'").fetchone()[0] == "SHIPPED"


def test_an_incomplete_order_event_is_rejected_not_fatal():
    """An ORDER_CREATED event without a quantity would break the fact's NOT
    NULL column and fail every run. It goes to OPS.REJECTED_EVENT instead."""
    import pandas as pd

    from sim.engine import Platform

    p = Platform()
    row = {
        "event_id": "E1",
        "event_type": "ORDER_CREATED",
        "event_ts": "2026-01-05 10:00:00",
        "order_id": "O1",
        "customer_id": "C000001",
        "channel": "web",
        "line_number": 1,
        "product_code": "P0001",
        "quantity": None,
        "unit_price": 10.0,
        "discount_pct": 0.0,
        "payload": "{}",
        "file_name": "orders/f1.json",
        "file_row_number": 1,
        "loaded_at": datetime(2026, 1, 5, 11, 0),
    }
    p._insert("ORDER_EVENT", pd.DataFrame([row]))
    p.run_dag()
    q = p.con.execute
    assert q("SELECT COUNT(*) FROM CORE.FACT_ORDER_LINE").fetchone()[0] == 0
    assert q("SELECT event_id, reason FROM OPS.REJECTED_EVENT").fetchall() == [("E1", "missing: quantity")]
    assert p.run_checks()["ops_rejected_event"] == 1
