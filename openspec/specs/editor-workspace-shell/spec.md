# editor-workspace-shell Specification

## Purpose
Define Jort's native editor workspace shell, title bar, footer, and landmark-index interaction.

## Requirements

### Requirement: The editor window has distinct stable workspace regions
Jort SHALL present a native title bar above a content region divided into a fixed landmark gutter and document canvas, with a fixed footer below them, and SHALL visually separate the gutter and footer without reducing the editor to a secondary panel.

#### Scenario: Healthy editor opens
- **WHEN** the document finishes loading in a healthy window
- **THEN** the title bar, gutter, canvas, and footer are visually distinct regions
- **AND** the editable canvas receives first responder and occupies all remaining content space

#### Scenario: Window is resized
- **WHEN** the user resizes the window down to its supported minimum or expands it
- **THEN** the gutter width and footer height remain stable
- **AND** the canvas resizes without overlapping either region
- **AND** wrapped text, scroll bars, and the native Find bar remain usable

#### Scenario: Separators render on a scaled display
- **WHEN** the shell renders at any supported backing scale factor
- **THEN** the gutter trailing edge and footer top edge render as aligned one-device-pixel separators
- **AND** the footer does not continue that boundary between the Option symbol and landmark label

### Requirement: The title bar remains quiet and native
Jort SHALL retain the native macOS title bar and traffic-light controls, SHALL keep Pocket as the sole right-side product action, and SHALL not visibly render an app logo, app/document title, Queue, History, overflow, or other roadmap placeholder.

#### Scenario: Main window is visible
- **WHEN** the user views the title bar
- **THEN** native traffic-light controls appear at the left and the Pocket icon appears at the right
- **AND** the center contains no Jort logo or visible title
- **AND** Queue, History, plus, and overflow controls are absent

#### Scenario: System inspects the untitled-looking window
- **WHEN** macOS or an accessibility client requests the window identity
- **THEN** the window remains identified as Jort despite hiding that title visually

#### Scenario: Pocket is activated
- **WHEN** the user activates the Pocket title-bar control or presses Command-K
- **THEN** Jort opens the existing Pocket command palette
- **AND** title-bar simplification does not change its focus, selection, or dismissal behavior

### Requirement: The footer communicates only current editor state
Jort SHALL show a left-aligned Option-key landmark affordance and attached-landmark count in the separated footer, SHALL use the footer for existing actionable persistence attention when present, and SHALL leave speculative center and right controls absent.

#### Scenario: No landmarks or storage problems exist
- **WHEN** the editor is healthy and contains no attached landmarks
- **THEN** the footer displays the Option symbol with a zero landmark count
- **AND** no idle activity message, Ask Jort control, or capture control appears

#### Scenario: Attached landmarks change
- **WHEN** a landmark is attached, detached, moved, or cleared
- **THEN** the footer updates its attached-landmark count to match the navigable gutter index
- **AND** does not change document text or editor focus

#### Scenario: Persistence needs attention
- **WHEN** the existing persistence state requires user action
- **THEN** its message and available retry or recovery action appear in the footer without covering document text
- **AND** when the condition clears, the center footer region becomes empty

### Requirement: Option temporarily reveals the landmark index
Jort SHALL show landmark navigation for as long as Option is held, SHALL restore the user's latched gutter preference when Option is released, and SHALL treat the modifier as observation rather than a consumed command.

#### Scenario: Option is held from line-number mode
- **WHEN** the gutter is not latched in landmark mode and the user presses and holds Option
- **THEN** the gutter displays the landmark index for the duration of the hold
- **AND** releasing Option restores line-number mode

#### Scenario: Option is held from latched landmark mode
- **WHEN** the gutter is already latched in landmark mode and the user presses and releases Option
- **THEN** the landmark index remains visible throughout and after the hold

#### Scenario: User changes the latch while holding Option
- **WHEN** the user activates the footer landmark status while Option is held
- **THEN** Jort updates the latched preference while the effective landmark index remains visible
- **AND** release reveals the newly selected latched state

#### Scenario: Option participates in text input
- **WHEN** the user enters an Option-modified character or uses an Option-modified native text command
- **THEN** the text system receives the original modifier event unchanged
- **AND** the temporary gutter reveal does not mutate selection, text, undo state, or viewport

#### Scenario: Focus changes during a hold
- **WHEN** Jort loses key-window or application-active state before receiving an Option release
- **THEN** Jort clears transient held state
- **AND** restores the latched gutter preference when the window becomes active again

### Requirement: Shell controls remain accessible without becoming document content
Jort SHALL expose the Pocket control, gutter mode, footer landmark status, persistence actions, and effective held/latched state with keyboard- and accessibility-operable roles, names, values, and actions while excluding them from the text area's value.

#### Scenario: Accessibility client traverses the shell
- **WHEN** VoiceOver or Full Keyboard Access inspects the window
- **THEN** shell controls have distinct descriptive labels and current values
- **AND** the document text area exposes only canonical document text
- **AND** traversal follows title bar, editor region, and footer in a stable order
