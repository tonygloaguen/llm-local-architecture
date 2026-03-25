"""Smoke tests for the minimal Python package."""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from llm_local_architecture import get_package_name


def test_package_name() -> None:
    assert get_package_name() == "llm_local_architecture"
