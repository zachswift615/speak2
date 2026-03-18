# VoiceOver Accessibility — Design Spec

## Goal

Make Speak2 fully usable by VoiceOver users. Every interactive element must be labeled, every stateful element must report its value, and decorative elements must be hidden from the accessibility tree.

## Current State

Speak2 has zero user-facing VoiceOver support. The only accessibility code is system-level infrastructure (AXObserver for paste detection, AXIsProcessTrusted for permissions). All view files, the menu bar, window controllers, and all custom controls are inaccessible.

## Key Decisions

### Custom radio buttons — case-by-case treatment

Some views use custom radio button patterns (Image "circle.inset.filled"/"circle"). The treatment depends on complexity:

**Simple selection (can use native Picker):**
- AIRefineSettingsView — already uses `Picker(.radioGroup)`, verify accessible
- AddToDictionarySheet — already uses `Picker(.radioGroup)`, verify accessible

**Complex selection (keep custom pattern, add accessibility modifiers):**
- SetupView (model selection) — compound widget with disclosure groups, download buttons, progress bars, and active badges. Cannot be a simple Picker. Add `.accessibilityLabel()`, `.accessibilityValue("selected"/"not selected")`, `.accessibilityAddTraits(.isSelected)` to each row.
- GeneralSettingsView (hotkey selection) — dynamic list of presets + custom combos with delete buttons + capture mode. Cannot be a simple Picker. Add accessibility modifiers to each `hotkeyRow`.
- ModelsSettingsView (model selection) — same compound widget pattern as SetupView. Add accessibility modifiers to each row.

### onTapGesture → Button (functional blocker)

Model rows in SetupView and ModelsSettingsView use `.onTapGesture` for selection. VoiceOver cannot activate tap gestures. These must be refactored to use `Button` or have `.accessibilityAction(.default)` added. This is a functional blocker — VoiceOver users literally cannot select models without this fix.

### Live transcription panel — hidden from VoiceOver

The floating live transcription panel is a visual feedback channel. For VoiceOver users it creates two problems:
1. VoiceOver speaking while the user is speaking creates a voice jammer effect
2. Navigating to the panel steals focus from the target text field, breaking the paste

The panel will be hidden entirely via `panel.setAccessibilityElement(false)` and `.accessibilityHidden(true)`. VoiceOver users rely on existing audio cues (recording start/stop sounds) and the accessible menu bar status.

The live transcription toggle in General Settings will have an `.accessibilityHint` explaining this: "Live transcription overlay is visual only and hidden from VoiceOver. Audio cues indicate recording status."

### State change announcements

Speak2 is a push-to-talk app where the user is focused on another application during dictation. VoiceOver users need audio feedback for state transitions. Post `NSAccessibility.post(notification: .announcementRequested)` for:
- "Recording started" (when recording begins)
- "Transcribing" (when recording stops and transcription starts)
- "Refining with AI" (when AI refinement starts, if enabled)
- "Text pasted" (when transcription is complete and pasted)

These announcements complement the existing audio cues (start/stop sounds).

### KeyCaptureView — labels and passthrough hint

The custom key capture view (NSViewRepresentable) will get accessibility labels and a hint explaining VoiceOver passthrough (VO+Shift+Minus). If VoiceOver users find this too cumbersome, a structured picker alternative can be added later.

### Hover-only buttons — always in accessibility tree

DictionaryEntryRow edit/delete buttons use `.opacity(isHovering ? 1 : 0)` making them invisible until hover. VoiceOver users cannot hover. These buttons must remain in the accessibility tree regardless of visual opacity — either always set `opacity` to 1 for VoiceOver users via `@Environment(\.accessibilityEnabled)`, or ensure the accessibility tree includes them even at opacity 0 (which SwiftUI does by default for opacity but not for `if/else` conditionals).

## Guiding Principles

| Element Type | Treatment |
|---|---|
| Buttons with text labels | Verify SwiftUI auto-labels; add `.accessibilityHint()` where action isn't obvious |
| Buttons with icon-only | `.accessibilityLabel("action description")` |
| Simple radio selection | Verify native `Picker(.radioGroup)` is accessible |
| Complex radio selection | Add `.accessibilityLabel()`, `.accessibilityValue()`, `.accessibilityAddTraits(.isSelected)` |
| onTapGesture interactions | Refactor to `Button` or add `.accessibilityAction(.default)` |
| Toggles | Verify SwiftUI auto-labels from title; add `.accessibilityHint()` for context |
| Text fields | `.accessibilityLabel()` if placeholder alone is insufficient |
| Progress indicators | `.accessibilityValue("\(Int(progress * 100)) percent")` |
| Status text (read-only) | `.accessibilityLabel()` with full context |
| Decorative icons | `.accessibilityHidden(true)` |
| Section headers | Add `.accessibilityAddTraits(.isHeader)` for rotor navigation |
| Date group headers (History) | Add `.accessibilityAddTraits(.isHeader)` for rotor navigation |
| Empty state decorative icons | `.accessibilityHidden(true)` |
| Error banners | `.accessibilityLabel()` on dismiss button; post layout-change notification on appear |
| Active/status badges | Include in combined row label or `.accessibilityHidden(true)` if redundant |
| NSWindow/NSPanel | Set `.title` for window chooser; `.setAccessibilityElement(false)` for live transcription |
| NSMenu items | Already accessible by default — verify status line reads correctly |
| Dynamic content changes | Post `NSAccessibilityNotificationName.layoutChanged` when sections expand/collapse |

## View-by-View Changes

### StatusBarController.swift
- NSMenu items are natively accessible on macOS — verify status line reads meaningfully
- Status bar icon already has accessibilityDescription — no changes needed

### SetupView.swift
- Refactor model row `onTapGesture` to `Button` or `.accessibilityAction(.default)`
- Model rows — `.accessibilityElement(children: .combine)` with combined label including model name, size, download state
- Model rows — `.accessibilityAddTraits(.isSelected)` on active model
- Whisper disclosure toggle — `.accessibilityLabel("Whisper models")` with expand/collapse state
- Permission "Grant" buttons — `.accessibilityHint("Opens system settings to grant permission")`
- Permission granted checkmark icon — `.accessibilityLabel("Granted")`
- Download buttons — `.accessibilityHint()` describing action
- Progress bar — `.accessibilityValue()` with percentage
- Active badge — include in combined row label or `.accessibilityHidden(true)`
- Large download alert — verify (SwiftUI .alert() is accessible by default)

### GeneralSettingsView.swift
- Hotkey preset rows — add `.accessibilityLabel()`, `.accessibilityValue("selected"/"not selected")`, `.accessibilityAddTraits(.isSelected)` to each `hotkeyRow`
- Custom combo rows — same treatment, plus `.accessibilityLabel("Delete [combo name]")` on minus button
- KeyCaptureView — `.accessibilityLabel("Custom hotkey capture field")` and `.accessibilityHint("Activate VoiceOver passthrough with VO+Shift+Minus before pressing your desired key combination")`
- Live transcription toggle — `.accessibilityHint("Live transcription overlay is visual only and hidden from VoiceOver. Audio cues indicate recording status.")`
- About section — already uses standard Text views, accessible

### SettingsView.swift
- Verify NavigationSplitView sidebar tabs are accessible (Label views in List should work)

### ModelsSettingsView.swift
- Refactor model row `onTapGesture` to `Button` or `.accessibilityAction(.default)`
- Model rows — `.accessibilityElement(children: .combine)` with combined label
- Model rows — `.accessibilityAddTraits(.isSelected)` on active model
- Download/delete buttons — `.accessibilityLabel()` including model name
- Download progress — `.accessibilityValue()` with percentage
- Storage location — `.accessibilityHint()` on Choose Folder / Use Default buttons; accessibility for moving-in-progress state
- Disclosure chevrons — `.accessibilityHidden(true)`
- Active badge — include in combined row label or `.accessibilityHidden(true)`

### DictionarySettingsView.swift
- List rows — `.accessibilityElement(children: .combine)` to group content
- Toggle enable/disable — `.accessibilityLabel("Enable [word]")` and `.accessibilityValue()`
- Edit/delete icon buttons — `.accessibilityLabel("Edit [word]")`, `"Delete [word]"`; ensure visible to VoiceOver even when hover-hidden
- Import/export buttons — verify text labels are sufficient
- Error banner dismiss button — `.accessibilityLabel("Dismiss error")`
- Empty state decorative icon — `.accessibilityHidden(true)`
- Footer word/entry count — `.accessibilityElement(children: .combine)` with readable label

### DictionaryView.swift
- Same treatment as DictionarySettingsView (standalone window version)
- Error banner dismiss button — `.accessibilityLabel("Dismiss error")`
- Empty state decorative icon — `.accessibilityHidden(true)`

### DictionaryEntryRow.swift
- Edit/delete buttons — ensure in accessibility tree regardless of hover opacity
- Category badge icon — `.accessibilityHidden(true)` (category name is already in text)
- Enable/disable toggle — `.accessibilityLabel("Enable [word]")` and `.accessibilityValue()`

### DictionaryEntryEditor.swift
- Text fields — verify labels connected, add `.accessibilityLabel()` where needed
- Category/language pickers — verify (SwiftUI Picker is accessible by default)

### QuickAddSheet.swift
- Text fields — `.accessibilityLabel()` where placeholder alone is insufficient
- Category/language pickers — verify

### AddToDictionarySheet.swift
- Already uses `Picker(.radioGroup)` — verify accessible
- Search results list — `.accessibilityLabel()` on each result row

### TranscriptionHistoryRow.swift
- Copy button — `.accessibilityLabel()` that updates with transient state ("Copy transcription" / "Copied")
- Delete button — `.accessibilityLabel("Delete transcription")`
- "Show More/Show Less" — `.accessibilityHint()`
- `.accessibilityElement(children: .combine)` for row grouping

### HistorySettingsView.swift
- Date section headers ("Today", "Yesterday", etc.) — `.accessibilityAddTraits(.isHeader)` for rotor navigation
- Model filter dropdown — verify Picker accessible
- Clear all confirmation — verify (SwiftUI .confirmationDialog() accessible by default)
- Error banner dismiss button — `.accessibilityLabel("Dismiss error")`
- Empty state / no results decorative icons — `.accessibilityHidden(true)`
- Footer entry count — `.accessibilityElement(children: .combine)` with readable label

### TranscriptionHistoryView.swift
- Same treatment as HistorySettingsView (standalone window version)

### AIRefineSettingsView.swift
- Already uses `Picker(.radioGroup)` for mode selection — verify accessible
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

### DictationController.swift (state announcements)
- Post `NSAccessibility.post(notification: .announcementRequested)` for state transitions:
  - "Recording started"
  - "Transcribing"
  - "Refining with AI" (if enabled)
  - "Text pasted"

## Implementation Approach

Systematic view-by-view pass. Each view is an independent unit of work that can be parallelized across subagents. All changes ship together as a single release.

## Testing

### Manual VoiceOver testing
1. Enable VoiceOver (Cmd+F5)
2. Navigate every view with VO+Arrow keys
3. Verify every control is announced with label, role, and value
4. Verify decorative elements are skipped
5. Verify live transcription panel is invisible to VoiceOver
6. Test full dictation flow: menu bar → record → transcribe → paste
7. Verify state announcements fire ("Recording started", "Transcribing", "Text pasted")
8. Verify KeyCaptureView passthrough hint is announced
9. Test QuickAddSheet from menu bar "Add Word..."
10. Verify error banners are announced when they appear

### Keyboard-only navigation
11. Tab/Shift-Tab through all settings views — verify logical focus order
12. Verify all interactive elements are keyboard-reachable

### Accessibility Inspector
13. Run Xcode Accessibility Inspector audit on each view to catch unlabeled elements
