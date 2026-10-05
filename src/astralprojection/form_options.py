"""Normalizes existing string and labeled form choices for shared web rendering.
Saved values missing from a refreshed catalog remain selectable without changing their wire value.
"""

from collections.abc import Mapping


def form_options(options, defaults=()):
    result = []
    seen = set()
    for item in options if isinstance(options, (list, tuple)) else ():
        value = item.get("value") if isinstance(item, Mapping) else item
        if not isinstance(value, str) or value in seen:
            continue
        label = item.get("label") if isinstance(item, Mapping) else value
        result.append((value, label if isinstance(label, str) and label else value))
        seen.add(value)
    for value in defaults:
        if isinstance(value, str) and value and value not in seen:
            result.append((value, value))
            seen.add(value)
    return result
