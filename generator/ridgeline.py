"""Synthetic landing files for Ridgeline Outdoor Supply, a fictional online and
store retailer. Writes what the source systems drop into the landing
container, day by day, in the layout the Snowpipe pipes read:

    landing/orders/YYYY/MM/DD/events_HH.json    web shop order events, JSON lines
    landing/customers/YYYY/MM/DD/customers.csv   CRM changes since the last export
    landing/products/YYYY/MM/DD/products.csv     full catalogue snapshot

Order events are written one record per order line for ORDER_CREATED (the
header repeated on each line), and one record per order for PAID, SHIPPED and
CANCELLED. Planted on purpose, because each is a case the pipeline handles:

  * duplicate events: the same event_id written again in a later file
  * status events that arrive before the order's ORDER_CREATED lines
  * orders whose customer reaches the CRM export one or two days later
  * a customer change that arrives after a newer change for that customer
  * order lines with a product code the catalogue does not have
  * customers without an email address

    python -m generator.ridgeline --out landing --days 90 --scale 1.0
"""

from __future__ import annotations

import argparse
import csv
import json
import random
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path

START = date(2026, 1, 5)
REGIONS = ["NORTHEAST", "SOUTHEAST", "MIDWEST", "WEST"]
TIERS = ["NONE", "SILVER", "GOLD"]
CATEGORIES = ["Tents", "Packs", "Footwear", "Apparel", "Climbing", "Cooking"]

DUPLICATE_SHARE = 0.005
STATUS_FIRST_SHARE = 0.01
# of customers who sign up and order on the same day inside the window
LATE_CUSTOMER_SHARE = 0.2
# of CRM change rows: an older version re-sent the next day
OUT_OF_ORDER_CUSTOMER_SHARE = 0.03
UNKNOWN_PRODUCT_SHARE = 0.002
NO_EMAIL_SHARE = 0.02


@dataclass
class Config:
    days: int = 90
    scale: float = 1.0
    seed: int = 7

    @property
    def customers(self) -> int:
        return max(50, int(3000 * self.scale))

    @property
    def products(self) -> int:
        return max(20, int(400 * self.scale))

    @property
    def orders_per_day(self) -> int:
        return max(5, int(450 * self.scale))


@dataclass
class Stats:
    counts: dict[str, int] = field(default_factory=dict)

    def add(self, key: str, n: int = 1) -> None:
        self.counts[key] = self.counts.get(key, 0) + n


def _ts(d: date, rng: random.Random, start_hour: int = 6, end_hour: int = 23) -> datetime:
    return datetime(d.year, d.month, d.day, rng.randint(start_hour, end_hour), rng.randint(0, 59), rng.randint(0, 59))


def _day_dir(root: Path, kind: str, d: date) -> Path:
    p = root / kind / f"{d:%Y/%m/%d}"
    p.mkdir(parents=True, exist_ok=True)
    return p


def generate(out: Path, cfg: Config) -> dict[str, int]:
    rng = random.Random(cfg.seed)
    stats = Stats()
    days = [START + timedelta(days=i) for i in range(cfg.days)]

    # ---- products: a snapshot every day; prices change now and then --------
    products = {
        f"P{i:05d}": {
            "product_code": f"P{i:05d}",
            "product_name": f"{rng.choice(CATEGORIES)} item {i}",
            "category": rng.choice(CATEGORIES),
            "list_price": round(rng.uniform(15, 600), 2),
            "is_active": "true",
        }
        for i in range(1, cfg.products + 1)
    }

    # ---- customers: first appearance day, later changes ---------------------
    customers: dict[str, dict] = {}
    first_seen: dict[str, date] = {}
    for i in range(1, cfg.customers + 1):
        cid = f"C{i:06d}"
        signup = days[0] - timedelta(days=rng.randint(0, 400)) if rng.random() < 0.7 else rng.choice(days)
        customers[cid] = {
            "customer_id": cid,
            "email": "" if rng.random() < NO_EMAIL_SHARE else f"customer{i}@example.com",
            "full_name": f"Customer {i}",
            "region": rng.choice(REGIONS),
            "loyalty_tier": rng.choice(TIERS),
            "signup_date": max(signup, date(2024, 1, 1)).isoformat(),
        }
        first_seen[cid] = max(signup, days[0])

    # CRM changes per export day: (day, row). Initial rows on first_seen.
    crm_rows: dict[date, list[dict]] = {d: [] for d in days}
    late_customers: set[str] = set()
    for cid, c in customers.items():
        d = first_seen[cid]
        updated = datetime(d.year, d.month, d.day, 5, 0, 0) - timedelta(minutes=rng.randint(1, 600))
        crm_rows[d].append({**c, "updated_at": updated.isoformat(sep=" ")})

    order_days_by_customer: dict[str, list[date]] = {}
    events_by_file: dict[tuple[date, int], list[dict]] = {}
    event_no = 0

    def emit(d: date, hour: int, ev: dict) -> None:
        events_by_file.setdefault((d, hour), []).append(ev)

    snapshots: dict[date, list[dict]] = {}
    order_no = 0
    for d in days:
        eligible = [c for c in customers if first_seen[c] <= d]
        # customer changes made today (exported tomorrow)
        for cid in rng.sample(eligible, k=max(1, len(eligible) // 150)):
            c = customers[cid]
            field_name = rng.choice(["region", "loyalty_tier", "email"])
            if field_name == "region":
                c["region"] = rng.choice([r for r in REGIONS if r != c["region"]])
            elif field_name == "loyalty_tier":
                c["loyalty_tier"] = rng.choice([t for t in TIERS if t != c["loyalty_tier"]])
            else:
                c["email"] = f"{cid.lower()}.{d:%m%d}@example.com"
            changed_at = _ts(d, rng)
            export_day = d + timedelta(days=1)
            if export_day in crm_rows:
                crm_rows[export_day].append({**c, "updated_at": changed_at.isoformat(sep=" ")})
                stats.add("customer_changes")

        # price changes
        for code in rng.sample(list(products), k=max(1, len(products) // 100)):
            products[code]["list_price"] = round(products[code]["list_price"] * rng.uniform(0.9, 1.15), 2)
            stats.add("price_changes")
        snapshots[d] = [dict(p) for p in products.values()]

        # orders
        for _ in range(cfg.orders_per_day):
            order_no += 1
            oid = f"O{order_no:08d}"
            cid = rng.choice(eligible)
            created = _ts(d, rng)
            n_lines = rng.choice([1, 1, 1, 2, 2, 3, 4])
            lines = []
            for ln in range(1, n_lines + 1):
                code = rng.choice(list(products))
                if rng.random() < UNKNOWN_PRODUCT_SHARE:
                    code = f"X{rng.randint(1, 999):05d}"
                    stats.add("unknown_product_lines")
                price = products.get(code, {"list_price": round(rng.uniform(15, 600), 2)})["list_price"]
                lines.append((ln, code, rng.randint(1, 4), price, rng.choice([0, 0, 0, 0.1, 0.15])))
            order_days_by_customer.setdefault(cid, []).append(d)

            created_hour = created.hour
            status_first = rng.random() < STATUS_FIRST_SHARE
            if status_first:
                # the CREATED lines arrive in a later file than the PAID event
                created_hour = min(23, created.hour + 2)
                stats.add("status_before_created_orders")
            for ln, code, qty, price, disc in lines:
                event_no += 1
                emit(
                    d,
                    created_hour,
                    {
                        "event_id": f"E{event_no:09d}",
                        "event_type": "ORDER_CREATED",
                        "event_ts": created.isoformat(sep=" "),
                        "order_id": oid,
                        "customer_id": cid,
                        "channel": rng.choice(["WEB", "WEB", "APP"]),
                        "line_number": ln,
                        "product_code": code,
                        "quantity": qty,
                        "unit_price": price,
                        "discount_pct": disc,
                    },
                )
            stats.add("orders")
            stats.add("order_lines", len(lines))

            paid = created + timedelta(minutes=rng.randint(1, 30))
            event_no += 1
            paid_ev = {
                "event_id": f"E{event_no:09d}",
                "event_type": "PAID",
                "event_ts": paid.isoformat(sep=" "),
                "order_id": oid,
                "customer_id": cid,
            }
            emit(d, created.hour if status_first else min(23, paid.hour), paid_ev)

            r = rng.random()
            later_day = d + timedelta(days=rng.randint(1, 3))
            if r < 0.05:
                event_no += 1
                emit(
                    later_day if later_day in [*days] else d,
                    9,
                    {
                        "event_id": f"E{event_no:09d}",
                        "event_type": "CANCELLED",
                        "event_ts": datetime(later_day.year, later_day.month, later_day.day, 9, 0, 0).isoformat(
                            sep=" "
                        ),
                        "order_id": oid,
                        "customer_id": cid,
                    },
                )
                stats.add("cancelled_orders")
            elif r < 0.90:
                event_no += 1
                emit(
                    later_day if later_day in [*days] else d,
                    14,
                    {
                        "event_id": f"E{event_no:09d}",
                        "event_type": "SHIPPED",
                        "event_ts": datetime(later_day.year, later_day.month, later_day.day, 14, 0, 0).isoformat(
                            sep=" "
                        ),
                        "order_id": oid,
                        "customer_id": cid,
                    },
                )

    # late customers: a share of customers first seen on an order day reach the
    # CRM export one or two days after their first order
    for cid, order_days in order_days_by_customer.items():
        first_order = min(order_days)
        if first_seen[cid] == first_order and first_order > days[0] and rng.random() < LATE_CUSTOMER_SHARE:
            rows = [
                r for r in crm_rows[first_order] if r["customer_id"] == cid and r["updated_at"] < f"{first_order} 05"
            ]
            if not rows:
                continue
            delay = rng.randint(1, 2)
            target = first_order + timedelta(days=delay)
            if target not in crm_rows:
                continue
            crm_rows[first_order].remove(rows[0])
            crm_rows[target].append(rows[0])
            late_customers.add(cid)
    stats.add("late_customers", len(late_customers))

    # out-of-order customer change: an older change exported after a newer one
    for d in days[2:]:
        for row in list(crm_rows[d]):
            if row["customer_id"] in late_customers:
                continue
            if rng.random() < OUT_OF_ORDER_CUSTOMER_SHARE and d + timedelta(days=1) in crm_rows:
                stale = {
                    **row,
                    "region": rng.choice(REGIONS),
                    "updated_at": (datetime.fromisoformat(row["updated_at"]) - timedelta(days=1)).isoformat(sep=" "),
                }
                crm_rows[d + timedelta(days=1)].append(stale)
                stats.add("out_of_order_customer_rows")

    # duplicates: re-send a sample of events in a later hour's file
    keys = sorted(events_by_file)
    for d, h in keys:
        for ev in list(events_by_file[(d, h)]):
            if rng.random() < DUPLICATE_SHARE:
                emit(d, min(23, h + 1), dict(ev))
                stats.add("duplicate_events")

    # ---- write ---------------------------------------------------------------
    files = 0
    for (d, h), evs in sorted(events_by_file.items()):
        p = _day_dir(out, "orders", d) / f"events_{h:02d}.json"
        p.write_text("".join(json.dumps(e) + "\n" for e in evs))
        files += 1
        stats.add("order_events", len(evs))
    cols = ["customer_id", "email", "full_name", "region", "loyalty_tier", "signup_date", "updated_at"]
    for d, rows in crm_rows.items():
        if not rows:
            continue
        with (_day_dir(out, "customers", d) / "customers.csv").open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            w.writerows(rows)
        files += 1
        stats.add("customer_rows", len(rows))
    pcols = ["product_code", "product_name", "category", "list_price", "is_active"]
    for d in days:
        with (_day_dir(out, "products", d) / "products.csv").open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=pcols)
            w.writeheader()
            w.writerows(snapshots[d])
        files += 1
    stats.add("files", files)
    stats.counts["customers"] = cfg.customers
    stats.counts["products"] = cfg.products
    stats.counts["days"] = cfg.days
    (out / "_counts.json").write_text(json.dumps(dict(sorted(stats.counts.items())), indent=2) + "\n")
    return stats.counts


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, default=Path("landing"))
    p.add_argument("--days", type=int, default=90)
    p.add_argument("--scale", type=float, default=1.0)
    p.add_argument("--seed", type=int, default=7)
    a = p.parse_args()
    counts = generate(a.out, Config(a.days, a.scale, a.seed))
    for k, v in counts.items():
        print(f"{k:<32}{v:>10,}")


if __name__ == "__main__":
    main()
