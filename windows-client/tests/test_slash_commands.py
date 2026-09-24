"""Tests for astral_client/app.py: the slash-command discovery popup's QCompleter model
— every command listed with its description, prefix filtering, and the clean inserted
command token.
"""

from astral_client.app import build_slash_completer, _SLASH_COMMANDS


def test_completer_lists_all_commands(qapp):
    from PySide6.QtCore import Qt

    comp = build_slash_completer()
    model = comp.model()
    assert model.rowCount() == len(_SLASH_COMMANDS) == 5

    displays = [model.data(model.index(i, 0), Qt.ItemDataRole.DisplayRole) for i in range(model.rowCount())]
    edits = [model.data(model.index(i, 0), Qt.ItemDataRole.EditRole) for i in range(model.rowCount())]

    assert any(d.startswith("/help") and "show available commands" in d for d in displays)
    assert "/summarize " in edits
    assert "/weather " in edits


def test_completer_prefix_filtering(qapp):
    comp = build_slash_completer()

    comp.setCompletionPrefix("/")
    assert comp.completionCount() == 5

    comp.setCompletionPrefix("/sum")
    assert comp.completionCount() == 1
    assert comp.currentCompletion() == "/summarize "

    comp.setCompletionPrefix("hello")
    assert comp.completionCount() == 0
