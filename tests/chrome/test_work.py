"""Shared Work views consume public snapshots without granting actions."""

from copy import deepcopy
import json

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome.work import build_work_view
from astralprojection.models import LayoutView, ThemeView

ID = "180cd30b-cc38-432d-8349-1851b0d3ad7e"
OTHER = "48873d61-2e9b-4f38-bc36-bbfa81d78580"
ACTION = "fc5c2124-ce23-48d9-927b-9c004d950c10"
TIME = "2026-09-12T12:00:00+00:00"


def operation(**values):
    return {
        "id": ID,
        "revision": 3,
        "instruction_revision": 1,
        "control_epoch": 1,
        "title": "Public page research",
        "kind": "research",
        "disposition": "completed",
        "lifecycle": "completed",
        "phase": "waiting",
        "created_at": TIME,
        "updated_at": TIME,
        "next_wake_at": None,
        "deadline_at": TIME,
        "schema_supported": True,
        "safe_error_code": None,
        "usage": {},
        **values,
    }


def result():
    return {
        "id": ID,
        "revision": 3,
        "result": {
            "version": 1,
            "available": True,
            "reason": None,
            "content": {
                "version": 1,
                "scope": "one_page_excerpts",
                "disposition": "evidence",
                "source": {
                    "requested_url": "https://example.org/start",
                    "final_url": "https://example.org/page",
                    "retrieved_at": TIME,
                    "media_type": "text/html",
                    "extraction_profile": "html_readable_v1",
                    "title": "Original source",
                    "body_complete": True,
                    "extraction_complete": True,
                    "excerpt_complete": True,
                    "redacted": False,
                    "action_id": ACTION,
                    "result_digest": "a" * 64,
                    "revision_digest": "b" * 64,
                },
                "passages": [{"id": "p001", "text": "Exact retained evidence.\nSecond line."}],
            },
        },
    }


def state(mode="result", **values):
    return {
        "mode": mode,
        "status": "ready",
        "operation": operation(),
        "result": result(),
        "page": {"operations": [operation()], "next_cursor": None, "page_full": False},
        **values,
    }


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def encoded(view):
    return json.dumps(view.to_dict(), ensure_ascii=False)


def buttons(view):
    return [node for node in nodes(view.to_dict()) if node.get("type") == "button"]


def unavailable(value):
    view = build_work_view(value)
    assert "unavailable" in render_html(view).lower()
    assert "Exact retained evidence" not in encoded(view)
    return view


def test_result_is_exact_attributed_content_first_and_only_navigation():
    value = state()
    before = deepcopy(value)
    view = build_work_view(value)
    html = render_html(view)
    assert value == before
    assert "Exact retained evidence.\nSecond line." in html
    assert html.index("Exact retained evidence") < html.index("Requested URL")
    assert "https://example.org/page" in html and "Original source" in html
    assert "full visual page" in html and "HTML readable text" in html
    assert "Save" not in html and "Approve" not in html
    for button in buttons(view):
        assert button["action"] == "chrome_open"
        assert button["payload"]["surface"] == "work"
        assert set(button["payload"]["params"]) <= {"mode", "operation_id", "after_id"}
    assert "result_digest" not in encoded(view) and "action_id" not in encoded(view)


@pytest.mark.parametrize("mode", ["compact", "standard", "wide", "watch"])
def test_form_factors_keep_all_evidence_and_shared_navigation(mode):
    ordinary = build_work_view(state())
    view = build_work_view(state(), layout=LayoutView(mode=mode), theme=ThemeView(contrast="high"))
    assert view.to_dict()["components"] == ordinary.to_dict()["components"]
    assert view.layout.mode == mode and view.theme.contrast == "high"


@pytest.mark.parametrize("status,label", [("loading", "Loading"), ("unavailable", "unavailable")])
def test_loading_and_unavailable_never_display_stale_payload(status, label):
    view = build_work_view(state(status=status, error="PRIVATE_DIAGNOSTIC"))
    assert label in render_html(view)
    assert "Exact retained evidence" not in encoded(view) and "PRIVATE_DIAGNOSTIC" not in encoded(
        view
    )


def test_empty_and_page_navigation_are_truthful():
    empty = state("list", page={"operations": [], "next_cursor": None, "page_full": False})
    assert "No work yet" in render_html(build_work_view(empty))
    page = {"operations": [operation()], "next_cursor": ID, "page_full": True}
    view = build_work_view(state("list", page=page))
    assert any(b["payload"]["params"] == {"mode": "list", "after_id": ID} for b in buttons(view))
    assert any(
        b["payload"]["params"] == {"mode": "detail", "operation_id": ID} for b in buttons(view)
    )


@pytest.mark.parametrize(
    "disposition,label",
    [
        ("queued", "Queued"),
        ("active", "In progress"),
        ("awaiting_approval", "Review required"),
        ("awaiting_authority", "Authorization required"),
        ("budget_blocked", "Budget limit reached"),
        ("reconciliation_required", "Outcome uncertain"),
        ("paused", "Paused"),
        ("awaiting_event", "Waiting for an event"),
        ("retry_eligible", "Retry eligible"),
        ("completed", "Completed"),
        ("failed", "Failed"),
        ("cancelled", "Cancelled"),
        ("unsupported_version", "Unsupported version"),
    ],
)
def test_public_dispositions_are_not_guessed_from_phase(disposition, label):
    view = build_work_view(state("detail", operation=operation(disposition=disposition)))
    assert label in render_html(view)
    assert {b["action"] for b in buttons(view)} == {"chrome_open"}


def test_usage_missing_unknown_zero_and_unpriced_money_are_distinct():
    missing = render_html(build_work_view(state("detail")))
    assert "Usage not recorded" in missing
    row = operation(
        usage={
            "spent": {"tokens": 0, "tool_calls": None, "spend_micro_units": 30},
            "outstanding": {"tokens": 10},
        }
    )
    html = render_html(build_work_view(state("detail", operation=row)))
    assert "<dd>0</dd>" in html and "Unknown" in html
    assert "30 micro-units (currency unavailable)" in html
    assert "Outstanding" in html and "<dd>10</dd>" in html


@pytest.mark.parametrize("amount", [0, 30, None])
@pytest.mark.parametrize("bucket", ["spent", "daily", "outstanding"])
def test_monetary_amount_preserves_known_zero_and_nonzero_without_inventing_currency(
    amount, bucket
):
    row = operation(usage={bucket: {"spend_micro_units": amount}})
    html = render_html(build_work_view(state("detail", operation=row)))
    expected = "Unknown" if amount is None else f"{amount} micro-units (currency unavailable)"
    assert f"<dd>{expected}</dd>" in html
    assert "USD" not in html and "Unpriced" not in html
    if amount is not None:
        assert "Unknown" not in html


@pytest.mark.parametrize(
    "key", ["body_complete", "extraction_complete", "excerpt_complete", "redacted"]
)
def test_completeness_dimensions_remain_independent(key):
    value = state()
    source = value["result"]["result"]["content"]["source"]
    source[key] = key == "redacted"
    html = render_html(build_work_view(value))
    assert {
        "body_complete": "Response body incomplete",
        "extraction_complete": "Extraction incomplete",
        "excerpt_complete": "Retained text incomplete",
        "redacted": "Content was redacted",
    }[key] in html
    assert "Exact retained evidence" in html


def test_insufficient_evidence_is_not_a_successful_answer_or_empty_result():
    value = state()
    page = value["result"]["result"]["content"]
    page.update(disposition="insufficient_evidence", passages=[])
    html = render_html(build_work_view(value))
    assert "Insufficient evidence" in html and "https://example.org/page" in html


@pytest.mark.parametrize(
    "reason,label",
    [
        ("unsupported", "not supported"),
        ("not_completed", "not completed"),
        ("not_retained", "not retained"),
        ("unavailable", "unavailable"),
    ],
)
def test_closed_unavailable_result_reasons(reason, label):
    value = state()
    value["result"]["result"].update(available=False, reason=reason, content=None)
    assert label in render_html(build_work_view(value))


@pytest.mark.parametrize(
    "change",
    [
        {"id": OTHER},
        {"revision": 4},
        {"revision": True},
        {"extra": "SECRET"},
    ],
)
def test_wrong_result_identity_revision_or_outer_schema_refused(change):
    value = state()
    value["result"].update(change)
    unavailable(value)


@pytest.mark.parametrize(
    "change",
    [
        {"version": True},
        {"version": 2},
        {"available": 1},
        {"reason": "SECRET"},
        {"extra": "SECRET"},
        {"available": False},
        {"content": None},
    ],
)
def test_malformed_result_envelopes_refused(change):
    value = state()
    value["result"]["result"].update(change)
    unavailable(value)


@pytest.mark.parametrize(
    "change",
    [
        {"version": 2},
        {"scope": "free_form_answer"},
        {"disposition": "summary"},
        {"passages": []},
        {"passages": [{"id": "p001", "text": "evidence"}] * 2},
        {"passages": [{"id": "p000", "text": "evidence"}]},
        {"passages": [{"id": "p001", "text": "evidence", "private": "SECRET"}]},
        {"passages": [{"id": "p001", "text": "x" * 513}]},
        {"passages": [{"id": "p001", "text": "\ud800"}]},
        {"passages": [{"id": "p001", "text": "\x00SECRET"}]},
        {"extra": "SECRET"},
    ],
)
def test_malformed_evidence_never_becomes_partial_success(change):
    value = state()
    value["result"]["result"]["content"].update(change)
    unavailable(value)


@pytest.mark.parametrize(
    "change",
    [
        {"body_complete": 1},
        {"retrieved_at": "2026-09-12T12:00:00"},
        {"extraction_profile": "visual_page"},
        {"media_type": "image/png"},
        {"action_id": OTHER.upper()},
        {"result_digest": "wrong"},
        {"requested_url": "javascript:alert(1)"},
        {"final_url": "https://user:secret@example.org"},
        {"final_url": "/private"},
        {"title": {"secret": "SECRET"}},
        {"extra": "SECRET"},
    ],
)
def test_malformed_source_is_not_rendered_or_navigated(change):
    value = state()
    value["result"]["result"]["content"]["source"].update(change)
    unavailable(value)


def test_html_and_private_unknown_fields_never_escape_the_projection():
    value = state()
    value["operation"].update(title='<img src=x onerror="secret()">', private="SECRET")
    value["private"] = {"token": "SECRET"}
    value["result"]["result"]["content"]["passages"][0]["text"] = "<script>test()</script>"
    view = build_work_view(value)
    html = render_html(view)
    assert "<script>" not in html and "<img " not in html
    assert "&lt;script&gt;" in html and "&lt;img" in html
    assert "SECRET" not in encoded(view)


@pytest.mark.parametrize(
    "change",
    [
        {"id": "bad"},
        {"revision": True},
        {"title": {"secret": "SECRET"}},
        {"disposition": "invented"},
        {"schema_supported": 1},
        {"usage": {"spent": {"tokens": -1}}},
        {"created_at": "bad"},
    ],
)
def test_invalid_public_metadata_refused(change):
    unavailable(state("detail", operation=operation(**change)))


@pytest.mark.parametrize(
    "page",
    [
        {},
        {"operations": None, "page_full": False, "next_cursor": None},
        {"operations": [operation()] * 101, "page_full": False, "next_cursor": None},
        {"operations": [operation()] * 2, "page_full": False, "next_cursor": None},
        {"operations": [], "page_full": True, "next_cursor": ID},
        {"operations": [operation()], "page_full": False, "next_cursor": ID},
        {"operations": [operation()], "page_full": True, "next_cursor": OTHER},
    ],
)
def test_invalid_pages_never_masquerade_as_empty_or_offer_bad_cursor(page):
    view = unavailable(state("list", page=page))
    assert not any("after_id" in b["payload"]["params"] for b in buttons(view))


@pytest.mark.parametrize(
    "value", [None, {}, {"mode": "edit", "status": "ready"}, state(status="maybe")]
)
def test_bad_host_view_state_fails_closed(value):
    unavailable(value)


def test_whole_result_utf8_budget_counts_urls_metadata_and_all_passages():
    value = state()
    page = value["result"]["result"]["content"]
    page["passages"] = [{"id": f"p{number:03}", "text": "🙂" * 512} for number in range(1, 9)]
    assert len(json.dumps(page, ensure_ascii=False).encode()) > 8192
    unavailable(value)
    page["passages"] = [{"id": "p001", "text": "keep me"}]
    page["source"].update(
        requested_url="https://example.org/" + "x" * 4000,
        final_url="https://example.org/" + "y" * 4000,
    )
    view = unavailable(value)
    assert "keep me" not in encoded(view)


def test_maximum_passages_exact_unicode_and_selection_order_preserved():
    value = state()
    page = value["result"]["result"]["content"]
    page["passages"] = [
        {"id": f"p{number:03}", "text": f"段落 {number} " + "x" * 500} for number in range(8, 0, -1)
    ]
    view = build_work_view(value)
    actual = [node["content"] for node in nodes(view.to_dict()) if node.get("type") == "text"]
    expected = [item["text"] for item in page["passages"]]
    assert [item for item in actual if item in expected] == expected


@pytest.mark.parametrize(
    "media,profile,label",
    [
        ("text/plain", "plain_text_v1", "Plain text"),
        ("application/xhtml+xml", "html_readable_v1", "HTML readable text"),
    ],
)
def test_supported_extractor_pairs_and_empty_source_title(media, profile, label):
    value = state()
    value["result"]["result"]["content"]["source"].update(
        title="", media_type=media, extraction_profile=profile
    )
    html = render_html(build_work_view(value))
    assert "Exact retained evidence" in html and label in html


def test_future_usage_fields_are_not_forwarded_or_counted_as_zero():
    row = operation(usage={"future": {"payload": "SECRET"}, "spent": {"future": "SECRET"}})
    view = build_work_view(state("detail", operation=row))
    assert "SECRET" not in encoded(view) and "Usage not recorded" in render_html(view)


@pytest.mark.parametrize(
    "change", [{"title": " "}, {"title": "x" * 4097}, {"revision": 2**63}, {"usage": {"spent": []}}]
)
def test_additional_metadata_bounds_do_not_raise_or_expose_content(change):
    unavailable(state(operation=operation(**change)))


@pytest.mark.parametrize(
    "change",
    [
        {"requested_url": " https://example.org"},
        {"final_url": "https://example.org:99999"},
        {"retrieved_at": "2026-09-12T12:00:00+01:00"},
        {"title": "🙂" * 129},
        {"revision_digest": "F" * 64},
    ],
)
def test_source_size_time_and_url_shape_bounds(change):
    value = state()
    value["result"]["result"]["content"]["source"].update(change)
    unavailable(value)


@pytest.mark.parametrize("layout", ["compact", "standard", "wide", "watch"])
def test_actual_producer_maximum_size_golden_is_fully_renderable(layout):
    # Actual Deep build_page_result output reproduced by the retained producer
    # compatibility probe. These hashes are input facts, not UI authentication.
    value = state()
    page = value["result"]["result"]["content"]
    page["source"].update(
        title="🙂" * 128,
        requested_url="https://example.org/段落/" + "a" * 1638,
        final_url="https://example.org/段落/" + "b" * 1638,
        result_digest="352f8ea11cb852aa7af1b109e2a7e3ee66446e3538ca0cda386dee3ef96131a3",
        revision_digest="64da6a6614b04dc7ea9387e165821bb971e817b8e58f4d8d981d5d24d1e403e1",
    )
    page["passages"] = [
        {"id": f"p{number:03}", "text": "🙂" + "x" * 511} for number in range(1, 8)
    ] + [{"id": "p008", "text": "zq"}]
    assert (
        len(json.dumps(page, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode())
        == 8192
    )
    view = build_work_view(value, layout=LayoutView(mode=layout))
    actual = [n["content"] for n in nodes(view.to_dict()) if n.get("type") == "text"]
    assert actual[1:9] == [item["text"] for item in page["passages"]]
    assert len(encoded(view).encode()) > 8192
    page["source"]["final_url"] += "x"
    unavailable(value)


@pytest.mark.parametrize(
    "change", [{"disposition": "active"}, {"schema_supported": False}, {"kind": "chat"}]
)
def test_available_result_cannot_override_incompatible_public_metadata(change):
    unavailable(state(operation=operation(**change)))


# ── Feature 088 T043: exact Save bindings and the review layout ────────────────

SUBMISSION = "48873d61-2e9b-4f38-bc36-bbfa81d78580"
PUBLICATION = "7c3d5a9e-1f2b-4c6d-8e7f-0a1b2c3d4e5f"
APPROVAL = "9e8d7c6b-5a4f-4e3d-8c2b-1a0f9e8d7c6b"
SAVE_ACTION = "chrome_work_result_save"
EXPIRES = "2026-09-12T12:15:00+00:00"


def save(**values):
    return {
        "submission_id": SUBMISSION,
        "publication_id": PUBLICATION,
        "expected_revision": 3,
        "conversation_id": "chat-1",
        "conversation_title": "Reviewed result destination",
        "expected_workspace_revision": 0,
        "expected_workspace_publication_id": None,
        **values,
    }


def payload():
    return {
        "type": "card",
        "title": "Public page research",
        "variant": "default",
        "content": [
            {"type": "text", "content": "Exact retained evidence.\nSecond line.", "variant": "body"},
            {
                "type": "text",
                "content": "Selected source text, not a summary of the full visual page.",
                "variant": "caption",
            },
            {
                "type": "keyvalue",
                "title": "Original source",
                "columns": 2,
                "items": [
                    {"label": "Requested URL", "value": "https://example.org/start"},
                    {"label": "Retrieved URL", "value": "https://example.org/page"},
                    {"label": "Retrieved at", "value": TIME},
                ],
            },
        ],
    }


def review():
    return {
        "version": 1,
        "status": "review_required",
        "created": True,
        "revision": 4,
        "proposal": {
            "action_id": SUBMISSION,
            "proposal_digest": "c" * 64,
            "publication_id": PUBLICATION,
            "conversation_id": "chat-1",
            "component_id": "au_work_result_" + ID,
            "base_render_revision": 0,
            "base_publication_id": None,
            "content_digest": "d" * 64,
            "stage_digest": "e" * 64,
            "expires_at": EXPIRES,
        },
        "component": {
            "component_id": "au_work_result_" + ID,
            "component_type": "card",
            "title": "Public page research",
            "position": 0,
            "payload": payload(),
        },
    }


def review_state(**values):
    defaults = {
        "operation": operation(revision=4),
        "review": review(),
        "approve": {"submission_id": APPROVAL, "expired": False},
        "conversation_title": "Reviewed result destination",
    }
    return state("review", **{**defaults, **values})


def save_buttons(view):
    return [b for b in buttons(view) if b["action"] == SAVE_ACTION]


def test_result_without_host_bindings_never_offers_save():
    for value in (state(), state(save=None)):
        view = build_work_view(value)
        assert not save_buttons(view) and "Save" not in render_html(view)


def test_save_button_carries_exactly_the_server_issued_propose_bindings():
    value = state(save=save())
    before = deepcopy(value)
    view = build_work_view(value)
    html = render_html(view)
    assert value == before
    [button] = save_buttons(view)
    assert button["payload"] == {
        "version": 1,
        "command": "propose",
        "operation_id": ID,
        "submission_id": SUBMISSION,
        "publication_id": PUBLICATION,
        "expected_revision": 3,
        "conversation_id": "chat-1",
        "expected_workspace_revision": 0,
        "expected_workspace_publication_id": None,
    }
    assert button["label"] == "Save result" and button["variant"] == "primary"
    assert "conversation_title" not in button["payload"]
    assert "Viewing this result does not save it" in html
    assert "Reviewed result destination" in html
    assert html.index("Exact retained evidence") < html.index("Save result")
    assert {b["action"] for b in buttons(view)} == {"chrome_open", SAVE_ACTION}
    assert "Approve" not in html and "proposal_digest" not in encoded(view)


def test_save_binding_keeps_a_positive_destination_head_exactly():
    value = state(save=save(expected_workspace_revision=7, expected_workspace_publication_id=OTHER,
                            conversation_title=""))
    [button] = save_buttons(build_work_view(value))
    assert button["payload"]["expected_workspace_revision"] == 7
    assert button["payload"]["expected_workspace_publication_id"] == OTHER
    assert "<dd>chat-1</dd>" in render_html(build_work_view(value))


@pytest.mark.parametrize(
    "change",
    [
        {"expected_revision": 4},
        {"expected_revision": True},
        {"submission_id": PUBLICATION},
        {"publication_id": "bad"},
        {"submission_id": SUBMISSION.upper()},
        {"conversation_id": " padded "},
        {"conversation_id": ""},
        {"conversation_id": "x" * 513},
        {"conversation_id": "tab\there"},
        {"conversation_title": {"secret": "SECRET"}},
        {"expected_workspace_revision": 1},
        {"expected_workspace_revision": -1},
        {"expected_workspace_publication_id": PUBLICATION},
        {"expected_workspace_revision": 2, "expected_workspace_publication_id": "bad"},
        {"extra": "SECRET"},
    ],
)
def test_malformed_save_bindings_make_the_whole_result_unavailable(change):
    value = state(save=save(**change))
    view = unavailable(value)
    assert not save_buttons(view) and "SECRET" not in encoded(view)


def test_save_binding_without_a_field_or_on_an_unavailable_result_is_refused():
    value = state(save=save())
    del value["save"]["conversation_title"]
    unavailable(value)
    value = state(save=save())
    value["result"]["result"].update(available=False, reason="not_completed", content=None)
    unavailable(value)
    unavailable(state(save="not-a-binding"))


def test_review_shows_complete_exact_content_destination_expiry_and_bound_approval():
    value = review_state()
    before = deepcopy(value)
    view = build_work_view(value)
    html = render_html(view)
    assert value == before
    assert view.title == "Public page research"
    assert "Nothing is saved until you approve it here" in html
    assert "Exact retained evidence.\nSecond line." in html
    assert "Selected source text, not a summary of the full visual page." in html
    assert "Original source" in html and "https://example.org/page" in html
    assert "https://example.org/start" in html and TIME in html
    assert "Reviewed result destination" in html and EXPIRES in html
    [button] = save_buttons(view)
    assert button["payload"] == {
        "version": 1,
        "command": "save",
        "operation_id": ID,
        "action_id": SUBMISSION,
        "submission_id": APPROVAL,
        "expected_revision": 4,
        "proposal_digest": "c" * 64,
    }
    assert button["label"] == "Save exactly this content"
    navigation = [b["payload"]["params"] for b in buttons(view) if b["action"] == "chrome_open"]
    assert navigation == [{"mode": "result", "operation_id": ID}, {"mode": "list"}]
    assert "Refresh" not in html
    # Digests bind the command only; they are never explanatory copy or forwarded.
    texts = [
        node.get("content") or node.get("value")
        for node in nodes(view.to_dict())
        if "content" in node or "value" in node
    ]
    assert not any(isinstance(item, str) and "c" * 64 in item for item in texts)
    assert "d" * 64 not in encoded(view) and "e" * 64 not in encoded(view)
    assert "columns" not in json.dumps(view.to_dict()["components"])


def test_review_destination_falls_back_to_the_conversation_identity():
    value = review_state()
    del value["conversation_title"]
    assert "<dd>chat-1</dd>" in render_html(build_work_view(value))


@pytest.mark.parametrize(
    "approve,label",
    [
        ({"submission_id": APPROVAL, "expired": True}, "expired before a decision"),
        (None, "not available for a decision"),
    ],
)
def test_expired_or_undecidable_review_keeps_content_but_offers_no_save(approve, label):
    value = review_state(approve=approve)
    if approve is None:
        del value["approve"]
    view = build_work_view(value)
    html = render_html(view)
    assert label in html and "Exact retained evidence" in html and EXPIRES in html
    assert not save_buttons(view)
    assert {b["action"] for b in buttons(view)} == {"chrome_open"}


@pytest.mark.parametrize("mode", ["compact", "standard", "wide", "watch"])
def test_review_and_saveable_result_keep_the_same_components_across_form_factors(mode):
    for value in (review_state(), state(save=save())):
        ordinary = build_work_view(value)
        view = build_work_view(value, layout=LayoutView(mode=mode))
        assert view.to_dict()["components"] == ordinary.to_dict()["components"]


def _review_change(path, change):
    value = review_state()
    target = value
    for key in path:
        target = target[key]
    if callable(change):
        change(target)
    else:
        target.update(change)
    return value


def _text(content, variant="body", **extra):
    return {"type": "text", "content": content, "variant": variant, **extra}


def _kv(items, **extra):
    return {"type": "keyvalue", "title": "S", "items": items, **extra}


@pytest.mark.parametrize(
    "path,change",
    [
        ((), {"review": None}),
        ((), {"conversation_title": {"secret": "SECRET"}}),
        (("review",), {"revision": 3}),
        (("review",), {"revision": True}),
        (("review",), {"status": "saved"}),
        (("review",), {"version": 2}),
        (("review",), {"created": 1}),
        (("review",), {"extra": "SECRET"}),
        (("review",), lambda r: r.pop("component")),
        (("review", "proposal"), {"action_id": PUBLICATION}),
        (("review", "proposal"), {"action_id": "bad"}),
        (("review", "proposal"), {"proposal_digest": "C" * 64}),
        (("review", "proposal"), {"content_digest": "short"}),
        (("review", "proposal"), {"stage_digest": None}),
        (("review", "proposal"), {"conversation_id": " padded "}),
        (("review", "proposal"), {"component_id": "au_work_result_" + OTHER}),
        (("review", "proposal"), {"base_render_revision": 1}),
        (("review", "proposal"), {"base_render_revision": 0, "base_publication_id": PUBLICATION}),
        (("review", "proposal"), {"expires_at": "2026-09-12T12:15:00+01:00"}),
        (("review", "proposal"), {"expires_at": None}),
        (("review", "proposal"), {"extra": "SECRET"}),
        (("review", "component"), {"component_id": "au_work_result_" + OTHER}),
        (("review", "component"), {"component_type": "text"}),
        (("review", "component"), {"title": " "}),
        (("review", "component"), {"title": "Other title"}),
        (("review", "component"), {"position": -1}),
        (("review", "component"), {"extra": "SECRET"}),
        (("review", "component", "payload"), {"variant": "changed"}),
        (("review", "component", "payload"), {"type": "container"}),
        (("review", "component", "payload"), {"content": []}),
        (("review", "component", "payload"), {"content": [{"type": "image", "src": "x"}]}),
        (("review", "component", "payload"), {"content": [_text("x", "h1")]}),
        (("review", "component", "payload"), {"content": [_text("x" * 2049)]}),
        (("review", "component", "payload"), {"content": [_text("\x00")]}),
        (("review", "component", "payload"), {"content": [_text("x", css="SECRET")]}),
        (("review", "component", "payload"), {"content": [_kv([{"label": "a", "value": "b"}], css="SECRET")]}),
        (("review", "component", "payload"), {"content": [_kv([{"label": "a", "value": "b", "extra": 1}])]}),
        (("review", "component", "payload"), {"content": [_kv([])]}),
        (("review", "component", "payload"), {"content": [_kv([{"label": "a", "value": "b"}] * 9)]}),
        (("review", "component", "payload"), {"content": [_kv([{"label": "a", "value": "b"}], columns=0)]}),
        (("review", "component", "payload"), {"content": [_text("x")] * 17}),
        (("review", "component", "payload"), {"content": [_text("x" * 2048)] * 9}),
        (("review", "component", "payload"), {"extra": "SECRET"}),
        (("approve",), {"extra": "SECRET"}),
        (("approve",), {"submission_id": SUBMISSION}),
        (("approve",), {"submission_id": "bad"}),
        (("approve",), {"expired": "yes"}),
    ],
)
def test_malformed_review_never_becomes_a_partial_or_approvable_review(path, change):
    view = unavailable(_review_change(path, change))
    assert not save_buttons(view) and "SECRET" not in encoded(view)


def test_review_private_and_unknown_host_fields_never_escape():
    value = review_state()
    value["private"] = {"token": "SECRET"}
    value["operation"]["private"] = "SECRET"
    value["review"]["component"]["payload"]["content"][0]["content"] = "<script>x()</script>"
    view = build_work_view(value)
    html = render_html(view)
    assert "SECRET" not in encoded(view)
    assert "<script>" not in html and "&lt;script&gt;" in html


def test_review_honours_the_maximum_reviewable_payload_exactly():
    value = review_state()
    content = value["review"]["component"]["payload"]["content"]
    content[0]["content"] = "x" * 2048
    del content[1:]
    content.extend([_text("x" * 2048)] * 6)
    size = len(json.dumps(value["review"]["component"]["payload"], ensure_ascii=False,
                          sort_keys=True, separators=(",", ":")).encode())
    assert size <= 16384
    assert save_buttons(build_work_view(value))
    content.append(_text("x" * 2048))
    unavailable(value)


# ---------------------------------------------------------------------------
# Feature 088 T052 -- charge basis, quoted currency and the measurements view.
# ---------------------------------------------------------------------------


def measurements(**values):
    return {
        "version": 1,
        "logical_attempts": 1,
        "physical_claims": 3,
        "observed_interval_ms": 4200,
        "elapsed_ms": 90000,
        "incomplete": False,
        "cutoff": False,
        **values,
    }


def test_charge_basis_is_disclosed_per_dimension_and_never_implies_a_measured_charge():
    row = operation(
        usage={
            "spent": {"tokens": 120, "spend_micro_units": 30},
            "basis": {"tokens": "observed", "spend_micro_units": "estimated"},
        }
    )
    view = build_work_view(state("detail", operation=row))
    html = render_html(view)
    assert "Charge basis" in html
    assert "Tokens: Observed" in html and "Monetary cost: Estimated" in html
    assert "not measured charges" in html
    assert {b["action"] for b in buttons(view)} == {"chrome_open"}


@pytest.mark.parametrize(
    "token,label,variant",
    [
        ("observed", "Observed", "success"),
        ("estimated", "Estimated", "info"),
        ("uncertain", "Uncertain", "warning"),
        ("none", "Not charged", "default"),
    ],
)
def test_every_basis_token_has_its_own_badge(token, label, variant):
    row = operation(usage={"spent": {"tokens": 5}, "basis": {"tokens": token}})
    view = build_work_view(state("detail", operation=row))
    badges = [
        node
        for node in nodes(view.to_dict())
        if node.get("type") == "badge" and node["label"].startswith("Tokens")
    ]
    assert [(node["label"], node["variant"]) for node in badges] == [
        (f"Tokens: {label}", variant)
    ]


def test_a_not_charged_dimension_is_not_rendered_as_a_zero_amount():
    row = operation(usage={"basis": {"spend_micro_units": "none"}})
    html = render_html(build_work_view(state("detail", operation=row)))
    assert "Monetary cost: Not charged" in html and "not a zero charge" in html
    assert "Usage not recorded" in html and "<dd>0</dd>" not in html


def test_absent_basis_adds_nothing_at_all():
    html = render_html(build_work_view(state("detail", operation=operation())))
    assert "Charge basis" not in html


def test_an_unknown_basis_token_or_shape_makes_the_view_unavailable():
    for basis in ("guessed", "", None, 1, ["observed"]):
        unavailable(state("detail", operation=operation(usage={"basis": {"tokens": basis}})))
    unavailable(state("detail", operation=operation(usage={"basis": ["observed"]})))


def test_a_basis_for_an_unknown_dimension_is_dropped_not_displayed():
    row = operation(usage={"basis": {"future_dimension": "SECRET", "tokens": "observed"}})
    view = build_work_view(state("detail", operation=row))
    assert "SECRET" not in encoded(view) and "Tokens: Observed" in render_html(view)


@pytest.mark.parametrize("bucket", ["spent", "daily", "outstanding"])
def test_a_reported_currency_is_quoted_instead_of_claiming_it_is_unavailable(bucket):
    row = operation(usage={bucket: {"spend_micro_units": 30}, "currency": "USD"})
    html = render_html(build_work_view(state("detail", operation=row)))
    assert "30 micro-units (USD)" in html and "currency unavailable" not in html


def test_an_unknown_amount_stays_unknown_even_when_a_currency_is_reported():
    row = operation(usage={"spent": {"spend_micro_units": None}, "currency": "GBP"})
    html = render_html(build_work_view(state("detail", operation=row)))
    assert "Unknown" in html and "GBP" not in html


@pytest.mark.parametrize("currency", ["usd", "U", "US DOLLAR", "USDOLLARS9", 1, ""])
def test_a_malformed_currency_is_refused_rather_than_quoted(currency):
    unavailable(
        state(
            "detail",
            operation=operation(usage={"spent": {"spend_micro_units": 30}, "currency": currency}),
        )
    )


def test_measurements_distinguish_the_task_from_its_recorded_runs():
    html = render_html(build_work_view(state("detail", measurements=measurements())))
    assert "Attempts (this task)" in html and "<dd>1</dd>" in html
    assert "Runs recorded (claims)" in html and "<dd>3</dd>" in html
    assert "not two different tasks" in html
    assert "<dd>4200</dd>" in html and "<dd>90000</dd>" in html
    assert "also\nincludes waiting" in html or "includes waiting" in html


def test_one_claim_for_one_task_does_not_get_the_multiple_run_explanation():
    html = render_html(
        build_work_view(state("detail", measurements=measurements(physical_claims=1)))
    )
    assert "not two different tasks" not in html


def test_absent_measurements_synthesize_no_attempt_or_timing_at_all():
    html = render_html(build_work_view(state("detail")))
    assert "Timing" not in html and "Attempts" not in html and "Runs recorded" not in html


@pytest.mark.parametrize("field", ["observed_interval_ms", "elapsed_ms"])
def test_an_unrecorded_interval_is_unknown_and_never_zero(field):
    view = build_work_view(state("detail", measurements=measurements(**{field: None})))
    html = render_html(view)
    assert "Unknown" in html and "<dd>0</dd>" not in html
    assert "includes waiting" not in html


def test_zero_recorded_activity_is_shown_as_zero_not_as_unknown():
    view = build_work_view(
        state("detail", measurements=measurements(observed_interval_ms=0, elapsed_ms=0))
    )
    html = render_html(view)
    assert "<dd>0</dd>" in html and "Unknown" not in html


@pytest.mark.parametrize(
    "change,phrase",
    [
        ({"incomplete": True}, "lower bound"),
        ({"cutoff": True}, "Later activity is not included"),
    ],
)
def test_incomplete_and_cutoff_measurements_say_so(change, phrase):
    html = render_html(build_work_view(state("detail", measurements=measurements(**change))))
    assert phrase in html


def test_a_never_claimed_task_reports_zero_runs_without_inventing_one():
    html = render_html(
        build_work_view(
            state(
                "detail",
                measurements=measurements(
                    logical_attempts=0,
                    physical_claims=0,
                    observed_interval_ms=None,
                    elapsed_ms=None,
                ),
            )
        )
    )
    assert "<dd>0</dd>" in html and "Unknown" in html


@pytest.mark.parametrize(
    "change",
    [
        {"version": 2},
        {"logical_attempts": -1},
        {"logical_attempts": True},
        {"physical_claims": None},
        {"observed_interval_ms": -1},
        {"elapsed_ms": "90000"},
        {"incomplete": "no"},
        {"cutoff": 1},
    ],
)
def test_malformed_measurements_make_the_whole_view_unavailable(change):
    unavailable(state("detail", measurements=measurements(**change)))


def test_extra_or_missing_measurement_keys_are_refused():
    extra = measurements()
    extra["owner_id"] = "SECRET"
    view = build_work_view(state("detail", measurements=extra))
    assert "SECRET" not in encoded(view)
    assert "unavailable" in render_html(view).lower()
    missing = measurements()
    del missing["cutoff"]
    unavailable(state("detail", measurements=missing))


def test_measurements_are_a_detail_disclosure_only():
    for mode in ("list", "result"):
        html = render_html(build_work_view(state(mode, measurements=measurements())))
        assert "Runs recorded (claims)" not in html
