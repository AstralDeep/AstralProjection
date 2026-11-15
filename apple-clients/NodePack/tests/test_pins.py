"""Checks the pin command prints its one authoritative kernel revision and refuses other requests."""

import runpy
import sys

import pytest

import pins


def test_pin_cli_prints_the_authoritative_kernel_commit(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["pins.py", "kernel-commit"])
    runpy.run_path(pins.__file__, run_name="__main__")
    assert capsys.readouterr().out.strip() == pins.load()["kernel"]["commit"]


def test_pin_cli_refuses_an_unknown_query(monkeypatch):
    monkeypatch.setattr(sys, "argv", ["pins.py", "unknown"])
    with pytest.raises(SystemExit, match="usage"):
        runpy.run_path(pins.__file__, run_name="__main__")
