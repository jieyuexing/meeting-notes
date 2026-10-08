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
