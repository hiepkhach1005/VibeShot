# Project map

## Source of truth

| Topic | Owner document |
| --- | --- |
| User-visible behavior and scope | `docs/PRODUCT_SPEC.md` |
| Components, data flow, technical invariants | `docs/ARCHITECTURE.md` |
| Work order and milestone exit criteria | `docs/IMPLEMENTATION_PLAN.md` |
| Coding/review constraints | `docs/ENGINEERING_RULES.md` |
| Plan/code/test workflow and Definition of Done | `docs/PROCESS.md` |
| Verification matrix | `docs/TESTING.md` |
| Decisions and changes over time | `docs/HISTORY.md` |
| Current state and next action | `docs/PROGRESS.md` |
| External research links | `docs/SOURCES.md` |
| Release signing, notarization, and direct-download runbook | `docs/RELEASING.md` |

## Dependency direction

```text
App + MenuBar
      ↓
CaptureCoordinator
   ↙     ↓       ↘
Capture Overlay Annotation
   \      |       /
      Export
       ↓
Settings + platform adapters
```

Feature code depends on small platform protocols. Pure geometry, annotation models, settings
validation, and encoding policy must remain testable without screen-recording permission.

## Change routing

- Menu click/settings task → `MenuBar/`, `Settings/`; read Product + Architecture.
- Capture/permission/display task → `Capture/`; read Architecture + Testing.
- Selection/toolbar/input task → `Overlay/`; read Product + Architecture + Testing.
- Drawing/text/undo task → `Annotation/`; read Product + Testing.
- Copy/save/format/quality task → `Export/`; read Product + Architecture + Testing.
- Cloud/history task → do not implement from the MVP prompt; first add an approved decision and privacy design.
- Lifecycle/diagnostics task → `Capture/CaptureLifecycleMonitor.swift` and `Support/PrivacySafeMetrics.swift`; keep
  interruption ownership centralized and diagnostics numeric-only.
- Release task → `docs/RELEASING.md` and `scripts/`; do not add credentials or sandbox exceptions.
