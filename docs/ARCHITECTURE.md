# Architecture

## Technology choices

- Swift 6 language mode where supported by the selected Xcode version.
- AppKit application lifecycle with `NSStatusItem` and temporary `NSPanel` overlays.
- ScreenCaptureKit for screenshots; Core Graphics and Image I/O for geometry and encoding.
- ServiceManagement `SMAppService.mainApp` for Launch at Login.
- `UserDefaults` behind a typed settings store for preferences.
- Carbon `RegisterEventHotKey` behind `GlobalShortcutService` for configurable global shortcuts
  without requiring Accessibility/Input Monitoring permission.
- XCTest/Swift Testing for logic; XCTest UI/manual matrix for system integrations.
- Avoid third-party dependencies for the first milestone. Reassess a maintained shortcut package only
  if native global shortcut registration becomes the dominant maintenance risk.

## Runtime component map

```text
VibeShotApp / AppDelegate
  ├─ StatusItemController ── right-click ── SettingsStore / LoginItemService
  │                     └── left-click ───┐
  ├─ GlobalShortcutService ────────────────┤
  └─ CaptureCoordinator (state machine) ◄──┘
       ├─ CaptureLifecycleMonitor ── topology / Space / sleep / memory / permission
       ├─ PermissionService
       ├─ ScreenCaptureService ── ScreenCaptureKit
       ├─ OverlayWindowController[] ── one per captured display
       │    ├─ SelectionController
       │    └─ CaptureOverlayView (snapshot + dim/undim + handles)
       ├─ AnnotationDocument / AnnotationCommandStack
       ├─ CompositeRenderer
       └─ ExportCoordinator
            ├─ ClipboardWriter
            ├─ ImageFileEncoder
            ├─ SavePanelService
            ├─ PrintService
            └─ ShareService
```

## Capture state machine

```text
idle
 └─ requestCapture → checkingPermission
      ├─ denied → permissionRequired → idle
      └─ granted → snapshotting → consuming → selecting → editing
                                      │           ├─ copy/save/print/share → exporting → idle
                                      └─ cancel ──┴───────────────────────────────→ idle
```

Only the coordinator changes top-level state. Services return values/errors and must not independently
open or close overlays. Reject capture requests while not idle rather than stacking sessions.
The session consumer reports `selecting`, `editing`, and terminal events tagged with the active
session UUID; cancellation is idempotent so stale callbacks cannot close a newer session.

## Coordinate spaces

Use explicit value types and conversion APIs; never pass an unlabeled `CGRect` between layers:

- `GlobalScreenRect`: AppKit global coordinates in points, origin semantics documented.
- `DisplayLocalRect`: points relative to an `NSScreen`.
- `ImagePixelRect`: integer pixel coordinates in a captured `CGImage`.
- `CanvasRect`: logical coordinates relative to the chosen region.

`DisplayGeometry` owns conversion using display frame, backing scale, captured image dimensions, and
vertical-axis flipping. Add round-trip unit tests for displays left/above the primary display and mixed
scale factors. Round outward during capture cropping to avoid losing edge pixels; clamp to image bounds.

## Capture pipeline

1. Enumerate active displays and map `NSScreen` to `SCDisplay` identifiers.
2. Capture every active display before creating overlays; any missing/failed display rejects the
   entire request.
3. Hand one immutable, session-scoped snapshot set to the next consumer seam. M3 creates one
   borderless, transparent, high-level panel per display using the captured bitmap as its stable
   background, building all panels before showing any of them.
4. Track drag events in global point space and convert through `DisplayGeometry`. M3 clamps a region
   to the display where the drag began and shows a cross-display limitation hint.
5. Crop source pixels only for preview/export; keep the original display snapshot for selection edits.
6. Exclude VibeShot windows/process content when the API path supports filters.

## Annotation model

Use immutable lower-left canvas value objects conforming to the shared Core Graphics rendering
contract:

- `FreehandStroke(points, style)`
- `LineAnnotation(start, end, style)`
- `ArrowAnnotation(start, end, style)`
- `RectangleAnnotation(rect, style)`
- `HighlightAnnotation(points, style)`
- `TextAnnotation(origin, bounds, attributedText, style)`

`AnnotationDocument` contains ordered annotations and transient in-progress content. An explicit
indexed command stack applies reversible add/update/delete commands and supports undo/redo with redo
invalidation after new edits. `AnnotationRenderer` applies one canvas transform and clip, draws
committed order followed by transient content, and is shared by the overlay preview and future
bitmap compositor to prevent export drift. Selection moves/resizes change the destination transform;
they do not mutate stored vectors.

## Menu and settings

`StatusItemController` inspects the current mouse event: left mouse-up requests region capture; right
mouse-up presents an `NSMenu`. Image quality is a static 100% label; Remember Last Region is a
checkable option.

`AppSettings` includes shortcut definitions, launch-at-login observation, output format, fixed quality,
save destination policy, last folder bookmark if sandboxing requires it, last color, and stroke width.
Validate persisted values and fall back safely when decoding older settings.

Settings schema v4 retains the legacy quality key but normalizes it to 100. Optional remembered regions
contain only normalized display-local rectangles keyed by persistent CoreGraphics display UUID. The
coordinator samples the pointer when it accepts a capture request; the consumer restores only that
display's rectangle before showing panels. Selection completion writes geometry once, including
move/resize and region Command+A; annotation changes and full-screen capture do not write it.

Shortcut replacement is atomic: register the new shortcut first, keep the previous shortcut if
registration fails, reject modifier-only input, and surface conflicts without requesting Accessibility.

## Concurrency and lifecycle

- UI, overlays, and coordinator state are `@MainActor`.
- Capture and encoding APIs may complete off-main; marshal UI changes to the main actor.
- Use cancellation-aware tasks tied to the active capture session identifier. `CaptureLifecycleMonitor`
  is the single owner of topology, Space, sleep/wake, memory-pressure, app-deactivation, and
  permission-revocation observers; it emits one interruption per active request and the coordinator
  performs the idempotent cancel-to-idle transition. Export-owned save/print/share UI is the only
  app-deactivation exception.
- Export actions are
  single-flight; resign-active cancellation is ignored only while VibeShot owns a save/print/share
  system UI, while display-topology changes still tear down the session.
- Tear down event monitors, cursor state, panels, and temporary buffers on every terminal path.
- Keep only one full-resolution snapshot set in memory and release it immediately after export/cancel.
- The overlay consumer owns a session-scoped system-UI boundary: hide all high-level panels before
  native dialogs, synchronize lifecycle ownership, and restore only the same retained session.
  Sharing uses a separate visible normal-level host. A session-scoped Carbon Escape hotkey reaches
  the capture even when an out-of-process native Save panel owns keyboard focus; the local key
  monitor also handles Escape and Command+Q in app-owned controls. Teardown unregisters the hotkey
  and removes both key and mouse monitors. Explicit Save panel Cancel restores the editor.
- Save uses retained `NSSavePanel.begin` completion and a cancellable detached immutable worker for
  composition, encoding, and atomic file I/O. Copy propagates task cancellation to its detached worker.
  The clipboard writer prepares PNG/TIFF before clearing and replacing existing pasteboard items.
  Session/job checks guard publication; cancellation checks guard the file commit boundary.
- `CaptureStallWatchdog` arms only while an overlay session exists. A main-run-loop timer beats in
  common/default/event-tracking/modal modes; a background timer checks a locked generation using
  sleep-excluding Mach absolute time. After 30 seconds without a beat it exits only this process.
  Disarm and the final exit decision serialize under the same lock. The exit function and clock are
  injectable; no screenshot/text/path content is recorded.

## Suggested source layout

```text
VibeShot/
  App/
    VibeShotApp.swift
    AppDelegate.swift
  MenuBar/
    StatusItemController.swift
    StatusMenuBuilder.swift
  Capture/
    CaptureCoordinator.swift
    CaptureState.swift
    PermissionService.swift
    ScreenCaptureService.swift
    DisplayGeometry.swift
  Overlay/
    OverlayWindowController.swift
    CaptureOverlayView.swift
    SelectionController.swift
    SelectionHandles.swift
    CaptureToolbarController.swift
  Annotation/
    Annotation.swift
    AnnotationDocument.swift
    AnnotationCommand.swift
    AnnotationCanvasView.swift
    Renderers/
  Export/
    CompositeRenderer.swift
    ImageFileEncoder.swift
    ClipboardWriter.swift
    SavePanelService.swift
    PrintService.swift
    ShareService.swift
  Settings/
    AppSettings.swift
    SettingsStore.swift
    LoginItemService.swift
    GlobalShortcutService.swift
  Support/
    AppError.swift
    Logger.swift
VibeShotTests/
VibeShotUITests/
```

M3 also defines a pure `ToolbarLayoutEngine` seam for later annotation controls; it does not create
toolbars or annotation state. Exact group/project paths may change when the Xcode project is created;
component boundaries and ownership should remain stable unless recorded in `HISTORY.md`.
