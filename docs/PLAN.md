# Door Listener plan

A macOS app that records calls, meetings, videos, lectures and voice notes,
then transcribes them on-device. Turkish and English, often mixed in one recording.

## Step 1: Record both sides
- Start/Stop in the window and the menu bar, so recording can be left running.
- Microphone (AVAudioEngine) and system audio (Core Audio process tap) saved as
  two separate tracks: `mic.m4a` and `system.m4a`.
- Sessions saved in `~/Library/Application Support/Door Listener/Recordings/<date>/`.

## Step 2: Transcribe on-device after stopping
- Engine picker: Apple Speech (SpeechAnalyzer) or Whisper (WhisperKit, large-v3-turbo).
- Whisper is the recommended default for mixed Turkish and English.
- Each track transcribed separately, merged by timestamp.
- Runs automatically when a recording stops; "Transcribe Again" re-runs it.
- Speaker bleed filter (see Step 3) is applied in the merge.

## Step 3: Speaker labels and transcript viewer
- Mic track is always "Me".
- System track split into Speaker 1, 2, 3... with on-device diarization (FluidAudio).
- Mic bleed: without headphones the mic also picks up what the speakers play.
  Drop mic segments that overlap in time and match text from the system track,
  so "Me" only gets lines the user actually said.
- Open a session, read the transcript, copy or export as text/Markdown.
- End of MVP.

## Step 4 (after MVP): Summaries via OpenRouter
- API key in Settings (Keychain), model picker, "Summarize" button.
