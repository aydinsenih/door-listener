# Door Listener plan

A macOS app that records calls, meetings, videos, lectures and voice notes,
then transcribes them on-device. Turkish and English, often mixed in one recording.

## Step 1: Record both sides
- Start/Stop in the window and the menu bar, so recording can be left running.
- Microphone (AVAudioEngine) and system audio (Core Audio process tap) saved as
  two separate tracks: `mic.m4a` and `system.m4a`.
- Sessions saved in `~/Library/Application Support/Door Listener/Recordings/<date>/`.

## Step 2: Transcribe on-device, live while recording
- Engine picker in Settings:
  - Whisper (WhisperKit, large-v3-turbo) with voice detection: the default for mixed
    Turkish and English. A line appears after each pause.
  - Qwen3-ASR 0.6B or 1.7B (speech-swift, MLX) with the same voice detection. Detects
    the language per sentence. No word timings, so each sentence is one line.
  - Apple Speech (SpeechAnalyzer): one language per recording.
- Each track goes through Silero VAD v5 (bundled ONNX model, run with ONNX Runtime)
  as it is captured. Silence never reaches the speech model, which saves CPU and
  stops Whisper from inventing phrases in quiet parts.
- An utterance ends after a 0.5 s pause (0.2 s once it is over 12 s long) and is cut
  at its quietest point if it reaches 20 s. Each one is transcribed right away, so
  lines show up in the open session while recording.
- The speech model sits behind `SpeechEngine` / `SpeechStream`, so another model
  can be dropped in. A streaming model is fed each utterance's audio as it's heard
  and finishes the utterance at the pause.
- Each track transcribed separately, merged by timestamp. The transcript is saved
  as it grows.
- "Transcribe Again" runs the same VAD over the saved files. If live transcription
  fails, the saved audio is transcribed after stopping instead.
- Speaker bleed filter (see Step 3) is applied in the merge.

## Step 3: Speaker labels and transcript viewer
- Mic track is always "Me".
- System track split into Speaker 1, 2, 3... with on-device diarization
  (SpeakerKit, Pyannote, from the same package as WhisperKit). It runs once over the
  whole system track after recording stops; until then lines read "Others". Speakers are numbered
  in the order they first talk. Whisper word timings split a segment where the
  speaker changes. If diarization fails, the system track falls back to "Others".
- Mic bleed: without headphones the mic also picks up what the speakers play.
  Drop mic segments that overlap in time and match text from the system track,
  so "Me" only gets lines the user actually said.
- Open a session, read the transcript, copy or export as text/Markdown.
  Back-to-back lines from the same speaker are joined into one turn.
- End of MVP.

## Step 4 (after MVP): Summaries via OpenRouter
- API key in Settings (Keychain), model picker, "Summarize" button.
