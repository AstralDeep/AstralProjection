"""Small protocol-neutral component constructors and a safe web renderer."""

from __future__ import annotations

import json
import re
from collections.abc import Iterable, Mapping, Sequence
from html import escape

from astralprojection.models import ChromeViewModel, ComponentView, LayoutView, ThemeView

_ACTION_RE = re.compile(r"^[a-z][a-z0-9_.:-]*$")
_FIELD_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.:-]*$")
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_FIELD_KINDS = frozenset(
    {"text", "password", "textarea", "number", "boolean", "select", "checklist"}
)


def clean_text(value: object) -> str:
    """Keep display text intact while removing unsafe control characters."""
    return "" if value is None else _CONTROL_RE.sub("", str(value))


def _action(value: object) -> str:
    action = str(value or "").strip()
    if not _ACTION_RE.fullmatch(action):
        raise ValueError("action must be a lowercase protocol token")
    return action


def _field_name(value: object) -> str:
    name = str(value or "").strip()
    if not _FIELD_NAME_RE.fullmatch(name):
        raise ValueError("field name must be a portable protocol identifier")
    return name


def text(content: object, variant: str = "body") -> ComponentView:
    return ComponentView("text", {"content": clean_text(content), "variant": variant})


def alert(message: object, variant: str = "info", title: object | None = None) -> ComponentView:
    props: dict[str, object] = {"message": clean_text(message), "variant": variant}
    if title is not None:
        props["title"] = clean_text(title)
    return ComponentView("alert", props)


def badge(label: object, variant: str = "default") -> ComponentView:
    return ComponentView("badge", {"label": clean_text(label), "variant": variant})


def button(
    label: object,
    action: str,
    payload: Mapping[str, object] | None = None,
    *,
    variant: str = "secondary",
    disabled: bool = False,
    local: bool = False,
) -> ComponentView:
    return ComponentView(
        "button",
        {
            "label": clean_text(label),
            "action": _action(action),
            "payload": dict(payload or {}),
            "variant": variant,
            "disabled": bool(disabled),
            "local": bool(local),
        },
    )


def card(
    title: object,
    content: Iterable[ComponentView],
    *,
    variant: str = "default",
) -> ComponentView:
    return ComponentView(
        "card",
        {
            "title": clean_text(title),
            "content": [item.to_dict() for item in content],
            "variant": variant,
        },
    )


def container(
    children: Iterable[ComponentView],
    *,
    direction: str = "column",
) -> ComponentView:
    return ComponentView(
        "container",
        {"children": [item.to_dict() for item in children], "direction": direction},
    )


def key_value(
    items: Iterable[tuple[object, object]],
    *,
    title: object | None = None,
) -> ComponentView:
    props: dict[str, object] = {
        "items": [
            {"label": clean_text(label), "value": clean_text(value)} for label, value in items
        ]
    }
    if title is not None:
        props["title"] = clean_text(title)
    return ComponentView("keyvalue", props)


def bullet_list(items: Iterable[object], *, ordered: bool = False) -> ComponentView:
    return ComponentView(
        "list",
        {"items": [clean_text(item) for item in items], "ordered": bool(ordered)},
    )


def field(
    name: str,
    label: object,
    kind: str = "text",
    *,
    default: object | None = None,
    options: Sequence[object] | None = None,
    help_text: object | None = None,
    visible_when: Mapping[str, object] | None = None,
) -> dict[str, object]:
    field_name = _field_name(name)
    normalized_kind = str(kind or "").strip().lower()
    if normalized_kind not in _FIELD_KINDS:
        raise ValueError(f"unsupported form field kind: {normalized_kind}")
    result: dict[str, object] = {
        "name": field_name,
        "label": clean_text(label),
        "kind": normalized_kind,
    }
    if default is not None and normalized_kind != "password":
        result["default"] = default
    if options is not None:
        result["options"] = [clean_text(item) for item in options]
    if help_text is not None:
        result["help"] = clean_text(help_text)
    if visible_when is not None:
        result["visible_when"] = dict(visible_when)
    return result


def form(
    fields: Iterable[Mapping[str, object]],
    *,
    title: object = "",
    description: object = "",
    submit_action: str | None = None,
    submit_label: object = "Save",
    submit_payload: Mapping[str, object] | None = None,
    actions: Iterable[Mapping[str, object]] | None = None,
) -> ComponentView:
    props: dict[str, object] = {
        "title": clean_text(title),
        "description": clean_text(description),
        "fields": [dict(item) for item in fields],
        "submit_label": clean_text(submit_label),
    }
    if submit_action is not None:
        props["submit_action"] = _action(submit_action)
        props["submit_payload"] = dict(submit_payload or {})
    if actions is not None:
        normalized: list[dict[str, object]] = []
        for item in actions:
            entry = dict(item)
            entry["action"] = _action(entry.get("action"))
            entry["label"] = clean_text(entry.get("label"))
            entry["payload"] = dict(entry.get("payload") or {})
            normalized.append(entry)
        props["actions"] = normalized
    return ComponentView("param_picker", props)


def build_view(
    surface: str,
    title: str,
    components: Iterable[ComponentView],
    *,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    return ChromeViewModel(
        surface,
        title,
        tuple(components),
        theme or ThemeView(),
        layout or LayoutView(),
    )


def denied_view(surface: str, title: str, message: object) -> ChromeViewModel:
    return build_view(surface, title, [alert(message, "error", "Access denied")])


def unavailable_view(surface: str, title: str, message: object) -> ChromeViewModel:
    return build_view(surface, title, [alert(message, "error", "Unavailable")])


def _json_attr(value: object) -> str:
    return escape(json.dumps(value, sort_keys=True, separators=(",", ":")), quote=True)


def _render_text(component: Mapping[str, object]) -> str:
    variant = str(component.get("variant") or "body")
    tag = {"h1": "h1", "h2": "h2", "h3": "h3", "caption": "small"}.get(variant, "p")
    return f'<{tag} data-text-variant="{escape(variant)}">{escape(clean_text(component.get("content")))}</{tag}>'


def _render_alert(component: Mapping[str, object]) -> str:
    variant = str(component.get("variant") or "info")
    role = "alert" if variant in {"error", "warning"} else "status"
    title = clean_text(component.get("title"))
    heading = f"<strong>{escape(title)}</strong> " if title else ""
    return (
        f'<div role="{role}" aria-live="polite" data-alert-variant="{escape(variant)}">'
        f"{heading}{escape(clean_text(component.get('message')))}</div>"
    )


def _render_button(component: Mapping[str, object], *, collect: bool = False) -> str:
    action = _action(component.get("action"))
    payload = component.get("payload") or {}
    disabled = ' disabled aria-disabled="true"' if component.get("disabled") else ""
    collect_attr = ' data-ui-collect="true"' if collect else ""
    return (
        f'<button type="button" data-ui-action="{escape(action)}" '
        f'data-ui-payload="{_json_attr(payload)}"{collect_attr}{disabled}>'
        f"{escape(clean_text(component.get('label')))}</button>"
    )


def _render_fields(component: Mapping[str, object]) -> str:
    rendered: list[str] = []
    fields = component.get("fields") or []
    for raw in fields if isinstance(fields, (list, tuple)) else []:
        if not isinstance(raw, Mapping):
            continue
        name = _field_name(raw.get("name"))
        label = escape(clean_text(raw.get("label")))
        kind = str(raw.get("kind") or "text")
        default = clean_text(raw.get("default"))
        help_text = clean_text(raw.get("help"))
        help_id = f"field-{name}-help"
        described = f' aria-describedby="{help_id}"' if help_text else ""
        if kind == "textarea":
            control = f'<textarea name="{escape(name)}"{described}>{escape(default)}</textarea>'
        elif kind == "boolean":
            checked = " checked" if raw.get("default") else ""
            control = f'<input type="checkbox" name="{escape(name)}"{checked}{described}>'
        elif kind in {"select", "checklist"}:
            options = raw.get("options") or []
            multiple = " multiple" if kind == "checklist" else ""
            option_html = "".join(
                f'<option value="{escape(clean_text(option))}"'
                f"{' selected' if clean_text(option) == default else ''}>"
                f"{escape(clean_text(option))}</option>"
                for option in options
                if not isinstance(option, Mapping)
            )
            control = f'<select name="{escape(name)}"{multiple}{described}>{option_html}</select>'
        else:
            input_type = kind if kind in {"password", "number"} else "text"
            value = "" if input_type == "password" else f' value="{escape(default, quote=True)}"'
            control = f'<input type="{input_type}" name="{escape(name)}"{value}{described}>'
        help_html = f'<small id="{help_id}">{escape(help_text)}</small>' if help_text else ""
        rendered.append(f"<label>{label}{control}</label>{help_html}")
    return "".join(rendered)


def _render_form(component: Mapping[str, object]) -> str:
    title = clean_text(component.get("title"))
    description = clean_text(component.get("description"))
    parts = ['<div data-ui-form="true" role="form">']
    if title:
        parts.append(f"<h3>{escape(title)}</h3>")
    if description:
        parts.append(f"<p>{escape(description)}</p>")
    parts.append(_render_fields(component))
    raw_actions = component.get("actions") or []
    if isinstance(raw_actions, (list, tuple)) and raw_actions:
        for item in raw_actions:
            if isinstance(item, Mapping):
                parts.append(_render_button(item, collect=True))
    elif component.get("submit_action"):
        parts.append(
            _render_button(
                {
                    "label": component.get("submit_label") or "Save",
                    "action": component.get("submit_action"),
                    "payload": component.get("submit_payload") or {},
                },
                collect=True,
            )
        )
    parts.append("</div>")
    return "".join(parts)


def _render_component(component: Mapping[str, object]) -> str:
    component_type = str(component.get("type") or "")
    if component_type == "text":
        return _render_text(component)
    if component_type == "alert":
        return _render_alert(component)
    if component_type == "badge":
        return (
            f'<span role="status" data-badge-variant="{escape(clean_text(component.get("variant")))}">'
            f"{escape(clean_text(component.get('label')))}</span>"
        )
    if component_type == "button":
        return _render_button(component)
    if component_type in {"card", "container"}:
        child_key = "content" if component_type == "card" else "children"
        raw_children = component.get(child_key) or []
        children = "".join(
            _render_component(item) for item in raw_children if isinstance(item, Mapping)
        )
        if component_type == "card":
            title = clean_text(component.get("title"))
            return (
                f'<section aria-label="{escape(title, quote=True)}"><h3>{escape(title)}</h3>'
                f"{children}</section>"
            )
        return f'<div role="group" data-direction="{escape(clean_text(component.get("direction")))}">{children}</div>'
    if component_type == "keyvalue":
        rows = []
        raw_items = component.get("items") or []
        for item in raw_items if isinstance(raw_items, (list, tuple)) else []:
            if isinstance(item, Mapping):
                rows.append(
                    f"<div><dt>{escape(clean_text(item.get('label')))}</dt>"
                    f"<dd>{escape(clean_text(item.get('value')))}</dd></div>"
                )
        title = clean_text(component.get("title"))
        heading = f"<h3>{escape(title)}</h3>" if title else ""
        return f"<section>{heading}<dl>{''.join(rows)}</dl></section>"
    if component_type == "list":
        tag = "ol" if component.get("ordered") else "ul"
        raw_items = component.get("items") or []
        items = "".join(
            f"<li>{escape(clean_text(item))}</li>"
            for item in raw_items
            if not isinstance(item, Mapping)
        )
        return f"<{tag}>{items}</{tag}>"
    if component_type == "param_picker":
        return _render_form(component)
    return _render_alert(
        {
            "variant": "info",
            "title": "Limited presentation",
            "message": (
                f"The {component_type or 'unknown'} component is not available in this renderer."
            ),
        }
    )


def render_html(view: ChromeViewModel) -> str:
    """Render a safe, accessible web representation of a chrome view model."""
    title_id = f"chrome-{view.surface}-title"
    degradation = ""
    if view.degradation.active:
        degradation = _render_alert(
            {
                "variant": "info",
                "title": "Adapted presentation",
                "message": view.degradation.reason,
            }
        )
    body = "".join(_render_component(component.to_dict()) for component in view.components)
    return (
        f'<section data-chrome-surface="{escape(view.surface)}" '
        f'data-theme="{escape(view.theme.name)}" data-layout="{escape(view.layout.mode)}" '
        f'aria-labelledby="{title_id}"><h2 id="{title_id}">{escape(view.title)}</h2>'
        f"{degradation}{body}</section>"
    )
