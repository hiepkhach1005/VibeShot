# SDD ledger — plan: docs/superpowers/plans/2026-09-29-fix-image-quality-100.md

Implementation: complete. Settings/menu tests showed legacy quality and slider failures before fix; fixed 100 normalization and static menu passed. Sync/async encoder spy covers nil and unvalidated legacy settings. Low-level encoder policy remains parameterized.

Workspace note: `sdd-workspace` failed because this directory is not a Git repository; no worktree, base commit, or generated Git review package is available. The user explicitly requested implementation in this workspace. Baseline of named source/test/docs files is archived at `/tmp/vibeshot-baseline.kvKfhm/baseline.tar`; keep edits limited to approved plans and review against this baseline.

## Pre-flight scan and rulings

| Pair | Shared files/interface | Finding | Ruling |
|---|---|---|---|
| Quality Task 1 × Quality Task 2 | `StatusItemController.swift`, `VibeShotTests.swift`, `ExportModule.swift`, `M6ExportTests.swift` | Task 1 owns settings/menu and Task 2 owns export inputs; the fixed constant flows from Task 1 to Task 2. | Implement settings/menu first; preserve generic low-level encoder tests while all app-facing routes use 100. |
| Quality plan × Clipboard Task 1 | `ExportModule.swift`, `M6ExportTests.swift` | Separate publication and encoding paths share test/module ownership. | Keep edits scoped and sequential. |
| Quality Task 1 × Remembered-region Task 1/3 | `SettingsModule.swift`, `StatusItemController.swift`; shared product/architecture/testing/progress docs | Fixed quality and v4 preference migration touch the same settings/menu/docs. | Apply v4 region changes after quality normalization and ensure migration/validation cannot reintroduce a non-100 quality. |
| Quality plan self-check | Legacy `imageQuality` key vs fixed app behavior | Persisted field remains for compatibility but must normalize to 100. | Retain key and force constant in default/decode/validate/export; leave encoder policy generic. |

## Tasks

- Task 1: pending.
- Task 2: pending; depends on Task 1's constant.
- Test strategy: focused settings/menu and export tests, then `swift build`, `swift test`, and validation script.
