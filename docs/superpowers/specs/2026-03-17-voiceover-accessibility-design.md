# VoiceOver Accessibility — Design Spec

## Goal

Make Speak2 fully usable by VoiceOver users. Every interactive element must be labeled, every stateful element must report its value, and decorative elements must be hidden from the accessibility tree.

## Current State

Speak2 has zero user-facing VoiceOver support. The only accessibility code is system-level infrastructure (AXObserver for paste detection, AXIsProcessTrusted for permissions). All 14 view files, the menu bar, 4 window controllers, and all custom controls are inaccessible.

## Key Decisions

### Custom radio buttons → native Picker

All custom radio button implementations (Image "circle.inset.filled"/"circle" patterns) will be replaced with native `Picker` using `.pickerStyle(.radioGroup)`. This affects:
- SetupView (model selection)
- GeneralSettingsView (hotkey selection)
- ModelsSettingsView (model selection)
- AIRefineSettingsView (refinement mode selection)
- AddToDictionarySheet (new word vs alias)

Native pickers provide VoiceOver accessibility, keyboard navigation, and focus rings for free.

### Live transcription panel — hidden from VoiceOver

The floating live transcription panel is a visual feedback channel. For VoiceOver users it creates two problems:
1. VoiceOver speaking while the user is speaking creates a voice jammer effect
2. Navigating to the panel steals focus from the target text field, breaking the paste

The panel will be hidden entirely via `panel.setAccessibilityElement(false)` and `.accessibilityHidden(true)`. VoiceOver users rely on existing audio cues (recording start/stop sounds) and the accessible menu bar status.

The live transcription toggle in General Settings will have an `.accessibilityHint` explaining this: "Live transcription overlay is visual only and hidden from VoiceOver. Audio cues indicate recording status."

### KeyCaptureView — labels and passthrough hint

The custom key capture view (NSViewRepresentable) will get accessibility labels and a hint explaining VoiceOver passthrough (VO+Shift+Minus). If VoiceOver users find this too cumbersome, a structured picker alternative can be added later.

## Guiding Principles

| Element Type | Treatment |
|---|---|
| Buttons with text labels | Verify SwiftUI auto-labels; add `.accessibilityHint()` where action isn't obvious |
| Buttons with icon-only | `.accessibilityLabel("action description")` |
| Custom radio buttons | Replace with native `Picker(.radioGroup)` |
| Toggles | Verify SwiftUI auto-labels from title; add `.accessibilityHint()` for context |
| Text fields | `.accessibilityLabel()` if placeholder alone is insufficient |
| Progress indicators | `.accessibilityValue("\(Int(progress * 100)) percent")` |
| Status text (read-only) | `.accessibilityLabel()` with full context |
| Decorative icons | `.accessibilityHidden(true)` |
| Section headers | Keep as-is — SwiftUI Text with .font(.headline) is already announced |
| NSWindow/NSPanel | Set `.title` for window chooser; `.setAccessibilityElement(false)` for live transcription |
| NSMenu items | Already accessible by default — verify status line reads correctly |

## View-by-View Changes

### StatusBarController.swift
- NSMenu items are natively accessible on macOS — verify status line reads meaningfully
- Status bar icon already has accessibilityDescription — no changes needed

### SetupView.swift
- Replace custom radio buttons (model selection) with `Picker(.radioGroup)`
- Permission "Grant" buttons — `.accessibilityHint("Opens system settings to grant permission")`
- Download buttons — `.accessibilityHint()` describing action
- Progress bar — `.accessibilityValue()` with percentage
- Large download alert — verify (SwiftUI .alert() is accessible by default)

### GeneralSettingsView.swift
- Replace custom hotkey radio buttons with `Picker(.radioGroup)`
- KeyCaptureView — `.accessibilityLabel("Custom hotkey capture field")` and `.accessibilityHint("Activate VoiceOver passthrough with VO+Shift+Minus before pressing your desired key combination")`
- Live transcription toggle — `.accessibilityHint("Live transcription overlay is visual only and hidden from VoiceOver. Audio cues indicate recording status.")`
- About section — already uses standard Text views, accessible

### ModelsSettingsView.swift
- Replace custom radio buttons with `Picker(.radioGroup)`
- Download/delete buttons — `.accessibilityLabel()` including model name
- Download progress — `.accessibilityValue()` with percentage
- Storage location picker — `.accessibilityHint()`
- Disclosure chevrons — `.accessibilityHidden(true)`

### DictionarySettingsView.swift
- List rows — `.accessibilityElement(children: .combine)` to group content
- Toggle enable/disable — `.accessibilityLabel("Enable [word]")` and `.accessibilityValue()`
- Edit/delete icon buttons — `.accessibilityLabel("Edit [word]")`, `"Delete [word]"`
- Import/export buttons — verify text labels are sufficient

### DictionaryEntryEditor.swift
- Text fields — verify labels connected, add `.accessibilityLabel()` where needed
- Category/language pickers — verify (SwiftUI Picker is accessible by default)

### QuickAddSheet.swift
- Text fields — `.accessibilityLabel()` where placeholder alone is insufficient
- Category/language pickers — verify

### AddToDictionarySheet.swift
- Replace radio-style selection (new word vs alias) with `Picker(.radioGroup)`
- Search results list — `.accessibilityLabel()` on each result row

### HistorySettingsView.swift
- History rows — `.accessibilityElement(children: .combine)`
- Copy/delete icon buttons — `.accessibilityLabel("Copy transcription")`, `"Delete transcription"`
- "Show More/Show Less" — `.accessibilityHint()`
- Model filter dropdown — verify Picker accessible
- Clear all confirmation — verify (SwiftUI .confirmationDialog() accessible by default)

### AIRefineSettingsView.swift
- Replace custom radio buttons (Off/Built-in/Ollama) with `Picker(.radioGroup)`
- URL text field — `.accessibilityLabel("Ollama server URL")`
- Model name field — `.accessibilityLabel("Ollama model name")`
- Custom prompt TextEditor — `.accessibilityLabel("Custom refinement prompt")`
- Test connection button — `.accessibilityHint("Tests connection to the Ollama server")`
- Download model progress — `.accessibilityValue()`

### LiveTranscriptionPanel.swift
- `panel.setAccessibilityElement(false)` on NSPanel
- `.accessibilityHidden(true)` on all panel content

### Window Controllers (all 4)
- Verify `.title` is set on each NSWindow

## Implementation Approach

Systematic view-by-view pass. Each view is an independent unit of work that can be parallelized across subagents. All changes ship together as a single release.

## Testing

Manual VoiceOver testing after implementation:
1. Enable VoiceOver (Cmd+F5)
2. Navigate every view with VO+Arrow keys
3. Verify every control is announced with label, role, and value
4. Verify decorative elements are skipped
5. Verify live transcription panel is invisible to VoiceOver
6. Test full dictation flow: menu bar → record → transcribe → paste
7. Verify KeyCaptureView passthrough hint is announced
