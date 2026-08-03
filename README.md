# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
# Stop a previously installed daemon before replacing its signed executable.
launchctl bootout "gui/$(id -u)/com.digimata.quill" 2>/dev/null || true
sudo install -m 755 .build/release/quill /usr/local/bin/quill.new
sudo mv -f /usr/local/bin/quill.new /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

For hands-free Zoom recording, enable `auto_record.zoom` in the config below.
quill watches Zoom's Core Audio activity: opening Zoom alone does nothing;
joining computer audio starts a recording, and leaving the call stops it.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system gives a reliable first split — `me` vs the remote side.
Optional speaker diarization can then split the system track into
`participant_1`, `participant_2`, and so on. CAF on purpose: unlike m4a, it
needs no finalization pass — if the process dies mid-meeting, everything
already written is still readable.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v3**
via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port —
roughly 20 seconds per hour of audio on Apple Silicon. v3 is the multilingual
model (25 European languages plus Japanese) and detects the spoken language on
its own, so there's nothing to configure for a non-English meeting.

Set `transcription.model` to `"v2"` for the English-only model, which has
marginally higher recall on English. Models (~600 MB) download once on first
transcription; `quill doctor` tells you whether they're already cached so
you're never downloading after an important meeting.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

### Whisper

Set `transcription.engine` to `"whisper"` for **Whisper large-v3-turbo** via
[WhisperKit](https://github.com/argmaxinc/WhisperKit) — the accuracy option.
It's ~1 GB and roughly 20x slower than parakeet (about six minutes for a
one-hour meeting, against twenty seconds), and it's meaningfully better on
non-English speech and technical vocabulary. Weights download once into
`~/Library/Application Support/quill/models`.

Whisper needs a language, unlike parakeet v3. Set `transcription.language`
(`"pt"`, `"en"`, `"es"`, …) and quill forces it. Leave it unset and Whisper
detects — but detection reads only the **first window**, so a meeting that
opens with a minute of English small talk before switching to Portuguese can
end up labelled English throughout, and the whole transcript degrades. If you
know the language, set it.

Whisper can emit confident stock phrases on silence even when its own
no-speech score says speech is present. quill independently checks waveform
energy before decoding, skips fully silent tracks, and requires credible voice
activity inside every decoded segment. It also strips Whisper control and
timestamp tokens before writing the transcript. The energy threshold is
configurable with `transcription.silence_threshold_db`; `quill doctor` checks
that the model for the currently selected engine is already cached.

## Speaker diarization and voice identification

Opt-in, fully local diarization splits `system.caf` into remote speakers with
FluidAudio's offline Pyannote Community-1 + WeSpeaker + VBx pipeline. Its Core
ML models download on first use. Quill joins the resulting speaker timeline to
ASR word timestamps, so a single long ASR segment can still become separate
`participant_1` and `participant_2` utterances. The mic track remains `me`.

Enable it with `diarization.enabled` in the config below. If model loading or
diarization fails, transcription still completes with the legacy `them` label;
speaker enrichment is never allowed to cost the recording itself.

Quill can also match participant clusters against a user-labelled voiceprint
library:

```sh
# Best: several clean samples from calls using the same audio path.
quill voices enroll "Maria" maria-call-1.wav maria-call-2.wav

# Or name a cluster after inspecting an existing transcript/session.
quill voices label ~/Recordings/2026.08.03-1400 participant_2 "Maria"

quill voices list
quill voices remove "Maria"
```

Enrollment requires at least three seconds of detected speech and rejects a
sample when several substantial voices are present. Multiple samples are
combined into a profile centroid. At transcription time a name is accepted
only when both its cosine-distance threshold and its lead over the second-best
profile pass; otherwise the honest `participant_N` label stays in place.
Predicted matches never update profiles automatically.

Voiceprints are biometric data. Quill stores only 256-dimensional embeddings,
not copied audio, in
`~/Library/Application Support/quill/voiceprints.json`, written owner-only
(`0600`). They never leave the machine and are deleted with `voices remove`.
Overlapping speech is still mixed audio: diarization says who spoke when, but
does not physically separate two simultaneous voices.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": {
    "enabled": true, "engine": "parakeet", "model": "v3",
    "language": "pt", "silence_threshold_db": -34
  },
  "diarization": {
    "enabled": true, "identify_speakers": true,
    "max_speakers": 8,
    "match_threshold": 0.42, "match_margin": 0.08
  },
  "auto_record": {
    "zoom": true, "start_delay_seconds": 3, "stop_delay_seconds": 20
  },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `transcription.engine` — `"parakeet"` (default, fast) or `"whisper"`
  (slower, more accurate). An unrecognized value warns and falls back to
  parakeet.
- `transcription.model` — for parakeet, the model version: `"v3"` (default,
  multilingual, self-detecting) or `"v2"` (English-only, marginally higher
  recall on English). An unrecognized value warns and falls back to v3.
  Whisper ships one model, `"whisper-large-v3-turbo"`.
- `transcription.language` — force the spoken language for whisper (`"pt"`,
  `"en"`, …). Unset means whisper detects from the first window, which
  mislabels a meeting that opens in another language. Parakeet ignores this —
  v3 detects per-utterance on its own.
- `transcription.silence_threshold_db` — waveform RMS threshold used to reject
  Whisper hallucinations on silence (default `-34` dBFS). Use a lower value
  such as `-40` only if real quiet speech is being dropped; a higher value
  suppresses more background noise. Parakeet ignores this setting.
- `diarization.enabled` — split remote system audio into `participant_N`
  speakers (default off). The offline models download on first use.
- `diarization.identify_speakers` — match clusters against the local voiceprint
  library (default on; has no effect until profiles are enrolled).
- `diarization.max_speakers` — expected upper bound for remote speakers,
  clamped to 2–20 (default 8). Set it near the largest call you normally have:
  a needlessly high cap can split one real voice into several clusters on a
  long, noisy recording.
- `diarization.match_threshold` — maximum cosine distance for accepting a
  known voice (default `0.42`; lower is stricter).
- `diarization.match_margin` — minimum lead over the second-best profile
  (default `0.08`; higher is stricter). Tune thresholds against your own
  validation calls rather than making them looser after a single miss.
- `auto_record.zoom` — automatically start and stop recordings from Zoom's
  audio activity (default off). Manual recording always wins: quill never
  auto-stops a session that was started from the menu.
- `auto_record.start_delay_seconds` — continuous Zoom audio before automatic
  start (default 3 seconds), filtering notification sounds and device churn.
- `auto_record.stop_delay_seconds` — inactive Zoom audio before automatic stop
  (default 20 seconds), allowing short reconnects and device switches.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill reprocess <session>    # regenerate an old transcript with current config
quill voices enroll <name> <audio...>
quill voices label <session-dir> <participant_N> <name>
quill voices list
quill voices remove <name-or-id>
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **Core Audio process activity** — Zoom call start/stop detection without
  Accessibility permissions or UI scripting
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription (default)
- **FluidAudio / Pyannote Community-1 + WeSpeaker + VBx** — optional offline
  speaker diarization and voice embeddings
- **WhisperKit / Whisper large-v3-turbo** — on-device Core ML transcription
  (the accuracy option)
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v2 (`"model": "v2"`) is English-only — it will happily return
  English-looking nonsense for other languages rather than failing. v3 is the
  default for that reason.
- Whisper's language detection reads only the first 30s window. Set
  `transcription.language` for any meeting that might not open in the language
  it's mostly conducted in.
- Remote-speaker diarization sees the mixed `system.caf` track. It can label
  sequential turns and detect overlaps, but ASR cannot reliably assign words
  when two people speak on top of each other.
- Diarization clusters are estimates, not identities. Long, noisy recordings
  can over-split one person; keep `diarization.max_speakers` close to the
  plausible participant count.
- Voice identification is deliberately conservative. Use several samples from
  different calls and keep `participant_N` when a match is ambiguous.
- Zoom auto-record starts when Zoom connects to computer audio, not when the
  meeting window opens. Calls joined without computer audio are intentionally
  ignored.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
