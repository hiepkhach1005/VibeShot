# Replace Stale Clipboard Image Implementation Plan

**Implementation status (2026-09-30):** Complete; fake and native pasteboard replacement regressions pass.

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development`; honor the repository planner → coder → tester sequence and apply TDD.

**Goal:** Make every successful VibeShot Copy replace older pasteboard items with the current image.

**Architecture:** Keep composition/encoding off the main actor. Once both image representations are ready, clear the general pasteboard immediately before publishing the current PNG/TIFF item; preserve session/job cancellation checks and clear partial VibeShot data on publication failure.

**Tech Stack:** Swift, AppKit `NSPasteboard`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-29-quality-region-memory-overlay-presentation-design.md`

## Global Constraints

- Prepare all representations before touching the pasteboard.
- Successful Copy leaves one current item with both PNG and TIFF representations.
- Never allow a canceled or obsolete async export to publish after a newer capture starts.
- Use generated image data only; never commit private screenshots.

## Review Focus

- Existing pasteboard items: test two consecutive writes and assert only the second remains.
- Old unrelated clipboard content: seed a unique pasteboard and assert VibeShot Copy replaces it.
- Paired formats: assert PNG and TIFF stay on the same item.
- Encode failure: assert no pasteboard mutation before preparation succeeds.
- Publication failure: assert partial VibeShot contents are cleared and failure is reported.

---

### Task 1: Make clipboard publication replace old items

**Files:**
- Modify: `VibeShot/Export/ExportModule.swift`
- Test: `VibeShotTests/M6ExportTests.swift`
- Update: `docs/PRODUCT_SPEC.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md`, `docs/HISTORY.md`, `docs/PROGRESS.md`

**Interfaces:**
- Consumes: `ClipboardWriter.publish(_:)`, `PasteboardWriting`, `PasteboardAdapter`.
- Produces: a replacement contract for `ClipboardWriter.publish(_:)`; no public API changes.

- [x] **Step 1: Write a red regression test.** Make `PasteboardTransactionSpy` model an array of pasteboard items (append on write, empty on clear). Publish distinct first and second representations through `ClipboardWriter`; assert exactly one item remains and it contains the second PNG/TIFF data.
- [x] **Step 2: Run the focused test and verify it fails.** Run `swift test --filter M6ExportTests`; expected failure: the fake retains two items because publication never clears old contents.
- [x] **Step 3: Implement replacement at the publication boundary.** In `ClipboardWriter.publish(_:)`, call `clearContents()` immediately before `writeRepresentations`; retain the defensive clear and error if writing fails. Update protocol/adapter comments to distinguish preparation from the irreversible replacement commit; keep `PasteboardAdapter` writing both representations into one `NSPasteboardItem`.
- [x] **Step 4: Add a native adapter regression test.** Use `NSPasteboard.withUniqueName()`, seed an older generated item, publish two different generated representations through `ClipboardWriter(PasteboardAdapter(...))`, and assert one item remains with the latest data and both formats.
- [x] **Step 5: Run focused tests and update docs.** Run `swift test --filter M6ExportTests`; expected: clipboard replacement, preparation-before-write, partial-write cleanup, and async cancellation tests pass. Document replacement semantics and the regression test in the source-of-truth docs; record the durable decision and current status.
