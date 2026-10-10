# SDD ledger — plan: docs/superpowers/plans/2026-09-29-replace-stale-clipboard-image.md

Implementation: complete. Append-aware fake test failed before fix (two items, stale first image), then passed after clearing at publication boundary. Native unique-pasteboard replacement test and M6ExportTests passed. Clipboard cancellation/session guards retained.

Workspace note: `sdd-workspace` failed because this directory is not a Git repository; no worktree, base commit, or generated Git review package is available. The user explicitly requested implementation in this workspace. Baseline of named source/test/docs files is archived at `/tmp/vibeshot-baseline.kvKfhm/baseline.tar`; keep edits limited to approved plans and review against this baseline.

## Pre-flight scan and rulings

| Pair | Shared files/interface | Finding | Ruling |
|---|---|---|---|
| Clipboard Task 1 × Quality Task 2 | `ExportModule.swift`, `M6ExportTests.swift` | Both touch export module/tests but distinct copy-publication vs encoder-quality paths. | Execute sequentially; retain fixed-quality constant when changing clipboard code. |
| Clipboard Task 1 × Quality Task 1 / Remembered-region Task 3 / Animation Task 1 | Product, architecture, testing, history, progress docs | Shared source-of-truth docs require coherent combined updates. | Update docs after behavior is implemented; do not overwrite earlier feature decisions. |
| Clipboard plan self-check | `PasteboardWriting`, `ClipboardWriter.publish`, `PasteboardAdapter` | The pasteboard clear is destructive and cannot restore another app's former contents. | Prepare PNG/TIFF first, clear only at publish boundary, report failure and clear partial VibeShot data as the approved spec requires. |

## Tasks

- Task 1: pending. No app edits yet.
- Test strategy: append-semantics fake plus unique native pasteboard regression; focused export tests before broader gates.
