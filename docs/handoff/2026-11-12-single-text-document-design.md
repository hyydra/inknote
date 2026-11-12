# One global text document per note

Design record, 2026-11-12. Approved by the user before implementation
("disable textbox, one global text document"), with three follow-up choices
taken from the same conversation.

## Problem

A note is a pile of numbered text boxes. Each one has its own position, size,
font, colour and bold state, and the only way to get more writing room is to
press "Add text block" again. On a page of paper that is backwards: one
document grows as you write, and the sheet is what moves, not the paragraph.

## Decisions

- **Text layer stays interactive.** The document is still live text on the
  canvas - visible, selectable, typeable, formatted. What goes away is the
  many-box model, not the text.
- **Concatenate into one doc, migrate on save.** A note's existing blocks join
  in order and the per-block records are dropped the next time that note is
  saved. Nothing is rewritten behind the user's back.
- **Fixed column at the top.** The document always starts at the top-left of
  page 1 in a column that spans the page width, and grows downward. There is no
  x, y, width or height to store, so there are no drag or resize handles and no
  per-block frames.

## Data model

`Note` loses `textBlocks` and `textBlockFormats` and gains one document:

```dart
class TextDocumentFormat {
  bool bold;             // default style for new text
  int color;
  double fontSize;
  List<TextStyleRange> styles;   // document-relative offsets
}

class Note {
  String text;                  // the whole document
  TextDocumentFormat textFormat;
}
```

`TextStyleRange`, `TextBlockFormat` and the `styles` lists inside them stay
where they are. `TextBlockFormat` keeps existing, but only as the type the
legacy reader decodes into.

`currentFormatVersion` stays **7**. Bumping it would make `drive_sync_service`
silently drop every remote note written by the new build (its `catch (_)`
around `Note.fromJson`) and `note_store` rename unreadable primaries to
`*.corrupt-<timestamp>`. The new `'textFormat'` key is additive and old builds
ignore unknown keys.

## Reader and writer

Reading is dual-shape, and the choice is made once per file:

1. `textBlocks` present and non-empty -> old shape. Join with `'\n\n'` and
   build the document format from the blocks.
2. otherwise -> read `'text'` and `'textFormat'`.

Writing is single-shape: `'text'` plus `'textFormat'`, no block arrays.

The migration converts block state into document state:

- Document offset of block *i* = `sum(len(block_j) + 2 for j < i)` (the
  `'\n\n'` separators).
- The document's default bold/colour/size come from the first block.
- Every block whose defaults differ from the document's contributes one
  `TextStyleRange` over its whole span, shifted by its offset.
- Each block's own `styles` are copied with the same shift applied.
- Empty blocks contribute no range.

An old-shape note opened by an old build after a new save falls back to
`value['text']`, so it shows the whole document in one default box. Degraded,
not lost.

## Interaction

One `RichTextEditingController`, one `FocusNode`, one `TextDocumentFormat` held
by the editor - `TextBlockController` and its test are deleted, and
`activeTextIndex` disappears with it.

| Pointer lands on | Text tool | Drawing tool |
|---|---|---|
| the document's own area | the field handles it: caret, selection, drag | glyph lines activate the document and place the caret where the tap landed; misses draw (v0.4.20 rule, kept) |
| anywhere else on the canvas | focus the document, caret at the end | draw |

`IgnorePointer(ignoring: tool != DrawTool.text)` replaces the per-block
`activeTextIndex` gate, so a pen stroke can still cross live text.

The v0.4.20 exception - an empty block opens on a tap anywhere in its frame -
goes away with the frames: an empty document has no glyphs, so a blank page is
paper for every tool.

The toolbar loses "Add text block"; the canvas loses the move handle, the
resize handle, the delete button and the "Text block N" hint. The Text tool in
the bottom drawing toolbar stays, and it is how an empty page is entered.

Growth: the field sizes to its content inside the fixed column width
(`canvasWidth` minus the page margins), and when the laid-out document reaches
the bottom of the last page, `_growPagesForDocument()` appends pages with the
same threshold the scroll rule already uses (`pageCount * canvasPageHeight -
180`). A long note therefore pushes the page count up as it is typed.

## Testing

`widget_test/` is not run by bare `flutter test`; CI runs
`flutter test widget_test/editor_gesture_test.dart` explicitly, so both suites
have to be touched in the same change.

New unit coverage in `test/note_data_test.dart`: old-shape JSON decodes to the
concatenated document; the separator arithmetic; per-block defaults becoming a
shifted range; a block's own styles shifted; new-shape round trip; an
old-shape file saved once and re-read producing the same document.

Widget specs removed: "tapping the canvas adds text at that position",
"multiple transparent text blocks can be added", "a text block can be moved and
resized on the canvas", "text reflows when a text block is resized narrower",
"tapping an empty text block still opens it for editing". Specs rewritten onto
the single document: the five glyph-precision specs keep their
`canvas-text-block-0` / `canvas-text-field-0` keys and move their taps up by the
28 pixels of title strip that no longer exists, "legacy drawing migrates
beneath text blocks" loses the plural, and the block-growth spec becomes "a long
document appends pages as it grows".

README lines describing typed text blocks are rewritten.

## Out of scope

- The finger-scroll design ("finger scrolls, stylus draws") - presented, never
  approved.
- The home-screen widget resize fix, still awaiting a device observation.
- Dead modules `lib/autosave_controller.dart` and `lib/canvas_editing.dart`,
  and the stale README claims at lines 22 and 29.
