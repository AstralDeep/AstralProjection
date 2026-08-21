"""Behavioral contracts for the native SDUI construction helpers."""

from webrender.chrome.surfaces import _sdui


def test_content_helpers_emit_primitive_dicts_without_aliasing_inputs() -> None:
    child = _sdui.text("Body", "h2")
    children = [child]
    items = [{"label": "Status", "value": "Ready"}]
    tab_items = [{"label": "General", "value": "general", "content": [child]}]

    assert child == {"type": "text", "content": "Body", "variant": "h2"}
    assert _sdui.card("Summary", children, "accent") == {
        "type": "card",
        "title": "Summary",
        "content": [child],
        "variant": "accent",
    }
    assert _sdui.container(children, "column") == {
        "type": "container",
        "children": [child],
        "direction": "column",
    }
    assert _sdui.key_value(items, "Facts", 3) == {
        "type": "keyvalue",
        "items": items,
        "title": "Facts",
        "columns": 3,
    }
    assert _sdui.bullet_list(["one", "two"], ordered=True)["ordered"] is True
    assert _sdui.tabs(tab_items)["tabs"] == tab_items

    children.append(_sdui.text("Later"))
    items.append({"label": "Late", "value": "addition"})
    tab_items.append({"label": "Late", "value": "late", "content": []})
    assert len(_sdui.card("Summary", [child])["content"]) == 1
    assert len(_sdui.key_value([items[0]])["items"]) == 1
    assert len(_sdui.tabs([tab_items[0]])["tabs"]) == 1


def test_action_and_status_helpers_preserve_safe_contract_fields() -> None:
    assert _sdui.button("Retry", "retry", {"job": "j1"}, "primary") == {
        "type": "button",
        "label": "Retry",
        "action": "retry",
        "payload": {"job": "j1"},
        "variant": "primary",
    }
    assert _sdui.button("Retry", "retry")["payload"] == {}
    assert _sdui.badge("Ready", "success") == {
        "type": "badge",
        "label": "Ready",
        "variant": "success",
    }
    assert _sdui.alert("Saved", "success", "Settings")["variant"] == "success"
    assert _sdui.alert("Saved", "not-a-variant")["variant"] == "info"
    assert _sdui.placeholder("Remote machines") == {
        "type": "alert",
        "message": "“Remote machines” isn't available in this app yet.",
        "variant": "info",
    }


def test_field_emits_only_present_optional_values() -> None:
    assert _sdui.field("name", "Name") == {
        "name": "name",
        "label": "Name",
        "kind": "text",
    }
    assert _sdui.field(
        "enabled",
        "Enabled",
        kind="boolean",
        default=False,
        options=[],
        help="",
        step=0,
        visible_when={},
    ) == {
        "name": "enabled",
        "label": "Enabled",
        "kind": "boolean",
        "default": False,
        "options": [],
        "help": "",
        "step": 0,
        "visible_when": {},
    }


def test_form_supports_single_and_multi_action_submission() -> None:
    fields = [_sdui.field("model", "Model")]
    single = _sdui.form(
        fields,
        submit_action="chrome_llm_save",
        submit_label="Apply",
        submit_payload={"scope": "user"},
        title="LLM",
        description="Choose a model",
    )
    assert single["type"] == "param_picker"
    assert single["fields"] == fields
    assert single["submit_action"] == "chrome_llm_save"
    assert single["submit_payload"] == {"scope": "user"}
    assert single["submit_label"] == "Apply"

    actions = [{"label": "Test", "action": "chrome_llm_test", "variant": "secondary"}]
    multi = _sdui.form(fields, actions=actions)
    assert multi["actions"] == actions
    assert "submit_action" not in multi
    actions[0]["label"] = "mutated"
    assert multi["actions"][0]["label"] == "Test"
