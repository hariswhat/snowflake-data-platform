"""Monthly credits for one environment from cost/inputs.yml and the
warehouse sizes in deploy/envs/<env>.json.

Warehouse billing: per second while running, at least 60 seconds each time
it resumes, and it keeps running for AUTO_SUSPEND seconds after the last
query. A workload that wakes the warehouse N times a day for d seconds costs
N x max(60, d + auto_suspend) seconds. Runs that share a resume are cheaper;
the model assumes they do not, so it is an upper bound for scheduled work.

Prices are not stored: credits x the contract's price per credit gives
money (docs/cost-estimate.md).

    python -m cost.model --env prd
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def load(env: str) -> tuple[dict, dict, dict]:
    doc = yaml.safe_load((ROOT / "cost" / "inputs.yml").read_text())
    envvars = json.loads((ROOT / "deploy" / "envs" / f"{env}.json").read_text())
    return doc["facts"], doc["estimates"], envvars


def billed_seconds(resumes_per_day: float, run_s: float, auto_suspend_s: float, minimum_s: float) -> float:
    return resumes_per_day * max(minimum_s, run_s + auto_suspend_s)


def monthly_credits(env: str) -> dict[str, float]:
    f, e, v = load(env)
    rate = f["credits_per_hour"]
    days = e["days_per_month"]
    minimum = f["min_billed_seconds_per_resume"]
    tw = rate[v["transform_wh_size"]] / 3600
    graph = billed_seconds(f["hours_with_files_per_day"], e["task_graph_run_s"], f["transform_auto_suspend_s"], minimum)
    dt = billed_seconds(
        e["dynamic_table_refreshes_per_day"], e["dynamic_table_refresh_s"], f["transform_auto_suspend_s"], minimum
    )
    alerts_on_wh = billed_seconds(f["alert_checks_per_day"], e["alert_check_s"], f["transform_auto_suspend_s"], minimum)
    bi = e["bi_active_hours_per_day"][env] * 3600 + f["bi_auto_suspend_s"]
    return {
        "transform: task graph": round(graph * tw * days, 1),
        "transform: dynamic table refresh": round(dt * tw * days, 1),
        "bi": round(bi * rate[v["bi_wh_size"]] / 3600 * days, 1),
        "adhoc": round(e["adhoc_hours_per_month"][env] * rate["XSMALL"], 1),
        # what the alerts would cost on the transform warehouse; they are
        # serverless instead, billed separately
        "not incurred: alerts on the transform warehouse": round(alerts_on_wh * tw * days, 1),
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--env", default="prd", choices=["dev", "prd"])
    a = p.parse_args()
    _, _, v = load(a.env)
    credits = monthly_credits(a.env)
    for k, c in credits.items():
        print(f"{k:<50}{c:>8.1f}")
    transform = credits["transform: task graph"] + credits["transform: dynamic table refresh"]
    print(f"\n{'transform total':<50}{transform:>8.1f}   monitor quota {v['transform_monthly_credits']}")
    print(f"{'bi':<50}{credits['bi']:>8.1f}   monitor quota {v['bi_monthly_credits']}")
    print(f"{'adhoc':<50}{credits['adhoc']:>8.1f}   monitor quota {v['adhoc_monthly_credits']}")


if __name__ == "__main__":
    main()
