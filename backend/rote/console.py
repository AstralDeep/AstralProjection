"""Derives the negotiated console layout from logical device dimensions.
DeviceProfile serializes these server-owned values for native web-console parity.
"""

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from rote.capabilities import DeviceCapabilities


CONSOLE_CONTRACT = "console/v2"


def presentation(capabilities: "DeviceCapabilities", *, watch: bool = False) -> dict:
    width = capabilities.viewport_width or capabilities.screen_width or 1920
    height = capabilities.viewport_height or capabilities.screen_height or 1080
    phone = width < 768
    drawer = width < 1024
    sidebar = min(320, round(width * 0.86, 2)) if drawer else 288 if width < 1280 else 350
    if watch:
        sidebar = 0
        content_padding = composer_padding = (8, 8, 8, 8)
        columns = 1
    elif phone:
        content_padding = (24, 16, 16, 16)
        composer_padding = (8, 8, 8, 8)
        columns = 1
    elif drawer:
        content_padding = (24, 20, 20, 20)
        composer_padding = (12, 20, 12, 20)
        columns = 2
    elif width < 1280:
        content_padding = (24, 24, 24, 24)
        composer_padding = (14, 24, 14, 24)
        columns = 2
    else:
        content_padding = (32, 48, 32, 48)
        composer_padding = (18, 48, 18, 48)
        columns = max(1, int((width - sidebar - 96 + 14) // 364))
    edges = ("top", "right", "bottom", "left")
    return {
        "version": 2,
        "navigation_mode": "stack" if watch else "drawer" if drawer else "sidebar",
        "sidebar_width": sidebar,
        "content_padding": dict(zip(edges, content_padding)),
        "composer_padding": dict(zip(edges, composer_padding)),
        "scenario_columns": columns,
        "settings_presentation": "push" if watch else "sheet" if phone else "dialog",
        "settings_navigation_axis": "horizontal" if phone and not watch else "vertical",
        "settings_width": width if phone or watch else min(940, width - 48),
        "dialog_width": width if phone or watch else min(640, width - 48),
        "settings_max_height": height if phone or watch else round(min(height * 0.86, 860), 2),
        "settings_navigation_width": 0 if phone or watch else 216,
        "result_preview_max_height": 440,
        "result_body_max_height": 380,
        "fullscreen_inset": 0,
        "minimum_control_height": 44 if watch or drawer or capabilities.has_touch else 0,
    }


def watch_availability(surface, params, profile, client_capabilities=()) -> dict:
    handoff = {"mode": "handoff", "message": "Continue on your phone or desktop."}
    supported = getattr(profile, "supported_types", None)
    if (getattr(profile, "console_contract", None) != CONSOLE_CONTRACT
            or not supported or not profile.supports_interactivity or profile.max_actions):
        return handoff
    capabilities = (set(item for item in client_capabilities if isinstance(item, str))
                    if isinstance(client_capabilities, (list, tuple, set, frozenset)) else set())
    required_types = {"text", "alert", "badge", "card", "button"}
    if surface == "guidance":
        required = ("guidance_selection_v1" if isinstance(params, dict)
                    and params.get("view") == "selection" else "guidance_notes_v1")
    elif surface == "work":
        required = "work_read_v1"
        required_types.add("keyvalue")
    elif surface == "agent_intro":
        required = None
        required_types = {"text", "card", "container", "button"}
    else:
        return handoff
    return ({"mode": "native"} if required_types <= supported
            and (required is None or required in capabilities) else handoff)
