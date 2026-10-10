# Engineering rules

## Required invariants

- The application remains menu-bar-only outside capture overlays and system dialogs.
- All top-level capture state changes go through `CaptureCoordinator`.
- Only one active capture session exists. Repeated triggers while busy are ignored or produce feedback.
- Capture source pixels before presenting overlay windows.
- Geometry types must state their coordinate space. No raw cross-layer `CGRect` assumptions.
- Keep the source snapshot immutable and annotations vector-based until compositing.
- Every terminal path restores cursor/event monitors/windows and releases full-resolution buffers.
- Network functionality is prohibited in MVP code unless the user explicitly approves that phase.
- Never persist or log screenshot pixels or annotation text implicitly.
- Lifecycle observation is centralized in `CaptureLifecycleMonitor`; diagnostics may contain only
  fixed stage identifiers and numeric durations/counts/byte estimates, never pixels, annotation text,
  user names, paths, or error payloads.

## Implementation style

- Prefer small Swift types with explicit ownership over singleton-heavy controllers.
- Keep AppKit objects on `@MainActor`; isolate pure geometry/rendering logic for unit tests.
- Wrap system APIs behind narrow protocols only where this enables deterministic tests.
- Avoid third-party packages until a concrete maintenance benefit outweighs supply-chain and binary cost.
- Treat warnings in project-owned Swift code as failures before a milestone is complete.
- Use structured errors with actionable UI messages; do not use `fatalError` for user/system conditions.

## Change discipline

- Implement one milestone or one focused defect at a time.
- Update `docs/PROGRESS.md` whenever a milestone state changes.
- Record durable architectural/product choices in `docs/HISTORY.md`; do not log routine edits there.
- Update `docs/PROJECT_MAP.md` when component ownership moves.
- Add tests in the same change as new pure logic or fixed regressions.

## Code review rules

Flag a change when it:

- Captures overlays, cursor, menu, or VibeShot itself.
- Confuses points and pixels or assumes the primary display origin is `(0, 0)`.
- Breaks negative display coordinates, mixed Retina scales, or display removal.
- Applies lossy quality semantics to PNG/BMP.
- Leaves global event monitors, panels, cursor state, or tasks alive after cancel/error.
- Writes private image/text/path contents to logs or introduces implicit upload.
- Couples annotation preview and export to different geometry/rendering behavior.
- Adds a package for logic that is small, stable, and available in platform frameworks.
