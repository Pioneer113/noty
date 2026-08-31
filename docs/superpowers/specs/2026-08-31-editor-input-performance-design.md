# Editor Input Performance and Caret Stability Design

Date: 2026-08-31

## Problem

Typing in the main note editor is visibly sluggish and the caret can appear to
move away from the insertion point. The regression is concentrated in
`NoteTextView` and was introduced with live Markdown styling:

- Every `textDidChange` call clears and reapplies attributes across the entire
  document.
- All Markdown regular expressions scan the entire document on every edit.
- The complete glyph cache and layout are invalidated after every edit.
- The selection is explicitly written back after every style pass.
- Cursor-rectangle rebuilding enumerates every line in the document.
- The same work can run while an input method owns marked text.

The cost therefore grows with total note length rather than with the text being
edited. Rewriting selection and layout during marked-text composition also
interferes with AppKit's caret and candidate-window bookkeeping.

## Goals

1. Keep direct typing responsive in short and long notes.
2. Keep the logical selection and visible caret stable during ordinary typing,
   selection movement, undo/redo, paste, and Chinese IME composition.
3. Preserve current behavior: live Markdown, hidden markers outside the active
   line, task checkboxes, task Return handling, find, configurable fonts and
   colours, and 250 ms autosave.
4. Apply the improvement to both the edge note editor and the Library editor,
   which share `NoteTextView`.
5. Make edit-time work proportional to the affected paragraphs. A multi-line
   paste may cost proportionally to the pasted range, but a one-character edit
   must not scan or relayout the full note.

## Non-goals

- Changing Markdown syntax or rendering.
- Replacing TextKit 1 or the hidden-glyph mechanism.
- Redesigning persistence, encryption, or the note UI.
- Adding background parsing; AppKit text storage and layout remain main-thread
  objects.

## Approaches considered

### 1. Debounce the existing full-document restyle

This is the smallest change and removes repeated work during a burst of typing.
It still produces a full-document pause when the debounce fires, delays visible
formatting, and can still disturb the caret. It does not meet the stability goal.

### 2. Incremental paragraph styling with IME protection — selected

Capture the actual character edit, expand it to the affected complete
paragraphs, and update attributes and layout only in that range. Defer all style
work while `NSTextView` has marked text. This preserves the existing live
editing model while removing the two root causes: document-wide work and
selection writes during input.

### 3. Disable Markdown styling while the editor is focused

This provides a fast plain-text editing path but changes the product behavior
and makes formatting jump on focus changes. It is unnecessary once styling is
incremental.

## Design

### 1. Separate styling from event coordination

Extract the attribute and Markdown work into a focused `EditorStyleEngine`.
The engine will:

- own precompiled regular expressions rather than compiling seven expressions
  per keystroke;
- clamp and expand character edits to safe complete-line ranges, including the
  adjacent character needed to handle newline insertion and deletion;
- reset and apply base, Markdown, and completed-task attributes only inside the
  requested range;
- reveal Markdown markers only on the supplied active line;
- invalidate glyphs and layout only for the range whose attributes changed;
- refresh base `typingAttributes` after a committed incremental pass so the
  next character cannot inherit a stale heading or code font;
- never mutate the underlying string or the text view's selection.

A full-document entry point remains for initial setup, external content
replacement, font changes, colour changes, and the Markdown setting changing.
Those are configuration transitions, not the normal typing path.

### 2. Make the coordinator own edit transactions

`NoteTextView.Coordinator` will conform to `NSTextStorageDelegate` in addition
to `NSTextViewDelegate`. It will record only `.editedCharacters` ranges and
ignore attribute-only edits created by the style engine. Multiple edits are
kept as a small normalized range set; only overlapping or adjacent ranges are
merged. This avoids accidentally styling all text between two distant edits.

The coordinator will also be refreshed from each `updateNSView` call instead of
retaining the first immutable `NoteTextView` value forever. This keeps the
binding, ink, font size, and configuration current without recreating the native
editor.

Normal edit flow:

1. TextKit changes characters and reports the edited range.
2. The coordinator publishes the current plain string through the binding so
   the existing autosave flow remains intact.
3. If the view has marked text, the coordinator retains the dirty range and
   performs no attribute, layout, cursor-rectangle, or selection operation.
4. When composition commits, the coordinator consumes the accumulated dirty
   range, expands it to complete affected lines, and applies incremental styles.
5. The current `selectedRange` is left entirely under AppKit's control.

The coordinator uses a reentrancy guard while applying attributes. This is a
defence in depth measure in addition to ignoring attribute-only storage edits.

### 3. Handle caret-line marker visibility incrementally

Moving the caret between lines changes which Markdown punctuation is visible.
The coordinator will remember the previous active line and restyle only the
previous and new active lines as two independent ranges when they are not
adjacent. It will skip this work while marked text exists. It will not call
`setSelectedRange` after a style-only change.

After a character edit, the stored active-line range is recalculated because
insertions and deletions can shift later locations. All ranges are clamped to
the current UTF-16 string length before use.

### 4. Restrict custom cursor work to visible text

`TaskTextView.resetCursorRects` currently enumerates every line. It will derive
the character range intersecting `visibleRect`, expand that range to complete
lines, and create checkbox cursor rectangles only there. Character edits may
still invalidate cursor rectangles, but rebuilding them will be bounded by the
visible viewport rather than total note length.

### 5. Keep external synchronization explicit

`updateNSView` will distinguish native user edits from an actual external
binding replacement:

- Equal strings require no assignment or restyle.
- Marked text is never overwritten by a SwiftUI update.
- A genuine external replacement may assign `tv.string`, clamp the old
  selection to the new length, and perform one full style pass.
- Font, ink, or Markdown configuration changes perform one full attribute pass
  without rewriting selection.

The Markdown-enabled value will be an explicit editor input and part of the
coordinator's configuration snapshot. This makes a setting transition
detectable without consulting mutable global state from inside a style pass.

Initialization installs delegates only after the initial string and full style
pass so setup does not leave a false pending edit.

## Edge cases and failure handling

- Empty strings and zero-length deletion ranges are valid and are clamped
  before line expansion.
- Deleting or inserting a newline includes both sides of the boundary so stale
  line styles cannot survive a merge or split.
- Multi-line paste, replacement, undo, and redo style every affected line once.
- Task insertion, checkbox toggling, and task-list Return use the same character
  edit pipeline; no special full restyle is needed.
- With Markdown styling disabled, incremental passes still apply base and task
  attributes but do not create hidden-marker attributes.
- If an edit range cannot be recovered, the safe fallback is one full style
  pass after marked text has ended. The fallback still must not set selection.
- All editor callbacks and styling remain on the main thread, matching AppKit's
  threading contract.

## Verification

### Automated checks

Add focused tests around the production range and style engine:

- one-character edits expand only to their affected line;
- newline insertion/deletion and multi-line replacement include every affected
  line without escaping into unrelated text;
- scoped styling does not alter characters or attributes outside the requested
  range;
- all supported Markdown and completed-task attributes remain correct;
- empty and UTF-16-heavy content (emoji and CJK) produces valid ranges;
- a style-only operation leaves an `NSTextView` selection unchanged;
- marked-text handling accumulates dirty ranges and does not invoke the engine
  until composition ends.

The repository has no existing test target, so implementation will add
`Tests/EditorStyleEngineTests.swift` plus `scripts/test-editor.sh`. The script
will compile a small command-line AppKit assertion harness with the same macOS
SDK, deployment target, architecture, and Swift language mode as `build.sh`.
The harness will compile and exercise the production style-engine source rather
than a copied implementation.

### Build checks

- `./build.sh debug`
- `./build.sh release`

Both must succeed with the Command Line Tools JDK-independent Swift toolchain.

### Runtime checks

1. Type continuously at the beginning, middle, and end of a long note containing
   Markdown and tasks. Characters must appear under the caret without visible
   pauses or horizontal/vertical caret jumps.
2. Compose and choose Chinese text through an IME. Marked text and the candidate
   window must remain anchored, and styling must appear after commit.
3. Move the caret across formatted lines; markers must reveal on the active line
   and hide on the old line without changing the logical selection.
4. Exercise paste, undo/redo, task toggle, task Return, find, font/colour changes,
   and Markdown on/off.
5. Repeat direct typing in the Library editor.

For a long-note probe, the test harness will ask the production range planner
for the ranges produced by a single-character edit and assert that their total
length is limited to the touched paragraphs rather than the full document.
This structural measurement is the primary performance gate; subjective
smoothness is a secondary runtime check.

## Acceptance criteria

- The edit-time path contains no full-document regex scan, attribute reset,
  glyph invalidation, layout invalidation, or cursor-line enumeration for a
  one-character edit.
- No normal edit or selection-only style pass calls `setSelectedRange`.
- No style or layout operation runs while `hasMarkedText()` is true.
- Existing editor features and autosave behavior remain functional in both
  editor surfaces.
- Automated checks, debug build, release build, and the runtime scenarios above
  pass.
