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
