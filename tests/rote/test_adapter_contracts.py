"""Tests for backend/rote/adapter.py's less common device-adaptation branches: voice,
chart condensation, table bounding, and fallback substitution.
"""

from dataclasses import replace
from copy import deepcopy

import pytest

from rote import lod
from rote.adapter import ComponentAdapter, declared_action_count
from rote.capabilities import DeviceProfile


def _profile(device_type: str = "browser", **changes) -> DeviceProfile:
    return replace(DeviceProfile.from_dict({"device_type": device_type}), **changes)


@pytest.mark.parametrize(
    ("component", "expected"),
    [
        ({"type": "text", "content": "hello"}, "hello"),
        ({"type": "metric", "title": "CPU", "value": "50", "subtitle": "peak"}, "CPU: 50"),
        ({"type": "alert", "message": "Careful"}, "Careful"),
        ({"type": "image", "alt": "brain scan"}, "Image: brain scan"),
        ({"type": "image"}, "view it on another device"),
        ({"type": "code", "language": "python"}, "Code block: python"),
        ({"type": "rating", "label": "Helpful", "value": 4}, "4 out of 5 stars"),
        ({"type": "skeleton", "label": "Preparing"}, "Preparing"),
        ({"type": "button", "label": "Continue"}, "Continue"),
    ],
)
def test_voice_adaptation_extracts_human_readable_content(component, expected) -> None:
    result = ComponentAdapter.adapt([component], _profile("voice"))
    assert result[0]["type"] == "text"
    assert expected in result[0]["content"]


def test_voice_drops_empty_components_and_truncates_long_text() -> None:
    profile = _profile("voice", max_text_chars=5)
    assert ComponentAdapter.adapt([{"type": "unknown"}], profile) == []
    assert ComponentAdapter.adapt([{"type": "text", "content": "123456"}], profile) == [
        {"type": "text", "content": "12345", "variant": "body"}
    ]


def test_chart_condensation_handles_pie_dataset_plotly_and_empty_data() -> None:
    watch = _profile("watch")
    cases = [
        ({"type": "pie_chart", "labels": ["A", "B"], "data": [1, 3]}, "B: 3"),
        ({"type": "line_chart", "datasets": [{"label": "Series", "data": [7]}]}, "Series: 7"),
        ({"type": "bar_chart", "datasets": [{"data": [8]}]}, "8"),
        ({"type": "plotly_chart", "data": [{"y": [9]}]}, "9"),
        ({"type": "line_chart"}, "N/A"),
    ]
    for component, expected in cases:
        assert ComponentAdapter.adapt([component], watch)[0]["value"] == expected


def test_table_adaptation_degrades_or_bounds_rows_and_columns() -> None:
    table = {
        "type": "table",
        "title": "Measurements",
        "headers": ["A", "B"],
        "rows": [[1, 2, 3], [4, 5, 6]],
    }
    degraded = ComponentAdapter.adapt(
        [table],
        _profile("watch", max_table_rows=1, max_table_cols=3),
    )[0]
    assert degraded == {
        "type": "list",
        "title": "Measurements",
        "items": ["A: 1 | B: 2 | 3"],
        "ordered": False,
    }

    bounded = ComponentAdapter.adapt(
        [table],
        _profile("browser", max_table_rows=1, max_table_cols=1),
    )[0]
    assert bounded["headers"] == ["A"]
    assert bounded["rows"] == [[1]]


def test_grid_tabs_collapsible_and_container_recursively_drop_unsupported_children() -> None:
    watch = _profile("watch")
    grid = {
        "type": "grid",
        "id": "grid-1",
        "columns": 3,
        "children": [{"type": "code", "content": "secret"}],
    }
    assert ComponentAdapter.adapt([grid], watch) == [
        {"type": "container", "id": "grid-1", "children": []}
    ]
    assert ComponentAdapter.adapt([{"type": "tabs", "tabs": []}], watch) == []
    flattened = ComponentAdapter.adapt(
        [{"type": "tabs", "tabs": [{"label": "One", "content": [{"type": "text", "content": "x"}]}]}],
        watch,
    )[0]
    assert flattened["type"] == "card" and flattened["title"] == "One"

    collapsible = ComponentAdapter.adapt(
        [{"type": "collapsible", "title": "Details", "content": [{"type": "file_upload"}]}],
        watch,
    )[0]
    assert collapsible == {"type": "card", "title": "Details", "content": []}

    browser = _profile("browser")
    nested = ComponentAdapter.adapt(
        [{"type": "container", "children": [{"type": "card", "content": [{"type": "text", "content": "x"}]}]}],
        browser,
    )
    assert nested[0]["children"][0]["content"][0]["content"] == "x"


def test_supported_rich_components_recurse_and_pass_through() -> None:
    browser = _profile("browser")
    tabs = {"type": "tabs", "tabs": [{"label": "One", "content": [{"type": "text", "content": "x"}]}]}
    collapsible = {"type": "collapsible", "title": "D", "content": [{"type": "text", "content": "x"}]}
    assert ComponentAdapter.adapt([tabs], browser)[0]["tabs"][0]["content"][0]["content"] == "x"
    assert ComponentAdapter.adapt([collapsible], browser)[0]["content"][0]["content"] == "x"
    assert ComponentAdapter.adapt([{"type": "code"}, {"type": "file_download"}], browser) == [
        {"type": "code"},
        {"type": "file_download"},
    ]


def test_buttons_skeleton_history_and_download_cards_follow_device_bounds() -> None:
    assert ComponentAdapter.adapt([{"type": "button", "action": "go"}], _profile("tv")) == []
    assert ComponentAdapter.adapt(
        [{"type": "button", "variant": "secondary"}], _profile("watch")
    ) == []
    assert ComponentAdapter.adapt(
        [{"type": "button", "variant": "primary"}], _profile("watch")
    ) == [{"type": "button", "variant": "primary"}]
    assert ComponentAdapter.adapt(
        [{"type": "skeleton", "count": "bad"}], _profile("mobile")
    ) == [{"type": "skeleton", "count": "bad"}]

    history = {"type": "chat_history", "items": [{"title": str(i), "preview": "p"} for i in range(12)]}
    mobile = ComponentAdapter.adapt([history], _profile("mobile"))[0]
    watch = ComponentAdapter.adapt([history], _profile("watch"))[0]
    assert len(mobile["items"]) == 10
    assert len(watch["items"]) == 4 and all("preview" not in item for item in watch["items"])

    no_url = ComponentAdapter.adapt(
        [{"type": "download_card", "version": "2.0"}], _profile("watch")
    )[0]
    assert no_url == {"type": "text", "content": "Download Astral desktop v2.0", "variant": "body"}


def test_fallback_substitution_handles_lists_tables_containers_and_unknown_types() -> None:
    list_profile = _profile("browser", supported_types=frozenset({"list", "text"}))
    timeline = {
        "type": "timeline",
        "title": "Events",
        "items": [{"time": "09:00", "title": "Start", "description": "Ready"}, "skip"],
    }
    assert ComponentAdapter.adapt([timeline], list_profile)[0] == {
        "type": "list",
        "title": "Events",
        "ordered": False,
        "items": ["09:00 — Start — Ready"],
    }

    table_profile = _profile("browser", supported_types=frozenset({"table", "text"}))
    key_value = {
        "type": "keyvalue",
        "title": "Facts",
        "items": [{"label": "A", "value": "B"}, "skip"],
    }
    assert ComponentAdapter.adapt([key_value], table_profile)[0] == {
        "type": "table",
        "title": "Facts",
        "headers": ["", ""],
        "rows": [["A", "B"]],
    }

    chart = {
        "type": "line_chart",
        "title": "Trend",
        "data": {"labels": ["Jan", "Feb"], "series": [{"name": "Sales", "data": [1]}]},
    }
    converted = ComponentAdapter.adapt([chart], table_profile)[0]
    assert converted["headers"] == ["label", "Sales"]
    assert converted["rows"] == [["Jan", 1], ["Feb", ""]]

    container_profile = _profile("browser", supported_types=frozenset({"card", "text"}))
    wrapped = ComponentAdapter.adapt(
        [{"type": "unknown", "title": "Wrapper", "children": [{"type": "badge", "label": "ok"}]}],
        container_profile,
    )[0]
    assert wrapped["type"] == "text" and wrapped["content"] == "ok"

    wrapped_container = ComponentAdapter.adapt(
        [{"type": "collapsible", "title": "Wrapper", "content": [{"type": "badge", "label": "ok"}]}],
        container_profile,
    )[0]
    assert wrapped_container == {
        "type": "card",
        "title": "Wrapper",
        "content": [{"type": "text", "content": "ok", "variant": "body"}],
    }


def test_lod_failure_is_fail_open_and_nested_ladders_are_consumed(monkeypatch) -> None:
    monkeypatch.setattr(lod, "lod_enabled", lambda: True)
    monkeypatch.setattr(ComponentAdapter, "_lod_device", classmethod(lambda cls, profile: (_ for _ in ()).throw(RuntimeError("boom"))))
    original = {"type": "text", "content": "full", "lod": {"l1": "short"}}
    assert ComponentAdapter.adapt([original], _profile("browser")) == [original]

    monkeypatch.setattr(
        ComponentAdapter,
        "_lod_device",
        classmethod(lambda cls, profile: {"device_type": "watch", "is_small": True}),
    )
    nested = {
        "type": "tabs",
        "tabs": [{"label": "One", "content": [{"type": "text", "content": "full", "lod": {"l1": "short"}}]}],
    }
    out = ComponentAdapter.adapt([nested], _profile("browser"))[0]
    assert out["tabs"][0]["content"][0] == {"type": "text", "content": "short"}


def test_host_action_budget_traverses_tab_content_and_ignores_non_dicts() -> None:
    profile = _profile("browser", max_actions=1)
    components = [
        "unchanged",
        {
            "type": "tabs",
            "tabs": [
                {"label": "One", "content": [{"type": "button", "action": "first"}]},
                {"label": "Two", "content": [{"type": "button", "action": "second"}]},
            ],
        },
    ]
    out = ComponentAdapter.adapt(components, profile)
    assert out[0] == "unchanged"
    assert len(out[1]["tabs"][0]["content"]) == 1
    assert out[1]["tabs"][1]["content"] == []


@pytest.mark.parametrize("device", ["ios", "macos", "android", "windows"])
def test_native_form_action_metadata_survives_full_adaptation(device) -> None:
    actions = [
        {"label": label, "action": action, "payload": {"operation": operation,
         "context": {"type": "not_a_component", "value": "retained"}}}
        for label, action, operation in (
            ("Load models", "chrome_llm_models", "load"),
            ("Test connection", "chrome_llm_test", "test"),
            ("Save", "chrome_llm_save", "save"),
            ("Save TypeSafe key", "chrome_typesafe_save", "save"),
        )
    ]
    original = {"type": "card", "content": [{"type": "param_picker",
                "fields": [], "actions": actions}]}
    snapshot = deepcopy(original)
    profile = _profile(device, supported_types=frozenset({"card", "param_picker", "text"}))
    adapted = ComponentAdapter.adapt([original], profile)
    assert adapted[0]["content"][0]["actions"] == actions
    assert original == snapshot


def test_metadata_preservation_does_not_skip_typed_action_fallback() -> None:
    component = {"type": "param_picker", "fields": [], "actions": [
        {"label": "Save", "action": "save"},
        {"type": "unsupported", "content": "Unavailable"},
    ]}
    output = ComponentAdapter._degrade_unsupported(component, {"param_picker", "text"})
    assert output["actions"][0] == {"label": "Save", "action": "save"}
    assert output["actions"][1]["type"] == "text"


def test_form_descriptors_share_budget_with_buttons_and_submit_actions() -> None:
    original = [
        {"type": "button", "label": "First", "action": "first"},
        {"type": "param_picker", "fields": [], "actions": [
            {"label": "Save", "action": "save", "payload": {"value": 1}},
            {"label": "Test", "action": "test"},
        ]},
        {"type": "param_picker", "fields": [], "submit_action": "other", "submit_payload": {"id": 1}},
    ]
    snapshot = deepcopy(original)
    output = ComponentAdapter.adapt(original, _profile("ios", max_actions=2))
    assert output[1]["actions"] == [original[1]["actions"][0]]
    assert output[2]["type"] == "text"
    assert original == snapshot


@pytest.mark.parametrize("form", [
    {"type": "param_picker", "fields": [], "actions": [{"label": "Save", "action": "save"}]},
    {"type": "param_picker", "fields": [], "submit_action": "save"},
    {"type": "param_picker", "fields": [], "submit_message_template": "Send {value}"},
])
def test_read_only_hosts_cannot_execute_forms(form) -> None:
    result = ComponentAdapter.adapt([form], _profile("ios", supports_interactivity=False))
    assert result[0]["type"] == "text"
    assert "unavailable" in result[0]["content"].lower()
    assert not any(key in result[0] for key in ("actions", "submit_action", "submit_message_template"))


def test_single_form_submit_consumes_budget_and_preserves_identity_on_denial() -> None:
    forms = [{"type": "param_picker", "id": name, "fields": [], "submit_action": name}
             for name in ("save", "test")]
    output = ComponentAdapter.adapt(forms, _profile("ios", max_actions=1))
    assert output[0]["submit_action"] == "save"
    assert output[1]["type"] == "text"
    assert output[1]["id"] == "test"


@pytest.mark.parametrize("limits", [
    {"supports_interactivity": False},
    {"max_actions": 1},
])
def test_implicit_color_save_obeys_host_limits_and_preserves_identity(limits) -> None:
    picker = {"type": "color_picker", "id": "appearance", "title": "Appearance",
              "colors": {"primary": "#123456"}, "role": "primary"}
    original = [{"type": "button", "label": "First", "action": "first"}, picker]
    snapshot = deepcopy(original)
    output = ComponentAdapter.adapt(original, _profile(
        "ios", supported_types=frozenset({"text", "button", "color_picker"}), **limits))
    assert output[-1] == {"type": "text", "variant": "body", "id": "appearance",
                          "content": "Appearance is unavailable on this device."}
    assert original == snapshot


def test_implicit_color_save_consumes_budget_without_limiting_accepted_theme() -> None:
    theme = {"type": "theme_apply", "colors": {"primary": "#123456"}}
    picker = {"type": "color_picker", "id": "appearance", "role": "primary"}
    output = ComponentAdapter.adapt([theme, picker, {"type": "button", "action": "next"}],
                                    _profile("ios", max_actions=1))
    assert output == [theme, picker]
    assert ComponentAdapter.adapt([theme], _profile("ios", supports_interactivity=False)) == [theme]


def test_declared_action_count_is_shared_across_actionable_primitive_shapes() -> None:
    assert declared_action_count({"type": "button", "action": "go"}) == 1
    assert declared_action_count({"type": "button", "label": "Inert"}) == 0
    assert declared_action_count({"type": "file_upload", "action": "attach_file"}) == 1
    assert declared_action_count({"type": "file_upload", "label": "Upload"}) == 0
    assert declared_action_count({"type": "param_picker", "fields": [], "submit_action": "save"}) == 1
    assert declared_action_count({"type": "param_picker", "fields": [],
                                  "submit_message_template": "Run {value}"}) == 1
    assert declared_action_count({"type": "param_picker", "fields": [],
                                  "actions": [{"label": "Noop"}, {"action": "go"}],
                                  "submit_action": "save"}) == 2
    assert declared_action_count({"type": "param_picker", "fields": []}) == 0
    assert declared_action_count({"type": "text", "content": "x"}) == 0


def test_actionable_file_upload_is_withdrawn_for_read_only_hosts() -> None:
    original = {"type": "file_upload", "id": "up1", "label": "Upload Scan", "action": "attach_file"}
    output = ComponentAdapter.adapt([original], _profile("browser", supports_interactivity=False))
    assert output[0]["type"] == "text"
    assert "unavailable" in output[0]["content"].lower()
    assert output[0]["id"] == "up1"
    assert "action" not in output[0]


def test_file_upload_without_action_is_not_budgeted_or_withdrawn() -> None:
    upload = {"type": "file_upload", "id": "up1", "label": "Upload Scan"}
    original = [{"type": "button", "id": "b1", "label": "Go", "action": "go"}, upload]
    output = ComponentAdapter.adapt(original, _profile("browser", max_actions=1))
    assert output[0] == original[0]
    assert output[1] == upload


def test_actionable_file_upload_shares_budget_with_buttons() -> None:
    original = [
        {"type": "button", "id": "b1", "label": "Go", "action": "go"},
        {"type": "file_upload", "id": "up1", "label": "Upload Scan", "action": "attach_file"},
    ]
    output = ComponentAdapter.adapt(original, _profile("browser", max_actions=1))
    assert output[0]["type"] == "button"
    assert output[1]["type"] == "text"
    assert output[1]["id"] == "up1"
    assert "action" not in output[1]

    reversed_out = ComponentAdapter.adapt(
        [dict(original[1]), dict(original[0])], _profile("browser", max_actions=1))
    assert len(reversed_out) == 1
    assert reversed_out[0]["type"] == "file_upload"
    assert reversed_out[0]["action"] == "attach_file"


def test_budget_covers_actionable_primitives_nested_in_tabs_and_cards() -> None:
    original = [{"type": "tabs", "tabs": [{"label": "One", "content": [
        {"type": "card", "content": [
            {"type": "file_upload", "id": "f1", "label": "Docs", "action": "a1"},
            {"type": "file_upload", "id": "f2", "label": "Images", "action": "a2"},
            {"type": "param_picker", "id": "f3", "fields": [],
             "submit_message_template": "Run {value}"},
            {"type": "action_group", "buttons": [{"action": "a3"}]},
        ]}]}]}]
    output = ComponentAdapter.adapt(original, _profile("browser", max_actions=2))
    kept = output[0]["tabs"][0]["content"][0]["content"]
    assert [c["id"] for c in kept if c.get("type") == "file_upload"] == ["f1", "f2"]
    assert [c["action"] for c in kept if c.get("type") == "file_upload"] == ["a1", "a2"]
    assert kept[2]["type"] == "text" and kept[2]["id"] == "f3"
    assert "submit_message_template" not in kept[2]
    assert kept[3]["buttons"] == []


def test_submit_template_only_form_is_counted_against_budget() -> None:
    original = [
        {"type": "param_picker", "id": "f1", "fields": [], "submit_message_template": "Run {value}"},
        {"type": "param_picker", "id": "f2", "fields": [], "submit_message_template": "Send {x}"},
    ]
    output = ComponentAdapter.adapt(original, _profile("ios", max_actions=1))
    assert output[0]["submit_message_template"] == "Run {value}"
    assert output[1]["type"] == "text"
    assert output[1]["id"] == "f2"


def test_zero_and_unlimited_budgets_keep_authorized_behavior() -> None:
    components = [
        {"type": "button", "id": "b1", "label": "Go", "action": "go"},
        {"type": "file_upload", "id": "up1", "label": "Upload", "action": "attach_file"},
        {"type": "param_picker", "id": "f1", "fields": [], "submit_action": "save",
         "actions": [{"label": "Test", "action": "test"}]},
    ]
    snapshot = deepcopy(components)
    unlimited = ComponentAdapter.adapt(components, _profile("ios"))
    assert unlimited[0]["action"] == "go"
    assert unlimited[1]["action"] == "attach_file"
    assert unlimited[2]["submit_action"] == "save"
    assert unlimited[2]["actions"] == components[2]["actions"]
    assert components == snapshot
