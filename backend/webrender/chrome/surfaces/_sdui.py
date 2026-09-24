"""Astralprims component-dict builders (text, card, button, form, etc.) that let a
settings surface render identically through the native SDUI path and the web
renderer, sharing the same chrome_* action keys.
"""

from typing import Any, Dict, List, Optional

from astralprims import (
    Alert,
    Badge,
    Button,
    Card,
    Container,
    KeyValue,
    List_,
    ParamPicker,
    Tabs,
    Text,
)


def text(content: str, variant: str = "body") -> Dict[str, Any]:
    return Text(content=content, variant=variant).to_dict()


def card(title: str, content: List[Dict[str, Any]], variant: str = "default") -> Dict[str, Any]:
    return Card(title=title, content=list(content), variant=variant).to_dict()


def container(children: List[Dict[str, Any]], direction: Optional[str] = None) -> Dict[str, Any]:
    return Container(children=list(children), direction=direction).to_dict()


def button(label: str, action: str, payload: Optional[Dict[str, Any]] = None,
           variant: str = "secondary") -> Dict[str, Any]:
    return Button(label=label, action=action, payload=payload or {}, variant=variant).to_dict()


def badge(label: str, variant: str = "default") -> Dict[str, Any]:
    return Badge(label=label, variant=variant).to_dict()


def alert(message: str, kind: str = "info", title: Optional[str] = None) -> Dict[str, Any]:
    variant = kind if kind in ("info", "success", "warning", "error") else "info"
    return Alert(message=message, variant=variant, title=title).to_dict()


def key_value(items: List[Dict[str, Any]], title: Optional[str] = None,
              columns: int = 2) -> Dict[str, Any]:
    return KeyValue(items=list(items), title=title, columns=columns).to_dict()


def bullet_list(items: List[Any], ordered: bool = False) -> Dict[str, Any]:
    return List_(items=list(items), ordered=ordered).to_dict()


def tabs(tab_items: List[Dict[str, Any]]) -> Dict[str, Any]:
    return Tabs(tabs=list(tab_items)).to_dict()


def field(name: str, label: str, kind: str = "text", default: Any = None,
          options: Optional[List[Any]] = None, help: Optional[str] = None,
          step: Optional[float] = None,
          visible_when: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    f: Dict[str, Any] = {"name": name, "label": label, "kind": kind}
    if default is not None:
        f["default"] = default
    if options is not None:
        f["options"] = options
    if help is not None:
        f["help"] = help
    if step is not None:
        f["step"] = step
    if visible_when is not None:
        f["visible_when"] = visible_when
    return f


def form(fields: List[Dict[str, Any]], submit_action: Optional[str] = None,
         submit_label: str = "Save", submit_payload: Optional[Dict[str, Any]] = None,
         actions: Optional[List[Dict[str, Any]]] = None, title: str = "",
         description: str = "") -> Dict[str, Any]:
    attrs: Dict[str, Any] = {}
    if actions:
        attrs["actions"] = [dict(a) for a in actions]
    if submit_action:
        attrs["submit_action"] = submit_action
        attrs["submit_payload"] = submit_payload or {}
    return ParamPicker(
        title=title,
        description=description,
        fields=list(fields),
        submit_label=submit_label,
        attributes=attrs,
    ).to_dict()


def placeholder(label: str) -> Dict[str, Any]:
    return Alert(
        message=f"“{label}” isn't available in this app yet.",
        variant="info",
    ).to_dict()
