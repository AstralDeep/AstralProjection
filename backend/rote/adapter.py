"""Stateless recursive component-tree adapter: degrades types down the capability
fallback ladder, enforces host action limits, and resolves level-of-detail for a
DeviceProfile; called by ROTE.adapt and orchestrator/ui_designer.py.
"""

from typing import AbstractSet, Any, Dict, List, Optional

from rote import fallback, lod
from rote.capabilities import DeviceProfile, DeviceType
from rote.console import CONSOLE_CONTRACT


_WEB_PROFILES = frozenset({DeviceType.BROWSER, DeviceType.TABLET, DeviceType.MOBILE})

_WEB_089_TYPES = frozenset({
    "action_group", "stat_group", "gauge", "pipeline_stepper",
    "donut_chart", "radar_chart",
})


class ComponentAdapter:
    @staticmethod
    def adapt_guidance_surface(state: Dict, profile: DeviceProfile, *, surface_capabilities=()) -> List[Dict]:
        import json
        from astralprojection.chrome.guidance import build_guidance_view, build_notes_view

        builder = build_guidance_view if profile.console_contract == CONSOLE_CONTRACT else build_notes_view
        components = [item.to_dict() for item in builder(state).components]
        supported = profile.supported_types
        if (profile.device_type == DeviceType.WATCH and profile.console_contract == CONSOLE_CONTRACT
                and isinstance(surface_capabilities, (list, tuple))
                and "guidance_notes_v1" in surface_capabilities and supported is not None):
            supported = supported | {"param_picker"}
        actions = 0
        count = 0

        def visit(node, depth=0):
            nonlocal actions, count
            count += 1
            kind = node["type"]
            if (count > 1024 or depth > 8
                    or kind not in {"text", "alert", "badge", "card", "button", "param_picker"}
                    or (supported is not None and kind not in supported)):
                raise ValueError("guidance_surface_unavailable")
            if kind == "button":
                actions += 1
            elif kind == "param_picker":
                actions += len(node.get("actions") or []) or int(bool(node.get("submit_action")))
            elif kind == "card":
                for child in node["content"]:
                    visit(child, depth + 1)

        for component in components:
            visit(component)
        limit = getattr(profile, "max_actions", 0) or 0
        if ((actions and not profile.supports_interactivity) or (limit > 0 and actions > limit)
                or len(json.dumps(components, ensure_ascii=False).encode("utf-8")) > 1024 * 1024):
            raise ValueError("guidance_surface_unavailable")
        return components

    @classmethod
    def adapt_work_surface(cls, components: List[Dict], profile: DeviceProfile) -> List[Dict]:
        from rote.work import validate_work_components

        validated = validate_work_components(components, profile.supported_types)
        return cls._enforce_host_limits(validated, profile)

    @staticmethod
    def adapt_voice_capability(profile: DeviceProfile) -> Dict[str, object]:
        return fallback.local_voice_disposition(profile.capabilities)

    @classmethod
    def adapt(cls, components: List[Dict], profile: DeviceProfile) -> List[Dict]:
        if lod.lod_enabled():
            try:
                device = cls._lod_device(profile)
                components = [cls._apply_lod(c, device) for c in components]
            except Exception:
                # Fail-open: a bad LOD entry must not break adaptation
                pass

        # Must run before per-component adapt or types get dropped
        components = [cls._degrade_089_for_non_web(c, profile) for c in components]

        result = []
        for comp in components:
            adapted = cls._adapt_component(comp, profile)
            if adapted is not None:
                result.append(adapted)
        supported = getattr(profile, "supported_types", None)
        if supported:
            result = [cls._degrade_unsupported(c, supported) for c in result]
        return cls._enforce_host_limits(result, profile)

    _089_TYPES = frozenset({
        "action_group",
        "stat_group",
        "gauge",
        "pipeline_stepper",
        "donut_chart",
        "radar_chart",
    })

    _089_WEB_DEVICES = frozenset({"browser", "tablet", "mobile"})

    @staticmethod
    def _supports_console_type(ctype: str, profile: DeviceProfile) -> bool:
        return (
            profile.console_contract == CONSOLE_CONTRACT
            and ctype in (profile.supported_types or ())
            and (ctype not in {"donut_chart", "radar_chart"} or profile.supports_charts)
        )

    @classmethod
    def _degrade_089_for_non_web(cls, comp: Dict, profile: DeviceProfile) -> Dict:
        if not isinstance(comp, dict):
            return comp
        device = getattr(getattr(profile, "device_type", None), "value", None)
        if device in cls._089_WEB_DEVICES:
            return comp
        return cls._degrade_089_tree(comp, profile)

    @classmethod
    def _degrade_089_tree(cls, comp: Dict, profile: DeviceProfile) -> Dict:
        if not isinstance(comp, dict):
            return comp
        ctype = str(comp.get("type", "")).strip().lower()
        if ctype in cls._089_TYPES and not cls._supports_console_type(ctype, profile):
            legacy = cls._legacy_supported_types(profile)
            return cls._degrade_unsupported(comp, legacy)
        out = dict(comp)
        for key in ("content", "children", "actions", "overflow_actions", "buttons"):
            kids = comp.get(key)
            if isinstance(kids, list):
                out[key] = [
                    cls._degrade_089_tree(c, profile) if isinstance(c, dict) else c
                    for c in kids
                ]
        tabs = comp.get("tabs")
        if isinstance(tabs, list):
            out["tabs"] = [
                (
                    {
                        **tab,
                        "content": [
                            cls._degrade_089_tree(c, profile)
                            if isinstance(c, dict)
                            else c
                            for c in tab["content"]
                        ],
                    }
                    if isinstance(tab, dict) and isinstance(tab.get("content"), list)
                    else tab
                )
                for tab in tabs
            ]
        return out

    _089_CANDIDATE_RUNGS = (
        "text", "container", "card", "grid", "list", "metric", "progress",
        "timeline", "keyvalue", "badge", "alert", "hero", "button", "table",
        "bar_chart", "line_chart", "pie_chart",
    )

    @classmethod
    def _legacy_supported_types(cls, profile: DeviceProfile) -> AbstractSet[str]:
        cache = getattr(cls, "_089_rung_cache", None)
        if cache is None:
            cache = cls._089_rung_cache = {}
        key = (
            getattr(getattr(profile, "device_type", None), "value", None),
            getattr(profile, "supports_charts", True),
            getattr(profile, "supports_tables", True),
            getattr(profile, "supports_tabs", True),
            getattr(profile, "supports_code", True),
            getattr(profile, "supports_interactivity", True),
            getattr(profile, "max_grid_columns", 0),
        )
        cached = cache.get(key)
        if cached is not None:
            return cached

        probes = {
            "text": {"type": "text", "content": "probe"},
            "container": {"type": "container", "children": []},
            "card": {"type": "card", "title": "probe", "content": []},
            "grid": {"type": "grid", "columns": 2, "children": []},
            "list": {"type": "list", "items": ["probe"]},
            "metric": {"type": "metric", "title": "probe", "value": "1"},
            "progress": {"type": "progress", "value": 0.5, "label": "probe"},
            "timeline": {"type": "timeline", "items": [{"title": "probe"}]},
            "keyvalue": {"type": "keyvalue",
                         "items": [{"label": "k", "value": "v"}]},
            "badge": {"type": "badge", "label": "probe"},
            "alert": {"type": "alert", "message": "probe"},
            "hero": {"type": "hero", "title": "probe"},
            "button": {"type": "button", "label": "probe", "action": "probe"},
            "table": {"type": "table", "headers": ["a"], "rows": [["1"]]},
            "bar_chart": {"type": "bar_chart", "labels": ["a"],
                          "datasets": [{"label": "s", "data": [1]}]},
            "line_chart": {"type": "line_chart", "labels": ["a"],
                           "datasets": [{"label": "s", "data": [1]}]},
            "pie_chart": {"type": "pie_chart", "labels": ["a"], "data": [1]},
        }
        supported = set()
        for name in cls._089_CANDIDATE_RUNGS:
            probe = probes.get(name)
            if probe is None:
                continue
            try:
                result = cls._adapt_component(dict(probe), profile)
            except Exception:
                result = None
            if isinstance(result, dict) and str(result.get("type", "")).lower() == name:
                supported.add(name)
        supported.add("text")
        supported -= cls._089_TYPES
        cache[key] = frozenset(supported)
        return cache[key]


    @classmethod
    def _carry_identity(cls, src: Dict, out: Dict) -> Dict:
        for key in ("id", "component_id", "provenance"):
            if comp_val := src.get(key):
                out.setdefault(key, comp_val)
        identity = src.get("component_id", src.get("id"))
        role = src.get("data-welcome")
        if (isinstance(role, str)
                and role in {"intro", "permission", "examples", "example", "more"}
                and (identity is None
                     or isinstance(identity, str) and identity.startswith("wel_"))):
            out.setdefault("data-welcome", role)
        return out

    @classmethod
    def _degrade_unsupported(cls, comp: Dict, supported) -> Dict:
        if not isinstance(comp, dict):
            return comp
        ctype = str(comp.get("type", "")).strip().lower()
        target = fallback.first_supported(ctype, supported)
        if target == ctype:
            return cls._degrade_children(comp, supported)
        converted = cls._degrade_089(comp, ctype, target, supported)
        if converted is not None:
            return cls._carry_identity(comp, converted)
        if target == "text":
            return cls._carry_identity(comp, {
                "type": "text",
                "content": cls._extract_text(comp) or str(comp.get("title") or ""),
                "variant": "body"})
        if target == "list":
            return cls._carry_identity(comp, cls._to_list(comp))
        if target == "table":
            return cls._carry_identity(comp, cls._to_table(comp, supported))
        if target in ("container", "card"):
            wrapped = {"type": target,
                       "content": (comp.get("content") or comp.get("children")
                                   or comp.get("buttons") or [])}
            if comp.get("title") or comp.get("label"):
                wrapped["title"] = comp.get("title") or comp.get("label")
            return cls._carry_identity(comp, cls._degrade_children(wrapped, supported))
        return cls._carry_identity(
            comp, {"type": "text", "content": cls._extract_text(comp) or "", "variant": "body"})

    _STEP_VARIANT = {
        "done": "success",
        "active": "info",
        "pending": "default",
        "error": "error",
    }

    @classmethod
    def _degrade_089(cls, comp: Dict, ctype: str, target: str, supported):
        if ctype == "gauge" and target == "progress":
            out: Dict[str, Any] = {
                "type": "progress",
                "value": comp.get("value", 0.0),
                "show_percentage": not comp.get("display_value"),
            }
            label = comp.get("label")
            display = comp.get("display_value")
            if label or display:
                out["label"] = (
                    f"{label}: {display}" if label and display else (label or display)
                )
            return out

        if ctype == "gauge" and target == "metric":
            return {
                "type": "metric",
                "title": comp.get("label") or "",
                "value": comp.get("display_value")
                or f"{round(float(comp.get('value') or 0.0) * 100)}%",
                "subtitle": comp.get("subtitle"),
                "progress": comp.get("value"),
            }

        if ctype == "stat_group" and target in ("grid", "keyvalue"):
            items = [i for i in (comp.get("items") or []) if isinstance(i, dict)]
            if target == "keyvalue":
                return {
                    "type": "keyvalue",
                    "title": comp.get("title"),
                    "items": [
                        {
                            "label": str(i.get("label") or ""),
                            "value": str(i.get("value") or ""),
                            "hint": i.get("hint") or i.get("delta"),
                        }
                        for i in items
                    ],
                }
            return cls._degrade_children(
                {
                    "type": "grid",
                    "title": comp.get("title"),
                    "columns": comp.get("columns", 4),
                    "children": [
                        {
                            "type": "metric",
                            "title": str(i.get("label") or ""),
                            "value": str(i.get("value") or ""),
                            "subtitle": i.get("hint") or i.get("delta"),
                            "variant": i.get("variant") or "default",
                        }
                        for i in items
                    ],
                },
                supported,
            )

        if ctype == "pipeline_stepper" and target == "timeline":
            steps = [s for s in (comp.get("steps") or []) if isinstance(s, dict)]
            return {
                "type": "timeline",
                "title": comp.get("title"),
                "items": [
                    {
                        "title": str(s.get("label") or ""),
                        "description": s.get("detail"),
                        "variant": cls._STEP_VARIANT.get(
                            str(s.get("status") or "").lower(), "default"
                        ),
                    }
                    for s in steps
                ],
            }

        if ctype == "donut_chart" and target == "pie_chart":
            return {
                "type": "pie_chart",
                "title": comp.get("title", ""),
                "labels": list(comp.get("labels") or []),
                "data": list(comp.get("data") or []),
            }

        if ctype == "radar_chart" and target == "table":
            axes = [str(a) for a in (comp.get("axes") or [])]
            datasets = [d for d in (comp.get("datasets") or []) if isinstance(d, dict)]
            rows = []
            for dataset in datasets:
                values = list(dataset.get("data") or [])
                rows.append(
                    [str(dataset.get("label") or "")]
                    + [
                        str(values[i]) if i < len(values) else ""
                        for i in range(len(axes))
                    ]
                )
            return {
                "type": "table",
                "title": comp.get("title"),
                "headers": [""] + axes,
                "rows": rows,
            }

        if ctype in ("donut_chart", "radar_chart", "stat_group") and target == "list":
            return cls._to_list_089(comp, ctype)

        if target == "text" and ctype in (
            "gauge",
            "stat_group",
            "pipeline_stepper",
            "donut_chart",
            "radar_chart",
            "action_group",
        ):
            return {
                "type": "text",
                "content": cls._summarize_089(comp, ctype),
                "variant": "body",
            }

        return None

    @classmethod
    def _summarize_089(cls, comp: Dict, ctype: str) -> str:
        title = str(comp.get("title") or comp.get("label") or "").strip()
        if ctype == "gauge":
            reading = comp.get("display_value") or (
                f"{round(float(comp.get('value') or 0.0) * 100)}%"
            )
            return f"{title}: {reading}".strip(": ")
        if ctype == "stat_group":
            parts = [
                f"{i.get('label', '')} {i.get('value', '')}".strip()
                for i in (comp.get("items") or [])
                if isinstance(i, dict)
            ]
            return "; ".join(p for p in ([title] if title else []) + parts if p)
        if ctype == "pipeline_stepper":
            parts = [
                f"{s.get('label', '')} ({s.get('status', 'pending')})".strip()
                for s in (comp.get("steps") or [])
                if isinstance(s, dict)
            ]
            return "; ".join(p for p in ([title] if title else []) + parts if p)
        if ctype == "donut_chart":
            labels = [str(x) for x in (comp.get("labels") or [])]
            values = list(comp.get("data") or [])
            parts = [
                f"{labels[i] if i < len(labels) else f'series {i + 1}'} {values[i]}"
                for i in range(len(values))
            ]
            return "; ".join(p for p in ([title] if title else []) + parts if p)
        if ctype == "radar_chart":
            axes = [str(a) for a in (comp.get("axes") or [])]
            parts = []
            for dataset in comp.get("datasets") or []:
                if not isinstance(dataset, dict):
                    continue
                values = list(dataset.get("data") or [])
                pairs = ", ".join(
                    f"{axes[i]} {values[i]}" for i in range(min(len(axes), len(values)))
                )
                parts.append(f"{dataset.get('label') or ''} {pairs}".strip())
            return "; ".join(p for p in ([title] if title else []) + parts if p)
        labels = [
            str(b.get("label") or "")
            for b in (comp.get("buttons") or [])
            if isinstance(b, dict)
        ]
        return "; ".join(p for p in ([title] if title else []) + labels if p)

    @classmethod
    def _to_list_089(cls, comp: Dict, ctype: str) -> Dict:
        items = []
        if ctype == "donut_chart":
            labels = [str(x) for x in (comp.get("labels") or [])]
            for index, value in enumerate(comp.get("data") or []):
                label = labels[index] if index < len(labels) else f"series {index + 1}"
                items.append(f"{label}: {value}")
        elif ctype == "radar_chart":
            axes = [str(a) for a in (comp.get("axes") or [])]
            for dataset in comp.get("datasets") or []:
                if not isinstance(dataset, dict):
                    continue
                values = list(dataset.get("data") or [])
                pairs = ", ".join(
                    f"{axes[i]} {values[i]}"
                    for i in range(min(len(axes), len(values)))
                )
                items.append(f"{dataset.get('label') or ''}: {pairs}".strip(": "))
        else:
            for item in comp.get("items") or []:
                if isinstance(item, dict):
                    items.append(
                        f"{item.get('label', '')}: {item.get('value', '')}".strip(": ")
                    )
        out: Dict[str, Any] = {"type": "list", "ordered": False, "items": items}
        if comp.get("title"):
            out["title"] = comp["title"]
        return out

    @classmethod
    def _degrade_children(cls, comp: Dict, supported) -> Dict:
        out = dict(comp)
        for key in ("content", "children", "actions", "overflow_actions", "buttons"):
            kids = comp.get(key)
            if isinstance(kids, list):
                out[key] = [cls._degrade_unsupported(c, supported)
                            for c in kids if isinstance(c, dict)]
        tabs = comp.get("tabs")
        if isinstance(tabs, list):
            out["tabs"] = [
                ({**t, "content": [cls._degrade_unsupported(c, supported)
                                   for c in t["content"] if isinstance(c, dict)]}
                 if isinstance(t, dict) and isinstance(t.get("content"), list) else t)
                for t in tabs
            ]
        return out

    @classmethod
    def _to_list(cls, comp: Dict) -> Dict:
        ctype = str(comp.get("type", "")).strip().lower()
        items: List[str] = []
        if ctype == "timeline":
            for it in (comp.get("items") or []):
                if isinstance(it, dict):
                    parts = [str(it[k]) for k in ("time", "title", "description") if it.get(k)]
                    if parts:
                        items.append(" — ".join(parts))
        elif ctype == "table":
            headers = comp.get("headers") or []
            for row in (comp.get("rows") or []):
                if isinstance(row, list):
                    cells = [f"{headers[i]}: {c}" if i < len(headers) else str(c)
                             for i, c in enumerate(row)]
                    items.append(" | ".join(cells))
        elif ctype == "keyvalue":
            for it in (comp.get("items") or []):
                if isinstance(it, dict):
                    items.append(f"{it.get('label', '')}: {it.get('value', '')}".strip(": "))
        if not items:
            t = cls._extract_text(comp)
            if t:
                items = [t]
        out: Dict[str, Any] = {"type": "list", "ordered": False, "items": items}
        if comp.get("title"):
            out["title"] = comp["title"]
        return out

    @classmethod
    def _to_table(cls, comp: Dict, supported) -> Dict:
        ctype = str(comp.get("type", "")).strip().lower()
        if ctype == "plotly_chart" and isinstance(comp.get("data"), list):
            rows = []
            for index, trace in enumerate(comp["data"]):
                if not isinstance(trace, dict):
                    continue
                values = trace.get("y", trace.get("values"))
                labels = trace.get("x", trace.get("labels", []))
                if not isinstance(values, list) or not isinstance(labels, list):
                    continue
                name = trace.get("name") or f"Series {index + 1}"
                rows.extend([name, labels[i] if i < len(labels) else i + 1, value]
                            for i, value in enumerate(values))
            if rows:
                return {"type": "table", "title": comp.get("title") or "Chart data",
                        "headers": ["Series", "Label", "Value"], "rows": rows}
        if ctype == "keyvalue":
            rows = [[it.get("label", ""), it.get("value", "")]
                    for it in (comp.get("items") or []) if isinstance(it, dict)]
            out: Dict[str, Any] = {"type": "table", "headers": ["", ""], "rows": rows}
            if comp.get("title"):
                out["title"] = comp["title"]
            return out
        data = comp.get("data") if isinstance(comp.get("data"), dict) else comp
        labels = data.get("labels")
        series = data.get("series") or data.get("datasets")
        if isinstance(labels, list) and isinstance(series, list) and series:
            names = [s.get("name") or s.get("label") or f"series {i}" if isinstance(s, dict)
                     else f"series {i}" for i, s in enumerate(series)]
            rows = []
            for ri, lab in enumerate(labels):
                row = [lab]
                for s in series:
                    vals = s.get("data") if isinstance(s, dict) else s
                    row.append(vals[ri] if isinstance(vals, list) and ri < len(vals) else "")
                rows.append(row)
            out = {"type": "table", "headers": ["label", *names], "rows": rows}
            if comp.get("title"):
                out["title"] = comp["title"]
            return out
        if "list" in supported:
            return cls._to_list(comp)
        return {"type": "text", "content": cls._extract_text(comp) or "", "variant": "body"}

    # Security bound: caps a compromised agent's action budget
    @classmethod
    def _enforce_host_limits(cls, components: List[Dict], profile: DeviceProfile) -> List[Dict]:
        read_only = not getattr(profile, "supports_interactivity", True)
        max_actions = getattr(profile, "max_actions", 0) or 0
        if not read_only and max_actions <= 0:
            return components
        budget = [max_actions if max_actions > 0 else None]

        def walk(node):
            if not isinstance(node, dict):
                return node
            if node.get("type") == "button" and node.get("action"):
                if read_only:
                    return None
                if budget[0] is not None:
                    if budget[0] <= 0:
                        return None
                    budget[0] -= 1
                return node
            out = dict(node)
            for key in ("children", "content", "actions", "overflow_actions", "buttons"):
                if isinstance(out.get(key), list):
                    out[key] = [w for w in (walk(c) for c in out[key]) if w is not None]
            if isinstance(out.get("tabs"), list):
                new_tabs = []
                for tab in out["tabs"]:
                    if isinstance(tab, dict) and isinstance(tab.get("content"), list):
                        tab = {**tab, "content": [w for w in (walk(c) for c in tab["content"]) if w is not None]}
                    new_tabs.append(tab)
                out["tabs"] = new_tabs
            return out

        return [w for w in (walk(c) for c in components) if w is not None]

    _LOD_CONTENT_KEY = "content"

    @classmethod
    def _lod_device(cls, profile: DeviceProfile) -> Dict[str, Any]:
        dt = profile.device_type.value if profile.device_type else "browser"
        is_small = profile.device_type in (DeviceType.WATCH, DeviceType.MOBILE)
        return {"device_type": dt, "is_small": is_small}

    @classmethod
    def _apply_lod(cls, comp: Any, device: Dict[str, Any]) -> Any:
        if not isinstance(comp, dict):
            return comp
        out = dict(comp)
        if isinstance(out.get("lod"), dict):
            resolved = lod.pick_content(out, device)
            out.pop("lod", None)
            if resolved != "" and not isinstance(out.get(cls._LOD_CONTENT_KEY), list):
                out[cls._LOD_CONTENT_KEY] = resolved
        for key in ("content", "children"):
            kids = out.get(key)
            if isinstance(kids, list):
                out[key] = [cls._apply_lod(c, device) for c in kids]
        tabs = out.get("tabs")
        if isinstance(tabs, list):
            new_tabs = []
            for tab in tabs:
                if isinstance(tab, dict) and isinstance(tab.get("content"), list):
                    tab = {**tab, "content": [cls._apply_lod(c, device) for c in tab["content"]]}
                new_tabs.append(tab)
            out["tabs"] = new_tabs
        return out

    @classmethod
    def _adapt_component(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        result = cls._adapt_component_typed(comp, profile)
        if isinstance(result, dict) and result is not comp and isinstance(comp, dict):
            cls._carry_identity(comp, result)
        return result

    @classmethod
    def _adapt_component_typed(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        if not isinstance(comp, dict):
            return comp

        comp_type = comp.get("type", "")

        if profile.device_type == DeviceType.VOICE:
            text = cls._extract_text(comp)
            if text:
                return {"type": "text", "content": text[:profile.max_text_chars] if profile.max_text_chars else text, "variant": "body"}
            return None

        if comp_type in ("bar_chart", "line_chart", "pie_chart", "plotly_chart"):
            return cls._adapt_chart(comp, profile)

        if comp_type in _WEB_089_TYPES:
            return cls._adapt_089_web(comp, profile)

        if comp_type == "table":
            return cls._adapt_table(comp, profile)

        if comp_type == "grid":
            return cls._adapt_grid(comp, profile)

        if comp_type == "collapsible":
            return cls._adapt_collapsible(comp, profile)

        if comp_type == "tabs":
            return cls._adapt_tabs(comp, profile)

        if comp_type == "code":
            return cls._adapt_code(comp, profile)

        if comp_type in ("file_upload", "file_download"):
            return cls._adapt_file_io(comp, profile)

        if comp_type == "text":
            return cls._adapt_text(comp, profile)

        if comp_type == "button":
            return cls._adapt_button(comp, profile)

        if comp_type == "skeleton":
            return cls._adapt_skeleton(comp, profile)

        if comp_type == "chat_history":
            return cls._adapt_chat_history(comp, profile)

        if comp_type == "download_card":
            return cls._adapt_download_card(comp, profile)

        if comp_type in ("container", "card"):
            return cls._adapt_container(comp, profile)

        return comp

    @classmethod
    def _adapt_089_web(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        comp_type = comp.get("type", "")
        if (profile.device_type not in _WEB_PROFILES
                and not cls._supports_console_type(comp_type, profile)):
            return comp
        width = profile.capabilities.viewport_width or (
            profile.capabilities.screen_width if profile.console_contract == CONSOLE_CONTRACT else 0
        )

        if comp_type == "stat_group":
            columns = comp.get("columns")
            cap = max(1, int(profile.max_grid_columns or 1))
            try:
                current = int(columns)
            except (TypeError, ValueError):
                return comp
            if current <= cap:
                return comp
            return {**comp, "columns": cap}

        if comp_type == "gauge":
            if 0 < width < 480 and comp.get("variant") != "compact":
                return {**comp, "variant": "compact"}
            return comp

        if comp_type in ("donut_chart", "radar_chart"):
            if 0 < width < 700:
                return cls._089_as_table(comp)
            return comp

        if comp_type == "pipeline_stepper":
            if 0 < width < 768 and comp.get("orientation") != "vertical":
                return {**comp, "orientation": "vertical"}
            return comp

        if comp_type == "action_group":
            actions = comp.get("actions")
            if not isinstance(actions, list):
                return comp
            updated = dict(comp)
            if (profile.device_type == DeviceType.MOBILE
                    or profile.console_contract == CONSOLE_CONTRACT and width <= 480):
                updated["wrap"] = True
            if len(actions) > 3:
                updated["actions"] = list(actions[:2])
                updated["overflow_actions"] = list(actions[2:])
            return updated if updated != comp else comp

        return comp

    @staticmethod
    def _089_as_table(comp: Dict) -> Dict:
        identity = {k: comp[k] for k in ("id", "component_id") if k in comp}
        title = comp.get("title", "")
        if comp.get("type") == "donut_chart":
            rows = []
            for segment in comp.get("segments", []) or []:
                if not isinstance(segment, dict):
                    continue
                rows.append([str(segment.get("label", "")), segment.get("value", "")])
            return {"type": "table", "title": title,
                    "columns": ["Segment", "Value"], "rows": rows, **identity}
        axes = [str(axis) for axis in (comp.get("axes") or [])]
        rows = []
        for dataset in comp.get("datasets", []) or []:
            if not isinstance(dataset, dict):
                continue
            values = list(dataset.get("data") or [])
            values += [""] * (len(axes) - len(values))
            rows.append([str(dataset.get("label", ""))] + values[:len(axes)])
        return {"type": "table", "title": title,
                "columns": [""] + axes, "rows": rows, **identity}

    @classmethod
    def _adapt_chart(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        if profile.supports_charts:
            if (comp.get("type") == "plotly_chart"
                    and 0 < profile.capabilities.viewport_width < 700):
                raw = comp.get("layout")
                layout = dict(raw) if isinstance(raw, dict) else {}
                layout.pop("width", None)
                layout.update(autosize=True, height=260)
                layout["margin"] = {"l": 44, "r": 12, "t": 32, "b": 60}
                for axis in ("xaxis", "yaxis"):
                    current = layout.get(axis)
                    layout[axis] = {**(current if isinstance(current, dict) else {}),
                                    "automargin": True}
                return {**comp, "layout": layout}
            return comp

        comp.get("type", "chart")
        title = comp.get("title", "Result")

        value = cls._extract_chart_value(comp)
        return {
            "type": "metric",
            "title": title,
            "value": str(value),
            "subtitle": f"(chart condensed for {profile.device_type.value})",
        }

    @classmethod
    def _extract_chart_value(cls, comp: Dict) -> Any:
        comp_type = comp.get("type", "")
        if comp_type == "pie_chart":
            data = comp.get("data", [])
            labels = comp.get("labels", [])
            if data:
                idx = data.index(max(data))
                label = labels[idx] if idx < len(labels) else "value"
                return f"{label}: {data[idx]}"
        datasets = comp.get("datasets", [])
        if datasets:
            first = datasets[0]
            data = first.get("data", [])
            label = first.get("label", "")
            if data:
                return f"{label}: {data[0]}" if label else data[0]
        plotly_data = comp.get("data", [])
        if plotly_data and isinstance(plotly_data, list):
            first = plotly_data[0]
            y = first.get("y", []) if isinstance(first, dict) else []
            if y:
                return y[0]
        return "N/A"

    @classmethod
    def _adapt_table(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        if not profile.supports_tables:
            headers = comp.get("headers", [])
            rows = comp.get("rows", [])
            max_rows = profile.max_table_rows or len(rows)
            max_cols = profile.max_table_cols or len(headers)
            trimmed = rows[:max_rows]
            items = []
            for row in trimmed:
                parts = []
                for i, cell in enumerate(row[:max_cols]):
                    if i < len(headers):
                        parts.append(f"{headers[i]}: {cell}")
                    else:
                        parts.append(str(cell))
                items.append(" | ".join(parts))
            degraded = {"type": "list", "items": items, "ordered": False}
            if comp.get("title"):
                degraded["title"] = comp["title"]
            return degraded

        headers = comp.get("headers", [])
        rows = comp.get("rows", [])

        if profile.max_table_cols and len(headers) > profile.max_table_cols:
            headers = headers[: profile.max_table_cols]
            rows = [r[: profile.max_table_cols] for r in rows]

        if profile.max_table_rows and len(rows) > profile.max_table_rows:
            rows = rows[: profile.max_table_rows]

        result = {**comp, "headers": headers, "rows": rows}
        return result

    @classmethod
    def _adapt_grid(cls, comp: Dict, profile: DeviceProfile) -> Dict:
        columns = comp.get("columns", 2)
        capped = min(columns, profile.max_grid_columns)
        children = comp.get("children", [])
        adapted_children = [
            c for c in (cls._adapt_component(ch, profile) for ch in children) if c is not None
        ]
        if capped <= 1:
            return cls._carry_identity(comp, {"type": "container", "children": adapted_children})
        return {**comp, "columns": capped, "children": adapted_children}

    @classmethod
    def _adapt_collapsible(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        if not profile.supports_tabs:
            content = comp.get("content", [])
            adapted = [
                c for c in (cls._adapt_component(ch, profile) for ch in content) if c is not None
            ]
            return {
                "type": "card",
                "title": comp.get("title", ""),
                "content": adapted,
            }
        content = comp.get("content", [])
        adapted = [
            c for c in (cls._adapt_component(ch, profile) for ch in content) if c is not None
        ]
        return {**comp, "content": adapted}

    @classmethod
    def _adapt_tabs(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        if not profile.supports_tabs:
            tabs = comp.get("tabs", [])
            if not tabs:
                return None
            first = tabs[0]
            content = first.get("content", [])
            adapted = [
                c for c in (cls._adapt_component(ch, profile) for ch in content) if c is not None
            ]
            return {
                "type": "card",
                "title": first.get("label", ""),
                "content": adapted,
            }
        tabs = comp.get("tabs", [])
        adapted_tabs = []
        for tab in tabs:
            tab_content = tab.get("content", [])
            adapted_content = [
                c for c in (cls._adapt_component(ch, profile) for ch in tab_content) if c is not None
            ]
            adapted_tabs.append({**tab, "content": adapted_content})
        return {**comp, "tabs": adapted_tabs}

    @classmethod
    def _adapt_code(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        if not profile.supports_code:
            return None
        return comp

    @classmethod
    def _adapt_file_io(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        if not profile.supports_file_io:
            return None
        return comp

    @classmethod
    def _adapt_text(cls, comp: Dict, profile: DeviceProfile) -> Dict:
        if not profile.max_text_chars:
            return comp
        content = comp.get("content", "")
        if len(content) > profile.max_text_chars:
            content = content[: profile.max_text_chars - 1] + "…"
        return {**comp, "content": content}

    @classmethod
    def _adapt_button(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        if profile.device_type in (DeviceType.TV, DeviceType.VOICE):
            return None
        if profile.device_type == DeviceType.WATCH:
            if comp.get("variant", "primary") != "primary":
                identity = comp.get("component_id", comp.get("id"))
                payload = comp.get("payload")
                message = payload.get("message") if isinstance(payload, dict) else None
                if not (comp.get("data-welcome") == "example"
                        and (identity is None or isinstance(identity, str)
                             and identity.startswith("wel_"))
                        and comp.get("action") == "chat_message"
                        and isinstance(message, str) and message.strip()):
                    return None
        return comp

    @classmethod
    def _adapt_skeleton(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        try:
            count = int(comp.get("count", 4))
        except (TypeError, ValueError):
            count = 4
        caps = {DeviceType.WATCH: 3, DeviceType.MOBILE: 5}
        cap = caps.get(profile.device_type)
        if cap is not None and count > cap:
            return {**comp, "count": cap}
        return comp

    @classmethod
    def _adapt_chat_history(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        items = [i for i in (comp.get("items") or []) if isinstance(i, dict)]
        caps = {DeviceType.WATCH: 4, DeviceType.MOBILE: 10}
        cap = caps.get(profile.device_type)
        if cap is None:
            return comp
        trimmed = items[:cap]
        if profile.device_type == DeviceType.WATCH:
            trimmed = [{k: v for k, v in it.items() if k != "preview"} for it in trimmed]
        return {**comp, "items": trimmed}

    @classmethod
    def _adapt_download_card(cls, comp: Dict, profile: DeviceProfile) -> Optional[Dict]:
        if profile.device_type == DeviceType.MOBILE:
            trimmed = {k: v for k, v in comp.items()
                       if k not in ("description", "sha256", "sigstore_bundle_url")}
            return trimmed
        if profile.device_type == DeviceType.WATCH:
            version = comp.get("version") or ""
            url = comp.get("download_url") or comp.get("html_url") or ""
            label = f"Download Astral desktop v{version}" if version else "Download Astral desktop"
            return {"type": "button", "label": label, "url": url} if url else {
                "type": "text", "content": label, "variant": "body"}
        return comp

    @classmethod
    def _adapt_container(cls, comp: Dict, profile: DeviceProfile) -> Dict:
        if comp.get("type") == "card":
            content = comp.get("content", [])
            adapted = [
                c for c in (cls._adapt_component(ch, profile) for ch in content) if c is not None
            ]
            return {**comp, "content": adapted}
        children = comp.get("children", [])
        adapted = [
            c for c in (cls._adapt_component(ch, profile) for ch in children) if c is not None
        ]
        return {**comp, "children": adapted}

    @classmethod
    def _extract_text(cls, comp: Dict) -> str:
        parts: List[str] = []
        comp_type = comp.get("type", "")

        if comp_type == "text":
            parts.append(comp.get("content", ""))

        elif comp_type == "metric":
            title = comp.get("title", "")
            value = comp.get("value", "")
            subtitle = comp.get("subtitle", "")
            parts.append(f"{title}: {value}" + (f" ({subtitle})" if subtitle else ""))

        elif comp_type == "alert":
            title = comp.get("title", "")
            msg = comp.get("message", "")
            parts.append(f"{title}: {msg}" if title else msg)

        elif comp_type == "image":
            alt = comp.get("alt") or comp.get("caption") or comp.get("title") or ""
            parts.append(f"Image: {alt}" if alt else "An image (view it on another device)")

        elif comp_type == "table":
            headers = comp.get("headers", [])
            rows = comp.get("rows", [])
            if headers:
                parts.append(", ".join(str(h) for h in headers))
            for row in rows:
                parts.append(", ".join(str(c) for c in row))

        elif comp_type in ("bar_chart", "line_chart", "pie_chart", "plotly_chart"):
            title = comp.get("title", "chart")
            value = cls._extract_chart_value(comp)
            parts.append(f"{title}: {value}")

        elif comp_type == "list":
            items = comp.get("items", [])
            for item in items:
                if isinstance(item, str):
                    parts.append(item)
                elif isinstance(item, dict):
                    parts.append(cls._extract_text(item))

        elif comp_type == "code":
            lang = comp.get("language", "")
            parts.append(f"[Code block: {lang}]")

        elif comp_type in ("card", "collapsible"):
            if comp.get("title"):
                parts.append(str(comp["title"]))

        elif comp_type == "badge":
            parts.append(comp.get("label", ""))

        elif comp_type == "download_card":
            title = comp.get("title") or "Astral desktop app"
            version = comp.get("version") or ""
            ver = f", version {version}" if version else ""
            parts.append(
                f"{title}{ver}. Download it from GitHub. Integrity is verified "
                "with a SHA-256 hash and a sigstore signature.")

        elif comp_type == "hero":
            for key in ("eyebrow", "title", "subtitle"):
                if comp.get(key):
                    parts.append(str(comp[key]))
            badges = [b for b in comp.get("badges", []) if isinstance(b, str)]
            if badges:
                parts.append(", ".join(badges))

        elif comp_type == "keyvalue":
            if comp.get("title"):
                parts.append(str(comp["title"]))
            for item in comp.get("items", []):
                if isinstance(item, dict):
                    parts.append(f"{item.get('label', '')}: {item.get('value', '')}")

        elif comp_type == "timeline":
            if comp.get("title"):
                parts.append(str(comp["title"]))
            for item in comp.get("items", []):
                if isinstance(item, dict):
                    entry = str(item.get("title", ""))
                    if item.get("time"):
                        entry = f"{item['time']} — {entry}"
                    if item.get("description"):
                        entry = f"{entry}: {item['description']}"
                    parts.append(entry)

        elif comp_type == "rating":
            label = comp.get("label", "rating")
            value = comp.get("value", 0)
            max_value = comp.get("max_value", 5)
            parts.append(f"{label}: {value} out of {max_value} stars")

        elif comp_type == "chat_history":
            parts.append(str(comp.get("title") or "Recent chats"))
            titles = [str(it.get("title")).strip()
                      for it in (comp.get("items") or [])
                      if isinstance(it, dict) and it.get("title")]
            if titles:
                parts.append(": " + "; ".join(titles))
            else:
                parts.append(": no conversations yet")

        elif comp_type == "skeleton":
            parts.append(str(comp.get("label") or "Loading"))

        elif comp_type == "button":
            parts.append(comp.get("label", ""))

        for key in ("children", "content"):
            for child in comp.get(key, []):
                if isinstance(child, dict):
                    t = cls._extract_text(child)
                    if t:
                        parts.append(t)

        for tab in comp.get("tabs", []):
            if isinstance(tab, dict):
                label = tab.get("label", "")
                if label:
                    parts.append(label)
                for child in tab.get("content", []):
                    if isinstance(child, dict):
                        t = cls._extract_text(child)
                        if t:
                            parts.append(t)

        return " ".join(p.strip() for p in parts if p.strip())
