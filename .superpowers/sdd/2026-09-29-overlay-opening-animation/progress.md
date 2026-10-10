# SDD ledger — plan: docs/superpowers/plans/2026-09-29-overlay-opening-animation.md

Investigation remains unconfirmed. Current overlay is ordered with `makeKeyAndOrderFront` and no explicit animation behavior. Automated/property checks cannot establish the user's observed expansion. No default-versus-`.none` cold/warm visual A/B comparison was available in this agent session, so production animation code was intentionally left unchanged; direct macOS comparison is still required.

Workspace note: `sdd-workspace` failed because this directory is not a Git repository; no worktree, base commit, or generated Git review package is available. The user explicitly requested implementation in this workspace. Baseline of named source/test/docs files is archived at `/tmp/vibeshot-baseline.kvKfhm/baseline.tar`; keep edits limited to approved plans and review against this baseline.

## Pre-flight scan and rulings

| Pair | Shared files/interface | Finding | Ruling |
|---|---|---|---|
| Animation Task 1 × Remember Task 3 | `OverlayWindowController.swift`, architecture/testing/history/progress docs | Region restoration changes pre-show state; `.none` experiment changes only ordering animation. | Run after region implementation; preserve behavior and change animation only with direct visual evidence. |
| Animation plan self-check | Temporary `.none` property test vs conditional production change | If no reproducible visual result, a permanent test asserting the experiment would contradict the approved unresolved outcome. | Add property test only if `.none` is retained; otherwise preserve production code and document the manual-observation limitation. |

## Tasks

- Task 1: pending; baseline/default-vs-none visual observation has not yet been possible.
- Decision gate: no production animation change without same-path visual comparison and input/display regression checks.
