"""Canvas review: constrained geometry and lossless chart data fallbacks."""
from copy import deepcopy

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile


@pytest.mark.parametrize("device", ["mobile", "android", "ios", "browser"])
def test_phone_chart_geometry_is_capability_based_and_preserves_data(device):
    profile = DeviceProfile.from_dict({"device_type": device, "viewport_width": 393})
    chart = {"type": "plotly_chart", "component_id": "forecast", "provenance": "grounded",
             "data": [{"name": "High", "x": ["Monday", "Tuesday"], "y": [81, 85]}],
             "layout": {"width": 1400, "height": 900, "xaxis": {"title": "Date"}}}
    original = deepcopy(chart)
    out = ComponentAdapter.adapt([chart], profile)[0]
    assert out["layout"]["height"] == 260
    assert "width" not in out["layout"]
    assert out["layout"]["xaxis"] == {"title": "Date", "automargin": True}
    assert out["data"] == chart["data"]
    assert out["component_id"] == "forecast" and out["provenance"] == "grounded"
    assert chart == original


@pytest.mark.parametrize("layout", [None, "invalid", {"xaxis": None, "yaxis": []}])
def test_phone_chart_without_usable_layout_still_adapts(layout):
    profile = DeviceProfile.from_dict({"device_type": "mobile", "viewport_width": 393})
    out = ComponentAdapter.adapt([{"type": "plotly_chart", "layout": layout}], profile)[0]
    assert out["layout"]["autosize"] is True
    assert out["layout"]["yaxis"]["automargin"] is True


def test_static_plotly_fallback_preserves_all_points_and_series():
    profile = DeviceProfile.default()
    profile.supported_types = frozenset({"table", "text", "list"})
    chart = {"type": "plotly_chart", "component_id": "rain", "provenance": "grounded",
             "data": [{"name": "Rain", "x": ["Mon", "Tue"], "y": [0.1, 0.2]},
                      {"labels": ["Wed"], "values": [0.3, 0.4]}, None,
                      {"y": "invalid"}, {"x": "invalid", "y": [1]}]}
    out = ComponentAdapter.adapt([chart], profile)[0]
    assert out["type"] == "table"
    assert out["rows"] == [["Rain", "Mon", 0.1], ["Rain", "Tue", 0.2],
                           ["Series 2", "Wed", 0.3], ["Series 2", 2, 0.4]]
    assert out["component_id"] == "rain" and out["provenance"] == "grounded"


def test_unrecognizable_plotly_still_has_labeled_fallback():
    profile = DeviceProfile.default()
    profile.supported_types = frozenset({"table", "list", "text"})
    out = ComponentAdapter.adapt([{"type": "plotly_chart", "title": "Unknown chart",
                                   "data": [None]}], profile)[0]
    assert out["type"] in {"list", "text"}
    assert "Unknown chart" in str(out)
