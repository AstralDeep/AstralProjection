"""Tests that the installed astralprojection distribution publishes the view builders that astral-rote's adapter resolves."""

from importlib.metadata import entry_points

import pytest

from astralprojection.chrome.guidance import build_guidance_view, build_notes_view
from astralprojection.chrome.terminal import build_terminal_view
from rote.surfaces import ENTRY_POINT_GROUP, surface_builder

EXPECTED = {
    "guidance": build_guidance_view,
    "notes": build_notes_view,
    "terminal": build_terminal_view,
}


def test_the_group_lists_exactly_the_projection_builders():
    published = {entry.name: entry.value for entry in entry_points(group=ENTRY_POINT_GROUP)}
    assert published == {
        "guidance": "astralprojection.chrome.guidance:build_guidance_view",
        "notes": "astralprojection.chrome.guidance:build_notes_view",
        "terminal": "astralprojection.chrome.terminal:build_terminal_view",
    }


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_rote_resolves_each_builder_to_the_projection_function(name):
    assert surface_builder(name, f"{name}_surface_unavailable") is EXPECTED[name]
