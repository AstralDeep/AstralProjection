# App JVM and device coverage

The opt-in `coverage` build type inherits debug configuration and keeps the registered app identity. Only this mode adds AGP device instrumentation and selects Kover's pinned JaCoCo 0.8.14 JVM engine. AGP JVM instrumentation remains disabled, and execution asserts exactly one JVM agent. Normal debug/release dependencies, the ordinary app lock and independent core Kover remain unchanged. Coverage mode uses `app/coverage-gradle.lockfile`; regenerate it only with deliberate review of exact locked coordinates and verification checksums.

From `android-client`, build the immutable inputs with the committed wrapper:

```sh
./gradlew -PastralCoverage=true :app:prepareCoverageInputs :core:koverXmlReport --no-configuration-cache
```

`--no-configuration-cache` is required: `prepareCoverageInputs` reads the AGP coverage report task's resolved class, source and tool inputs at execution time, which a serialized configuration-cache entry cannot carry. The CI lane passes the same flag.

In coverage mode the unit lane deliberately opts out of Gradle's build cache and up-to-date checks (`doNotTrackState` on the `coverage` Test task, `android-client/gradle/coverage.gradle`). Kover 0.9.8 never declares `app/build/kover/bin-reports/testCoverageUnitTest.exec` as a task output, and the `unit-agent.json` receipt that proves exactly one pinned JaCoCo agent ran is written from a `doFirst`. A `FROM-CACHE` or `UP-TO-DATE` unit lane would skip both, so `prepare` would fail closed on the missing receipt (`invalid_json_file`) or the missing probe file (`artifact_missing_or_oversized`) instead of reporting stale coverage. `:app:testCoverageUnitTest` therefore re-executes on every invocation; debug and release Test tasks are untouched.

Use an absolute Projection repository path and a new absolute output directory. The output may be outside Projection when the Deep evidence producer collects it. `JAVA_HOME` must identify the qualified JDK; `adb` must be on PATH or supplied with `--adb`.

```sh
python3 "$PROJECTION/scripts/android_coverage.py" prepare --root "$PROJECTION" --output "$EVIDENCE"
python3 "$PROJECTION/scripts/android_coverage.py" device --root "$PROJECTION" --output "$EVIDENCE" --serial "$TEST_SERIAL" --lane fixtures
python3 "$PROJECTION/scripts/android_coverage.py" report --root "$PROJECTION" --output "$EVIDENCE" --lanes fixtures
```

The explicit device serial must identify an isolated test device. Collection installs the retained app and test APKs, discovers every synthetic instrumentation class, excludes only the separately protected staging producer, and requires every expected test to pass without skips. Each lane is claimed once; failed attempts and their logs remain, and the same output directory cannot silently replay them. Never run this against a user's signed-in device.

Protected release collection adds a `staging` lane before reporting, with the exact same installed APKs. Pass `--arguments-file` pointing to a mode-0600 JSON object containing the existing staging instrumentation arguments; the collector neither creates credentials nor includes their values in receipts. It requires the real `ReleaseEvidenceInstrumentedTest` to pass. Report with `--lanes fixtures,staging`; fixtures alone do not satisfy staging. The platform report's declared APK basename must be validated, then populated from the identical retained `app-coverage.apk` bytes. The receipt binds both installed main and test APK digests.

The collector preserves `unit.exec`, each lane's `.ec`, test log and receipt, both APKs, the original class/source/tool digests, and `report/report.xml`. It checks every original class ID before invoking a detached native AGP JaCoCo report task. The full original class domain includes never-loaded and instructionless classes; no filters or XML rewriting are added. Report inputs are reconstructed and checked before and after reporting, and the report must represent every maintained app Kotlin/Java source. Five empty external inline-source placeholders emitted by JaCoCo are retained verbatim.

Every failure is reported as a closed token and nothing else: the CLI prints `android_coverage_failed <token>` on stderr, and a failed device lane persists the same token as `reason` in `<lane>.failed.json`. A token is either one of this module's own diagnostic codes (for example `invalid_json_file`, `artifact_missing_or_oversized`, `device_tests_not_passed`, `device_transport_failed`, `invalid_lanes`) or, for any other exception, only its Python class name — never a message, path or command line, which could carry a private location or a staging credential.

`report.json` records the exact XML digest and whether protected staging was included. Deep consumes the unchanged XML in its existing `android-app.xml` slot. Keep core Kover in its separate slot. The coverage APK is a test artifact and does not replace the release AAB. Missing, altered, stale or incomplete source/class/APK/probe inputs fail closed.
