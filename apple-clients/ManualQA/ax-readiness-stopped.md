# Unqualified accessibility readiness proposal

Saved at the owner's stopping request. This branch adds explicit foreground/key-window preparation to the existing native test fixtures; it does not replace the public AX lookup or its missing, ambiguous and foreign-window checks.

The earlier lookup-time preparation experiment failed two cases and was replaced by the current async-settle/mount proposal. The current proposal was not executed before stopping. Do not call it fixed or use it to waive the 18 accessibility-dependent failures from the full Mac gate.

Reproduction and failed diagnostic logs remain local at `/tmp/spec105-native-ax-publication-green.log` and `/tmp/spec105-native-ax-diagnostic-run.log`. The minimal Cocoa probes under `/tmp/spec105-ax-probe` found that both an active app and a key window were needed to publish its own AX window; this lead does not itself qualify the application fixture.

Resume with the two unchanged accessibility boundary tests and all affected native classes before a full Mac gate. The main feature branch separately preserves the unfinished consent-presentation repair and its handoff.
