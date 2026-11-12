"""What the pipeline should produce, worked out in plain Python from the
landing files, without SQL. The tests compare the DuckDB run with this.

The rules are the ones the transforms document, implemented separately:
customer versions by CRM timestamp with stale rows skipped, order status as
the newest event, one line per (order, line number), and each line keyed to
the customer version valid when the order was placed.
"""

from __future__ import annotations

import csv
import json
from dataclasses import dataclass, field
from datetime import datetime
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

FAR_PAST = datetime(1900, 1, 1)
FAR_FUTURE = datetime(9999, 12, 31)
RANK = {"ORDER_CREATED": 1, "PAID": 2, "SHIPPED": 3, "CANCELLED": 4}
STATUS = {"ORDER_CREATED": "PLACED", "PAID": "PAID", "SHIPPED": "SHIPPED", "CANCELLED": "CANCELLED"}


@dataclass
class Version:
    attrs: tuple
    valid_from: datetime
    valid_to: datetime = FAR_FUTURE


@dataclass
class Customer:
    versions: list[Version] = field(default_factory=list)
    source_ts: datetime = FAR_PAST


def _days(landing: Path, kind: str) -> list[Path]:
    return sorted(p for p in (landing / kind).glob("*/*/*") if p.is_dir())


def _attrs(r: dict) -> tuple:
    email = (r["email"] or "").strip() or None
    return (
        email,
        r["full_name"] or None,
        (r["region"] or "").upper(),
        (r["loyalty_tier"] or "").upper(),
        r["signup_date"] or None,
    )


def customers(landing: Path) -> tuple[dict[str, Customer], int]:
    out: dict[str, Customer] = {}
    late = 0
    for day in _days(landing, "customers"):
        rows = []
        for f in sorted(day.glob("*.csv")):
            with f.open() as fh:
                for n, r in enumerate(csv.DictReader(fh), start=2):
                    rows.append((datetime.fromisoformat(r["updated_at"]), str(f), n, r))
        latest: dict[str, tuple] = {}
        for row in sorted(rows, key=lambda x: (x[0], x[1], x[2])):
            latest[row[3]["customer_id"]] = row
        for cid, (ts, _, _, r) in latest.items():
            c = out.get(cid)
            a = _attrs(r)
            if c is None:
                out[cid] = Customer([Version(a, FAR_PAST)], ts)
            elif ts <= c.source_ts:
                late += 1
            elif a != c.versions[-1].attrs:
                c.versions[-1].valid_to = ts
                c.versions.append(Version(a, ts))
                c.source_ts = ts
            else:
                c.source_ts = ts
    return out, late


@dataclass
class Line:
    order_id: str
    line_number: int
    customer_id: str
    product_code: str
    order_ts: datetime
    net_amount: Decimal


def orders(landing: Path) -> tuple[dict[tuple, Line], dict[str, str]]:
    lines: dict[tuple, Line] = {}
    best: dict[str, tuple] = {}
    for day in _days(landing, "orders"):
        for f in sorted(day.glob("*.json")):
            for raw in f.read_text().splitlines():
                e = json.loads(raw)
                ts = datetime.fromisoformat(e["event_ts"])
                key = (ts, RANK[e["event_type"]], e["event_id"])
                if e["order_id"] not in best or key > best[e["order_id"]]:
                    best[e["order_id"]] = key
                if e["event_type"] == "ORDER_CREATED":
                    k = (e["order_id"], e["line_number"])
                    if k not in lines:
                        net = (
                            Decimal(str(e["quantity"]))
                            * Decimal(str(e["unit_price"]))
                            * (1 - Decimal(str(e["discount_pct"])))
                        )
                        lines[k] = Line(
                            e["order_id"],
                            e["line_number"],
                            e["customer_id"],
                            e["product_code"],
                            ts,
                            net.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP),
                        )
    status = {oid: STATUS[next(t for t, r in RANK.items() if r == k[1])] for oid, k in best.items()}
    return lines, status


def version_at(c: Customer, ts: datetime) -> Version | None:
    return next((v for v in c.versions if v.valid_from <= ts < v.valid_to), None)
