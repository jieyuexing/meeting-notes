# Meeting Notes Menu agent instructions

## Building and launching

- Always build and launch the app with `./scripts/stable-build.sh` from the repository root.
- Never launch `Meeting Notes.app` directly with `open`, and never run a binary from `.build`.
- Never restore the app after a UI-test run with a direct `open` command. Run `./scripts/stable-build.sh` again so it stops every old instance, rebuilds, verifies the exact executable, and launches one normal instance.
- Before starting a UI-test mode, confirm no real meeting is active. After UI testing, always finish with `./scripts/stable-build.sh`.
- Keep the runnable app at `Meeting Notes.app` in the repository root.
- If the app process is absent while an active meeting pointer exists, use
  `./scripts/stable-build.sh --recover-running-meeting`. This verifies and launches the existing
  canonical signed app without rebuilding or altering recovery state.

## Maintenance routing

- Final transcript text disagrees with a streamed partial, or a rendered CJK seam gains a space:
  run `swift test --disable-automatic-resolution` (final assembly and formatter regressions) and review
  `FORK.md` “Final transcription authority and CJK seams”. The final archive must take its text
  only from FluidAudio's finished result; live partials remain preview-only.
- Diagnose a retained local recording only when explicitly authorized: use the opt-in
  `localRetainedNemotronProbe` test with absolute `MEETING_NOTES_RETAINED_WAV`,
  `MEETING_NOTES_RETAINED_MODEL_DIR`, and `MEETING_NOTES_RETAINED_OUT` values. It returns
  immediately without those values, uses `preloadShared(from:)` rather than a download API, and
  writes every generated report or gain copy under the root task `.local/tmp/` directory.
- SenseVoice final transcript (engine choice, VAD segmentation, tag cleanup, segment-level
  timestamps) or the bilingual `transcript.<code>.md` (language detection, translation alignment,
  archive/retention behavior): run `swift test --disable-automatic-resolution --filter senseVoice`
  and `--filter '[Tt]ranslat'`, plus `PYTHONDONTWRITEBYTECODE=1 python3 Tests/test_transcription_lock.py`
  after touching `FinalTranscriptionEngine`; review `FORK.md` “SenseVoice 最终转写” and
  “转写语言与中外对照逐字稿”. Real-audio and real-backend checks use the opt-in
  `localSenseVoiceFinalProbe` / `liveTranscriptTranslationProbe` tests (variables in `FORK.md`);
  feed them only retained or synthetic material and write outputs under the root task `.local/tmp/`.
- Always-on / MEET-4 capture, lifelog archive, daily digest or experiment tools:
  run `swift test --disable-automatic-resolution -Xswiftc -warnings-as-errors` and
  `PYTHONDONTWRITEBYTECODE=1 python3 Tests/test_transcription_lock.py`; contract:
  `FORK.md` “MEET-4 常开模式”. `LifelogController` never enters MeetingStore,
  remote sync, per-segment summaries or translation. Keep the final-engine local-only
  guard inside the transcription lock. Tests use fake capture, never a real microphone.
  Daily comparison explicitly uses `--filter lifelogDigestProbe` with the four variables
  in FORK.md; do not invoke it on real data unless authorized.
  Experiment operations: root `.local/tmp/lifelog-24h/bin/{sample.py,report.py,digest.sh}`
  → root `.local/tmp/lifelog-24h/RUNBOOK.md`. No launchd load, recording, deployment,
  app restart or defaults changes is implied by a test/build request. For build-only
  verification use `scripts/build-app.sh` in a task-directory APFS clone (it deletes
  the clone's app bundle), never against the running canonical app. Set TMPDIR/TMP/TEMP
  to the root task `.local/tmp/lifelog-24h/tmp`; document platform test-runner temp overrides.

- Unified daily recording, display gate, T3 evidence, Today selection or UI language:
  `swift test --disable-automatic-resolution -Xswiftc -warnings-as-errors`,
  `PYTHONDONTWRITEBYTECODE=1 python3 Tests/test_transcription_lock.py`, and
  `PYTHONDONTWRITEBYTECODE=1 python3 Tests/test_ui_localization.py`
  → `FORK.md` “统一日常记录、Today 与完整 UI 本地化”. For these tests set
  `MEETING_NOTES_TEST_TMPDIR`, `TMPDIR`, `TMP`, `TEMP` to the root task directory;
  SwiftPM's test runner may override TMPDIR, so the explicit test variable is required.
  Keep the primary start/stop independent of meeting title. Unified media closes
  before ASR; both WAVs use the existing local-only final-engine lock. Screen files
  have a separate subroot and a capacity pause; screen text (below) owns deletion. T3 polls
  local `t3ctl m3max observe` without an agent/model loop and fails independently.
  Selection outputs live under `selections/<id>/`, reference final transcripts,
  and use only the configured daily-digest command; no second ASR or cloud fallback.
  User confirmed requests/final replies plus title/status, and all awake displays.
  `UILanguage` affects chrome only; preserve body text, model/command/protocol values.
  Build with `scripts/build-app.sh` only in a frozen task APFS clone. Then supply
  `MEETING_NOTES_LOCALIZATION_APP=/absolute/clone/Meeting Notes.app` to the Python
  localization test to exercise Foundation Bundle lookup; do not launch the app.
  Integration evidence: root `.local/tmp/lifelog-unified-capture/INTEGRATE-RECORD.md`.
  No deployment or restart during the 2026-10-08/09 24-hour experiment.

- Screen text / video deletion (MEET-5: keyframe dedupe, Vision OCR, `screen-text.*`,
  `segment.json` `screenText`/`screenDeletedAt`, Today screen-text row, digest/selection
  `[screen N]` evidence limits): strict Swift suite above (`--filter 'ScreenText|screenText|
  Unified|[Dd]igest|[Ss]election'` for a focused pass) and the localization test
  → `FORK.md` “画面转文字后删除视频（MEET-5）”. Audio-side saves must use
  `saveKeepingScreen`; screen-side writes only `LifelogStore.update(in:)`. Legacy segments
  without `screenText` are never processed by launch recovery. Real Vision check is the
  opt-in `screenTextVisionProbe` (`MEETING_NOTES_SCREEN_OCR_VIDEO`, `MEETING_NOTES_SCREEN_OCR_OUT`);
  feed only synthetic video, outputs under the root task `.local/tmp/`; evidence and
  probe generator: root `.local/tmp/lifelog-screen-ocr/RECORD.md`. Never record a real screen
  or upload frames/text for this check.
- MEET-4 read/write failures or root switching (R1–R3): run the strict Swift suite
  above and `PYTHONDONTWRITEBYTECODE=1 python3 Tests/test_transcription_lock.py`
  → `FORK.md` “MEET-4 常开模式”, root task `FIXES.md`. Never treat a read/repair
  error as silence; lifelog final-engine reads must remain throwing under the lock.
  Preserve first-write-error async notification outside the audio lock and stale-URL
  rejection. Root changes require stopped capture and drained current/inflight/queued/
  failed work; same-root aliases must not enqueue active audio.
- Missing-process metrics (R4): from the Universe root run
  `python3 -I .local/tmp/lifelog-24h/bin/verify-report.py`
  → `.local/tmp/lifelog-24h/RUNBOOK.md` and `FIXES.md`. This mocks ps/power and
  reads only synthetic fixtures. No-PID CPU/RSS are missing, including old CSV zeros;
  keep disk statistics independent. Never run live sample.py as a fixture check.
