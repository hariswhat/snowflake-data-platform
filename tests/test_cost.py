import json
import re

import pytest

from cost.model import ROOT, billed_seconds, monthly_credits


def test_billing_rule():
    # a 10-second query still pays the 60-second minimum after a resume
    assert billed_seconds(1, 10, 0, 60) == 60
    # and the warehouse stays up for auto-suspend after the last query
    assert billed_seconds(2, 45, 60, 60) == 210


@pytest.mark.parametrize("env", ["dev", "prd"])
def test_resource_monitor_quotas_cover_the_estimate(env):
    c = monthly_credits(env)
    v = json.loads((ROOT / "deploy" / "envs" / f"{env}.json").read_text())
    assert v["transform_monthly_credits"] >= c["transform: task graph"] + c["transform: dynamic table refresh"]
    assert v["bi_monthly_credits"] >= c["bi"]
    assert v["adhoc_monthly_credits"] >= c["adhoc"]


def test_alerts_on_the_warehouse_would_cost_more_than_the_task_graph():
    """The reason the alerts are serverless (R__ops.sql)."""
    c = monthly_credits("prd")
    assert c["not incurred: alerts on the transform warehouse"] > c["transform: task graph"]
    ops = (ROOT / "migrations" / "database" / "R__ops.sql").read_text()
    for alert in re.findall(r"CREATE OR REPLACE ALERT .*?THEN", ops, re.S):
        assert "WAREHOUSE" not in alert


def test_inputs_match_the_sql():
    import yaml

    facts = yaml.safe_load((ROOT / "cost" / "inputs.yml").read_text())["facts"]
    tasks = (ROOT / "migrations" / "database" / "R__tasks.sql").read_text()
    assert "SCHEDULE = 'USING CRON 15 * * * * UTC'" in tasks and facts["task_graph_schedule_runs_per_day"] == 24
    admin = (ROOT / "migrations" / "admin" / "V1.0.1__warehouses_and_monitors.sql").read_text()
    transform = admin.split("WH_{{ env }}_TRANSFORM")[1].split(";")[0]
    bi = admin.split("WH_{{ env }}_BI")[1].split(";")[0]
    assert f"AUTO_SUSPEND = {facts['transform_auto_suspend_s']}" in transform
    assert f"AUTO_SUSPEND = {facts['bi_auto_suspend_s']}" in bi
    ops = (ROOT / "migrations" / "database" / "R__ops.sql").read_text()
    assert len(re.findall(r"CREATE OR REPLACE ALERT", ops)) * 24 == facts["alert_checks_per_day"]
