# Speak2

Local voice dictation for macOS. Hold the fn key (configurable) to speak, release to transcribe. Works with any application.

100% on-device using [WhisperKit](https://github.com/argmaxinc/WhisperKit) or [Parakeet](https://github.com/FluidInference/FluidAudio) - no cloud services, no data leaves your Mac.

**[User Guide](https://moonquakemedia.com/guides/speak2/)** — Complete documentation for setup, dictation, models, dictionary, AI refinement, and more.

## Features

- **Push-to-talk or toggle dictation** - Hold a hotkey to record, or double-press to toggle on/off
- **Live transcription overlay** - See your words appear in real time as you speak
- **Multiple speech engines** - WhisperKit (5 model sizes) and Parakeet v3
- **AI text refinement** - Built-in LLM or Ollama cleans up filler words and false starts
- **Personal dictionary** - Phonetic matching corrects names, jargon, and technical terms
- **Transcription history** - Browse, search, and export your last 500 transcriptions
- **Custom hotkeys** - Fn, Right Option, Right Command, Hyper Key, or any custom key combo
- **Clipboard restoration** - Automatically restores your clipboard after pasting
- **100% private** - Everything runs locally on Apple Silicon, nothing leaves your Mac

## Speech Recognition Models

Speak2 supports multiple Whisper model sizes plus Parakeet for multilingual use:

| Model | Size | Languages | Best For |
|-------|------|-----------|----------|
| **Whisper tiny.en** | ~75 MB | English only | Fastest, lowest resource usage |
| **Whisper base.en** | ~140 MB | English only | Recommended balance of speed/accuracy |
| **Whisper small.en** | ~460 MB | English only | Better accuracy |
| **Whisper large-v3** | ~3 GB | 100+ languages | Best accuracy, multilingual |
| **Whisper large-v3 turbo** | ~954 MB | 100+ languages | Fast + accurate, multilingual |
| **Parakeet v3** | ~600 MB | 25 languages | Alternative multilingual option |

You can download multiple models and switch between them from the menu bar. Only one model is loaded at a time to conserve memory.

### Model Storage Location

By default, models are stored in `~/Library/Application Support/Speak2/Models/`. You can change this location in **Settings > Models** if you prefer to store large models on an external drive or different location.

When changing the storage location, you'll be prompted to either move existing models to the new location or start fresh.

## Requirements

- macOS 14.0 or later
- Apple Silicon Mac (M1/M2/M3/M4)

## Installation

### From DMG (recommended)
Download the latest .dmg from the [releases](https://github.com/zachswift615/speak2/releases) page and install.

### Build from source

```bash
git clone https://github.com/zachswift615/speak2.git
cd speak2/Speak2

# Install Metal toolchain (required once for MLX GPU shaders)
xcodebuild -downloadComponent MetalToolchain

# Build
xcodebuild build -scheme Speak2 -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .derivedData
```

> **Note:** You must use `xcodebuild` (not `swift build`) because the MLX dependency requires Xcode's build system to compile Metal shaders. `swift build` will compile but the app will crash at runtime when the built-in LLM feature is used.

### Run

```bash
.derivedData/Build/Products/Release/Speak2
```

### Tests

Tests can still use the Swift CLI since they don't exercise Metal:

```bash
swift test
```

## Releasing a New Version

Before building a release, update the version number in two places:

1. `Sources/Models/AppState.swift` — update `AppState.appVersion` (displayed in **Settings > General > About**)
2. `Sources/Info.plist` — update `CFBundleShortVersionString` and `CFBundleVersion` (used in the .app bundle for DMG distribution)

## First Launch Setup

On first launch, a setup window will appear. You need to:

### 1. Grant Accessibility Permission

This is required for global fn key detection.

#### DMG installs
<img width="456" height="356" alt="Screenshot 2025-12-01 at 2 13 06 PM" src="https://github.com/user-attachments/assets/fdd923ad-672a-4405-8db2-68e4529cd4d1" />

Click "Grant" next to Accessibility on the first launch window

<img width="466" height="183" alt="image" src="https://github.com/user-attachments/assets/28d9d0f9-25fb-4d7a-9396-1fad03426128" />

Then click Open System Settings

<img width="468" height="55" alt="image" src="https://github.com/user-attachments/assets/4b80e39e-0dec-4a19-8a6e-517c9fd4d578" />

Then find speak2 in the list and toggle the permission switch on and authenticate with password or fingerprint. If Speak2 is not in the list, click the `+` button and nagivate to your Applications directory where you dragged it to install, and Add Speak2 to the list of apps.

#### Building from source

**Option A:** Add Speak2 directly
1. Open **System Settings > Privacy & Security > Accessibility**
2. Click the **+** button
3. Press **Cmd+Shift+G** and navigate to the built binary (e.g. `.derivedData/Build/Products/Release/Speak2`)
4. Select the Speak2 executable and enable it

**Option B:** Enable Terminal (easier for development)
1. Open **System Settings > Privacy & Security > Accessibility**
2. Find **Terminal** in the list and toggle it **ON**
3. This allows any app run from Terminal to use accessibility features

### 2. Grant Microphone Permission
Click "Grant" next to Microphone. And click "Allow" on the permission window that pops up.

### 3. Download Speech Model

Choose a model and click "Download". For most users, **Whisper base.en** (~140MB) is recommended as a good balance of speed and accuracy.

See the [Speech Recognition Models](#speech-recognition-models) section above for all available options.

**Note:** Large models (large-v3, large-v3 turbo) will prompt for confirmation before downloading due to their size. Parakeet takes longer to load initially (~20-30 seconds) as it compiles the neural engine model. Subsequent loads are faster. The menu bar icon will show a spinning indicator while loading.

Once all three items show checkmarks, the setup window will indicate completion and you can close it.

> **Note:** Speak2 automatically detects when permissions are granted and will start the hotkey listener without a restart. In rare cases, macOS may not register the permission change immediately - if the hotkey doesn't respond after granting permissions, quit and relaunch Speak2.

## Usage

1. **Hold the fn key** - Recording starts (menu bar icon turns red, audio start sound plays)
2. **Speak** - Say what you want to type (live transcription overlay shows your words in real time)
3. **Release fn key** - Final transcription happens (icon shows spinner), text is refined if enabled, then pasted

The transcribed text is automatically pasted into whatever application text field has focus.

### Recording Modes

Speak2 supports two recording modes, configurable in **Settings > General**:

| Mode | How It Works |
|------|-------------|
| **Hold** (default) | Hold the hotkey to record, release to transcribe |
| **Toggle** | Press the hotkey twice to start recording, press twice again to stop and transcribe |

Toggle mode uses a 400ms window to detect the double-press. This is useful if you don't want to hold a key down for long dictations.

### Live Transcription Overlay

When enabled (**Settings > General**), a floating overlay appears at the bottom of your screen while recording. It shows your words in real time as you speak:

- **Confirmed text** appears in normal weight as the engine locks in words
- **Unconfirmed text** appears in italic as the engine processes your speech
- A pulsing red dot indicates active recording
- The panel auto-sizes and stays centered on screen
- Works across all spaces and full-screen apps

Live transcription uses streaming recognition - the same audio is also transcribed as a complete pass when you stop recording for maximum accuracy.

### Menu Bar

Speak2 runs as a menu bar app (no dock icon). Look for the microphone icon:

- **White/Black (depending on macOS theme)** - Idle, ready to record
- **Yellow spinning arrows** - Loading model
- **Red mic** - Recording in progress
- **Cyan spinner** - Transcribing
- **Purple sparkles** - AI refinement in progress

The menu shows a status line at the top indicating the current state (e.g., "Ready - Whisper (base.en)").

#### Switching Models
Click the menu bar icon and select **Model** to switch between downloaded models. Models not yet downloaded show a ↓ indicator - clicking them opens the setup window to download.

#### Choosing Hotkey

You can choose from several hotkey options in **Settings > General** or the menu bar **Hotkey** submenu:

| Hotkey | Description |
|--------|-------------|
| **Fn** (default) | Function key |
| **Right Option** | Right Option/Alt key |
| **Right Command** | Right Command key |
| **Hyper Key** | Ctrl+Option+Cmd+Shift (all four modifiers) |
| **Ctrl+Option+Space** | Three-key combo |
| **Custom** | Any key or key+modifier combo you define |

**Custom hotkeys** let you record any key combination using a capture interface. You can save multiple custom combos and switch between them. Supports single keys, modifier-only triggers, and key+modifier combinations.

Sometimes external keyboards don't send the function key reliably. In that case, choose one of the alternative options.

#### Settings

Click **Settings...** (⌘,) from the menu bar to open the unified settings window with five tabs:

- **General** - Hotkey configuration, recording mode (hold/toggle), live transcription toggle, permissions, launch at login
- **Models** - Download, manage, and delete speech recognition models; configure storage location
- **Dictionary** - Manage your personal dictionary (add, edit, import/export words)
- **History** - Browse, search, and export your transcription history
- **AI Refine** - Configure optional AI post-processing to clean up transcriptions

#### Add Word
Click **Add Word...** from the menu bar for quick dictionary word addition without opening the full settings window.

#### Personal Dictionary

Speak2 includes a personal dictionary feature that helps improve transcription accuracy for names, technical terms, industry jargon, and unique spellings.

**Accessing the Dictionary:**
- Click the menu bar icon → **Add Word...** for quick word addition
- Open **Settings > Dictionary** for full dictionary management

**Adding Words:**

Each dictionary entry can include:
| Field | Required | Description |
|-------|----------|-------------|
| Word | Yes | The correct spelling you want |
| Aliases | No | Common misspellings or mishearings (comma-separated) |
| Pronunciation | No | Phonetic hint for words spelled differently than pronounced |
| Category | No | Organization (Names, Technical, Medical, etc.) |
| Language | Yes | Which language this word belongs to (25 languages supported) |

**How It Works:**

When you speak, the transcription is post-processed using your dictionary:
1. **Alias matching** - Direct replacement of known misspellings (exact match, case-insensitive)
2. **Phonetic matching** - Multiple algorithms catch similar-sounding words:
   - **Soundex** - Traditional phonetic encoding
   - **Metaphone** - Better handling of English pronunciation rules
   - **Fuzzy matching** - Catches words with 70%+ similarity

**Using the Pronunciation Field:**

The pronunciation field helps when a word is spelled very differently from how it sounds. When set, phonetic matching uses the pronunciation hint instead of the word's spelling.

| Word | Pronunciation | Why |
|------|---------------|-----|
| Nguyen | "Win" | Vietnamese name pronounced differently than spelled |
| Siobhan | "Shivon" | Irish name with non-obvious pronunciation |
| GIF | "Jif" | If you prefer the soft G pronunciation |
| SQL | "Sequel" | Matches the spoken acronym |

**Examples:**

| Scenario | Word | Aliases | Pronunciation |
|----------|------|---------|---------------|
| Company name | Anthropic | Antropik, Anthropik | *(not needed - sounds like spelling)* |
| Technical term | Kubernetes | Cooper Netties, Kubernetties | *(not needed)* |
| Person's name | Siobhan | Shivon, Shavon | Shivon |
| Acronym | AWS | | Amazon Web Services |

For most words, you won't need the pronunciation field - phonetic matching will handle common mishearings automatically. Use it only when the spelling is very different from the sound.

**Right-Click Service:**

You can also add words directly from any application:
1. Select/highlight any text
2. Right-click → **Services** → **Add to Speak2 Dictionary**
3. Choose to add as a new word or as an alias to an existing word

> **Note:** The service may require logging out and back in to appear after first install.

**Import/Export:**

The dictionary can be exported to JSON and imported on another machine via **Settings > Dictionary**.

#### Transcription History

Speak2 keeps a history of your last 500 transcriptions, grouped by date (Today, Yesterday, Last 7 Days, etc.).

- Open **Settings > History** to browse, search, and export your transcription history
- Click the copy icon on any entry to copy it to your clipboard
- Use the model filter dropdown to show only transcriptions from a specific model
- Long transcriptions show a "Show More" toggle to expand the full text
- Each entry records the text, timestamp, model used, language, and audio length

History is stored locally at `~/Library/Application Support/Speak2/transcription_history.json`.

#### AI Text Refinement

Speak2 can optionally clean up transcribed text using an LLM before pasting. This removes filler words, false starts, repetitions, and verbal noise - entirely on-device, no cloud required.

Open **Settings > AI Refine** to choose a mode:

| Mode | Description |
|------|-------------|
| **Off** | No refinement - raw transcription is pasted directly |
| **Built-in (recommended)** | Downloads a small LLM (~1.1 GB) that runs locally via MLX |
| **External Server (Ollama)** | Sends text to a local Ollama instance for processing |

**Built-in mode:**

1. Select **Built-in (recommended)** in Settings > AI Refine
2. Click **Download Model** - downloads Qwen 2.5 1.5B Instruct (~1.1 GB) once
3. A green "Ready" checkmark appears when the model is cached

No additional software required. The model downloads to `~/Library/Caches/huggingface/hub/` and runs on Apple Silicon GPU via MLX.

**External Server (Ollama) mode:**

For users who prefer to use their own model via [Ollama](https://ollama.com):

1. Install and run [Ollama](https://ollama.com), pull a model (e.g. `ollama pull gemma3:4b`)
2. Select **External Server (Ollama)** in Settings > AI Refine
3. Set the **Server URL** (default: `http://localhost:11434`) and **Model Name**
4. Click **Test Connection** to verify

**How it works:**

After transcription (and dictionary post-processing), the text is sent to the selected LLM with a cleanup prompt. The refined result is pasted instead of the raw transcription. If refinement fails for any reason, Speak2 silently falls back to the original transcription so dictation is never interrupted.

During refinement the menu bar icon shows a **purple sparkles** symbol and the status reads "Refining with AI...".

**Custom prompt:**

The default prompt instructs the model to clean up transcription without adding commentary. You can replace it with anything - for example a prompt that formats output as bullet points, translates to another language, or applies domain-specific corrections. Leave the field empty to restore the default. The prompt is shared between both built-in and external modes.

#### Launch at Login
Toggle this option in **Settings > General**.

#### Quit Speak2
Click the menu bar icon and click "Quit Speak2".

## How It Works

- **HotkeyManager** - Detects hotkey press/release (hold mode) or double-press (toggle mode) using CGEvent tap
- **AudioRecorder** - Captures microphone audio at 16kHz mono PCM via AVAudioEngine
- **ModelManager** - Handles model downloading, loading, switching, and dispatching to the active engine
- **WhisperTranscriber** - Runs WhisperKit on-device for speech-to-text (supports streaming and file-based transcription)
- **ParakeetTranscriber** - Runs FluidAudio/Parakeet on-device for speech-to-text (supports streaming and file-based transcription)
- **DictationController** - Orchestrates the full record → stream → transcribe → refine → paste pipeline
- **DictionaryProcessor** - Post-processes transcription using personal dictionary (alias replacement + phonetic matching)
- **MLXRefiner** - Built-in LLM refinement using MLX (Qwen 2.5 1.5B Instruct); downloads and runs on-device
- **OllamaRefiner** - External LLM refinement via a local Ollama server; falls back to original text on any error
- **LiveTranscriptionPanel** - Floating overlay that displays streaming transcription results in real time
- **TranscriptionHistoryStorage** - Persists transcription history to local JSON (up to 500 entries)
- **TextInjector** - Copies transcription to clipboard, simulates Cmd+V to paste, then restores original clipboard contents

Both transcription engines implement a `StreamingTranscriptionEngine` protocol for live transcription, using a custom AVAudioEngine-based sliding-window approach for real-time results. A word-level diff algorithm separates confirmed from unconfirmed text in the overlay.

The selected model stays loaded in memory (~300-600MB RAM depending on model) for instant transcription.

## Tips

- Speak naturally with punctuation inflection - Whisper handles periods, commas, and question marks based on your tone
- Keep recordings under 30 seconds for best performance
- First transcription may be slightly slower as the model warms up
- Enable live transcription to see your words as you speak - useful for catching errors early
- Add frequently used names and technical terms to your personal dictionary for better accuracy
- Use aliases for words that are commonly misheard (e.g., add "Kubernetes" with alias "Cooper Netties")
- Try the built-in AI refinement to automatically clean up filler words like "um", "uh", and false starts
- Use toggle mode for longer dictations so you don't have to hold the key down

## Troubleshooting

### Model won't load or keeps re-downloading

If you upgraded from an earlier version of Speak2, your models may have been stored at a legacy location (`~/Documents/huggingface`). The app attempts to migrate these automatically, but if you experience issues:

**Quick fix:**
1. Open **Settings > Models**
2. Delete the affected model (trash icon)
3. Re-download it

**Manual cleanup (if needed):**
```bash
# Remove any orphaned model files at the old location
rm -rf ~/Documents/huggingface

# Remove incorrectly migrated files (if present)
rm -rf ~/Library/Application\ Support/Speak2/Models/huggingface

# Reset migration flag to trigger fresh migration on next launch
defaults delete com.zachswift.speak2 didAttemptLegacyMigrationV2
```

Then restart Speak2. If you had models at the legacy location, they'll be migrated to the correct path.

### Model shows as downloaded but won't transcribe

Try clicking on the model in **Settings > Models** to reload it. If that doesn't work, delete and re-download the model.

### Hotkey doesn't work after granting permissions

Speak2 automatically detects permission changes and starts the hotkey listener. If the hotkey still doesn't respond after granting both Accessibility and Microphone permissions, quit and relaunch Speak2. macOS occasionally requires a restart for CGEvent tap permissions to take effect.

### Multilingual model translating instead of transcribing

If a multilingual Whisper model (large-v3, large-v3 turbo) is translating your speech to English instead of transcribing it in the original language, this has been fixed in v1.5.0. Update to the latest version.

## Known Limitations

- Parakeet model takes ~20-30 seconds to load on first use (compiling neural engine model)
- Uses clipboard for text injection (briefly swaps clipboard contents, then restores them)
- fn key detection requires Accessibility permission
- Only tested on Apple Silicon Macs
- Live transcription streaming accuracy may differ slightly from the final transcription pass

## Tech Stack

- Swift + SwiftUI
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) - Apple's optimized Whisper implementation
- [FluidAudio](https://github.com/FluidInference/FluidAudio) - Parakeet speech recognition for Apple Silicon
- [MLX Swift](https://github.com/ml-explore/mlx-swift-lm) - On-device LLM inference for built-in text refinement
- AVFoundation / AVAudioEngine for audio capture and streaming
- CGEvent for global hotkey detection
- Accelerate (vDSP) for audio level analysis

## See Also

- **[Listen2](https://apps.apple.com/us/app/listen-2-reader/id6755753624)** — On-device text-to-speech for macOS. The companion to Speak2.

## License

MIT
