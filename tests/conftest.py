from pathlib import Path

import pytest

from generator.ridgeline import Config, generate
from sim.engine import run

# Small enough for a quick suite, long enough for late customers, stale CRM
# rows, re-sent events and cancellations to occur.
SMALL = Config(days=30, scale=0.2, seed=7)


@pytest.fixture(scope="session")
def landing(tmp_path_factory) -> Path:
    out = tmp_path_factory.mktemp("landing")
    generate(out, SMALL)
    return out


@pytest.fixture(scope="session")
def pipeline(landing):
    return run(landing)
