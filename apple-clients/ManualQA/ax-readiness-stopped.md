# Native accessibility readiness

The surface fixtures now order each test window front, make it key and ask the app to activate before reading its public accessibility tree. The lookup still fails on a missing, ambiguous or foreign window.

## What the qualification found

The 21 accessibility failures seen in one full Mac run on the feature line did not reproduce. A second full run of the same source passed every one of them, and they also pass alone. Their trigger was outside the code. That run started right after another test host hung on a Desktop folder privacy prompt.

Running surfaces in a focused window exposed a real defect. The computer Stop control lost its error color and took the accent color once its window was key in an active app. It now keeps the error tint in both states.

Text recognition read "Bypass on" with a Cyrillic first letter. The fixture handed Vision a transparent bitmap. The same image composited onto an opaque background reads correctly, and a language setting made no difference. Surface text is now read from the view drawn over its window background, and the failing assertions report the text they read.

The session controls Stop button also takes the accent color in a focused window. No test asserts its color and it is not changed here.

## Limits

Activation is cooperative. When another app holds focus, the fixture window stays inactive and the run covers the inactive state only. The settle step still waits a fixed time. It does not observe accessibility publication.

Two consent presentation tests fail in every full run, with and without this change. They belong to the consent presentation repair.
