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
