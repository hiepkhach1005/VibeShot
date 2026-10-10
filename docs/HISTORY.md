# Decision and product history

Record durable decisions here. New entries are append-only; if a decision changes, add a superseding
entry rather than silently rewriting history.

## 2026-09-18 — Native macOS menu-bar product

- Status: accepted.
- Decision: VibeShot is a native macOS menu-bar-only utility with temporary capture overlays.
- Reason: this gives direct access to display, window, pasteboard, shortcut, and login-item behavior
  while keeping the common workflow lightweight.

## 2026-09-18 — AppKit-first implementation

- Status: accepted.
- Decision: use AppKit for the status item, overlays, event handling, and editor canvas. SwiftUI may be
  embedded for small isolated views but does not own the capture-window lifecycle.
- Reason: Lightshot-style multi-display overlays and precise mouse/keyboard control map directly to AppKit.

## 2026-09-18 — macOS 14+ and ScreenCaptureKit

- Status: accepted for initial planning; confirm when the Xcode project is created.
- Decision: target macOS 14+ and use ScreenCaptureKit rather than shelling out to `screencapture`.
- Reason: native asynchronous capture, explicit display filtering, testable service boundary, and no
  child-process dependency.

## 2026-09-18 — Local-first MVP

- Status: accepted.
- Decision: upload, account/gallery, and similar-image search are not MVP features.
- Reason: these need backend ownership, authentication, deletion/retention, provider terms, and explicit
  privacy consent. Local capture/edit/export provides the requested core value without those risks.

## 2026-09-18 — Vector annotations until export

- Status: accepted.
- Decision: store annotations as vector commands and composite once for copy/save/print/share.
- Reason: reliable undo/redo, crisp Retina output, editable tools, and consistent preview/export.

## 2026-09-18 — M0 bootstrap identity and local validation

- Status: provisional until release configuration.
- Decision: use `com.vibeshot.VibeShot` as the temporary bundle identifier, macOS 14 as the deployment
  target, and unsigned local builds. Keep the checked-in Xcode project canonical and provide a small
  Swift Package manifest only for fast compiler and unit-test feedback.
- Reason: development can begin without a signing team or final distribution decision while keeping
  the native application and test targets reproducible in Xcode.

## 2026-09-19 — All-or-nothing display snapshot sessions

- Status: accepted for M2.
- Decision: each capture request enumerates and snapshots every active display before any overlay
  work. A missing, failed, or topology-changed display rejects the entire request; the immutable
  in-memory session is handed to the next consumer seam and released on completion/cancel.
- Reason: region selection must operate over one stable multi-display source set and must never show
  a partial or stale desktop.

## 2026-09-19 — M3 single-display selection and session events

- Status: accepted for M3.
- Decision: show one borderless overlay per captured display, but keep each region selection within
  the display where its drag began. Clamp at the display edge, show a visible cross-display hint,
  and retain cross-display selection as a later improvement.
- Decision: handoff consumers report session-ID-tagged selecting/editing/terminal events and expose
  idempotent cancellation. The coordinator owns top-level selecting/editing state and rejects stale
  callbacks.
- Reason: stable per-display point/pixel conversion is safer for the MVP than silently composing a
  cross-display crop, while session IDs prevent late panel callbacks from tearing down a newer capture.

## 2026-09-19 — M4 vector annotation documents and shared preview renderer

- Status: accepted for M4.
- Decision: keep pen, line, arrow, rectangle, and marker values in a lower-left logical canvas;
  render committed items in document order and transient previews last through one Core Graphics
  transform/clip shared by the overlay and future export.
- Decision: selection moves/resizes change only the destination transform. The immutable vectors and
  their original canvas bounds are not rewritten.
- Decision: add/update/delete operations use a reversible indexed command stack; a new command after
  undo clears redo. Last annotation color and stroke width are added as optional version-1 settings
  fields with safe migration defaults.
- Reason: this keeps Retina geometry crisp, makes preview/export parity testable without screen
  permissions, and avoids retaining annotation or source state after overlay teardown.

## 2026-09-19 — M5 value text editing and final local toolbar seams

- Status: accepted for M5.
- Decision: store text as value-based `TextAnnotation`/`TextStyle` data and render multiline text in
  the same canvas transform/clip scope as other vectors. Normalize editor newlines through a pure
  sanitizer and map the editor's destination rectangle back to canvas coordinates on one history add.
- Decision: use one idempotent in-place NSTextView session per overlay. Bare Return commits,
  Shift/Option-Return inserts a newline, Escape cancels text before capture, and focus loss commits
  nonblank text or cancels blank text. Native NSTextView commands remain native.
- Decision: replace temporary controls with a vertical tool/style/undo strip and a typed horizontal
  `CaptureEditorAction` seam. Cancel is wired in M5; copy/save/save-as/share/print stay disabled until
  the M6 export handler exists.
- Reason: this keeps text input isolated from capture shortcuts, preserves vector/export parity, and
  leaves local capture/privacy behavior unchanged while making the toolbar contract ready for M6.

## 2026-09-20 — M6 local export and terminal action policy

- Status: accepted.
- Decision: build one immutable export input from the selected display snapshot, crop through
  `DisplayGeometry`, and composite native-pixel sRGB RGBA output with committed annotations only.
  The same Core Graphics vector/text renderer is used for preview and export; transient gestures
  are never persisted to output.
- Decision: copy/save success closes; save cancellation/errors retain; print closes only after the
  print operation is accepted/completed; share closes only from the sharing delegate's success
  callback. All actions are single-flight behind an exporting phase/re-entry guard.
- Decision: Image I/O is selected by the format's UTType. PNG/BMP remain lossless, JPEG/HEIC alone
  receive quality, JPEG/BMP flatten alpha against white, and unavailable HEIC support is reported
  instead of silently falling back. Clipboard writes PNG and a TIFF compatibility representation.
- Decision: recent folders retain a versioned optional security-scoped bookmark with a legacy path
  fallback. Access is balanced, and the app remains unsandboxed for the current MVP. Save writes
  are atomic and default names gain collision-safe numeric suffixes.
- Reason: these boundaries preserve source pixels, avoid accidental data loss during system UI,
  and keep export behavior deterministic and locally testable without adding cloud functionality.

## 2026-09-20 — M7 lifecycle hardening and direct-download baseline

- Status: accepted for release preparation.
- Decision: one `CaptureLifecycleMonitor` owns display topology, Space, app deactivation, sleep/wake,
  memory-pressure, and permission-revocation interruption signals. It emits at most one cancellation
  request per monitored capture; the coordinator owns the transition to idle. Deactivation is ignored
  only while VibeShot owns save/print/share UI; topology, Space, sleep/wake, memory, and permission
  changes always tear down the session.
- Decision: local diagnostics use fixed-stage os_log signposts with durations, counts, and estimated
  or resident byte counts only. No pixels, annotation text, user names, paths, or error strings are
  accepted by the metrics sink, and the unit tests can inject a no-op sink.
- Decision: the MVP release target is a Developer ID signed/notarized direct download. Hardened
  runtime is enabled with an empty entitlements file and App Sandbox remains disabled; no runtime
  exceptions are carried forward.
- Decision: release automation validates the configured Developer ID name against the local
  `security find-identity` result, checks a notary profile with a non-submitting `notarytool history`
  query, and verifies the signed runtime flag plus an absent-or-empty entitlements payload. The
  notarization archive lives only in a unique temporary directory and is removed by a scoped trap.
- Reason: central ownership prevents duplicate observers and stale overlay teardown, while a local
  privacy-safe diagnostic envelope gives release profiling a bounded signal without adding network
  telemetry or changing the local-first product boundary.

## 2026-09-21 — Copy preparation leaves the main actor

- Status: accepted.
- Decision: compose copy output and encode its PNG/TIFF representations through a Sendable,
  injectable value-only preparation seam on a detached worker. Keep the NSPasteboard item write on
  the main actor, after session and export-job identity checks. Cancellation and replacement
  invalidate the job before publication; only a current successful copy closes its editor.
- Reason: large Retina selections can make Core Graphics composition and Image I/O expensive.
  Separating preparation from the AppKit transaction preserves responsive overlay interaction and
  prevents stale background work from mutating a newer capture's clipboard or lifecycle.
# 2026-09-23 — Export UI visibility and emergency exit

Native probes established that screen-saver-level capture overlays obscure normal NSAlert/NSSavePanel
windows. Export-owned UI now hides every overlay and restores only the same retained session. Save
uses asynchronous panel completion and background immutable encoding/file work; Copy owns worker
cancellation. Escape now cancels the entire session, superseding text-first cancellation, and a
session local monitor routes Command+Q through focused controls. A conservative 30-second active-
session watchdog exits VibeShot on a sustained main-thread stall, using a sleep-excluding clock and
locked generation/disarm guard. Emergency exit loses unsaved work. The original reported Copy error
has not been identified; this change fixes independently verified lockout paths.

## 2026-09-29 — Escape through the native Save panel

- Status: verified on the signed macOS UI test target.
- Decision: register an unmodified Escape Carbon hotkey only while a capture session is active.
  The native Save panel can own keyboard focus outside VibeShot, so its Escape event does not
  reliably reach an AppKit local monitor. The session hotkey cancels the whole capture; clicking
  the panel's Cancel button still restores the editor. Unregister on every terminal path.
- Decision: the DEBUG generated capture accepts an existing test-owned save directory through
  in-memory settings. The signed UI test uses the real Save panel and export writer, then decodes
  the resulting PNG and checks its pixel dimensions without persisting a user preference.

## 2026-09-30 — Current Copy, fixed quality, and optional remembered geometry

- Decision: Copy clears the pasteboard only after PNG and TIFF are prepared, then publishes one
  current item. `NSPasteboard.writeObjects` appends, which explained the stale first image.
- Decision: app exports always request quality 100. The legacy settings key remains readable but
  normalizes to 100; the menu presents a static label. PNG/BMP remain lossless.
- Decision: settings v4 optionally stores normalized rectangles by persistent display UUID, never
  screenshot pixels or annotations. The pointer is sampled at capture-request acceptance and only
  that display's completed region is restored. Disabling the option clears records atomically.
- Finding: the reported capture-start expansion still needs a direct default-versus-no-animation
  visual comparison before changing overlay presentation code.
- Review repair: restored selections now keep initial keyboard focus on their pointer display;
  the previous unconditional last-display focus could send shortcuts to the wrong overlay.
