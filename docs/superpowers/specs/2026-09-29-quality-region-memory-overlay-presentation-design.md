# VibeShot quality, remembered region, and overlay presentation design

**Status:** Approved for implementation  
**Date:** 2026-09-29

## Goal

Make exported image quality consistently 100%, optionally restore the last region selection on the next region capture, make Copy replace stale clipboard images, and investigate/fix the brief screen flicker without introducing unverified workarounds.

## User-visible behavior

### Image quality

- Image quality is fixed at 100% for VibeShot exports; users cannot change it in the menu.
- Replace the quality slider with a static `Image Quality: 100%` menu item. Its tooltip may explain that PNG/BMP do not use lossy quality settings and JPEG at 100% is still a lossy format.
- Existing saved settings that contain another quality value are normalized to 100 on load/validation. Export paths also use 100 even when a settings store is absent or contains legacy data.
- Keep the encoder policy capable of accepting a quality value for focused low-level tests; the app-facing settings/menu/export contract is fixed at 100.

### Remember Last Region

- Add a checkable `Remember Last Region` menu option, off by default.
- When enabled, persist the most recently completed region rectangle per display and restore it as an editable selection for the next region capture on that display. It remains enabled across app launches.
- Save only normalized rectangle geometry, not screenshots, pixels, annotations, text, or clipboard contents. Store geometry relative to display-local bounds so it can be restored after resolution or scale changes.
- Identify a display with its persistent CoreGraphics display UUID. If no UUID is available or the matching display is absent, start with no restored region; do not apply another display's rectangle.
- For a capture session, restore at most one rectangle: use the display containing the pointer when the capture request is accepted (capture the pointer location before asynchronous screen snapshots begin), falling back to the first available display if the pointer is outside the display topology. Full-screen capture ignores remembered-region state.
- Persist after a region selection is completed or changed by moving/resizing it, and after the region command selects the whole display. Do not write on every drag event or for annotation-only changes. Canceling the capture does not erase the last completed region.
- Turning the option off clears all remembered rectangles atomically. Turning it on later starts empty; it must not resurrect cleared data.
- Validate loaded geometry (finite values, positive dimensions, normalized bounds). Clamp valid restored geometry to the current display bounds and honor the existing minimum selection size. Malformed records are discarded without resetting unrelated settings.
- A settings write failure must leave the user's capture/editing interaction usable and must not falsely show the option as saved.

### Copy always publishes the current capture

- Each successful Copy replaces the general pasteboard contents with exactly one item containing the current capture's PNG and TIFF representations. Repeated copies must never leave an older VibeShot image ahead of the latest one.
- Root cause identified in the current adapter: `PasteboardAdapter.writeRepresentations` calls `NSPasteboard.writeObjects([item])` without clearing the pasteboard first. Apple's [`declareTypes` discussion](https://developer.apple.com/documentation/appkit/nspasteboard/declaretypes%28_%3Aowner%3A%29?language=swift) explains that `writeObjects(_:)` adds items without changing existing ones; consumers that read the first matching image can therefore receive the image from the first Copy instead of the latest one. Use [`clearContents()`](https://developer.apple.com/documentation/appkit/nspasteboard/clearcontents%28%29?changes=_7%2C_7) before writing the new item, and retain the existing clear-on-write-failure behavior.
- Treat pasteboard replacement as a destructive commit boundary: AppKit does not provide rollback to another app's former clipboard item after it is cleared. Continue to fully prepare PNG/TIFF data before clearing; if publication fails, report failure and leave no partial VibeShot payload.
- Keep session/export identity checks in place so a canceled or obsolete asynchronous copy cannot publish after a newer capture starts.

### Capture-start flicker

- The user's observation is that the transition looks like macOS windows “expanding” into view. This makes AppKit's automatic window-ordering animation the first hypothesis to test, rather than assuming the screenshot capture or dimming renderer is flashing.
- The overlay panel uses `makeKeyAndOrderFront`, and the current code does not set `animationBehavior`. Apple documents `.default` as automatic behavior inferred from the window type and `.none` as disabling AppKit's automatic ordering animation. This is evidence that an animation may be involved, but does not establish which visual effect macOS chooses for this borderless panel.
- Compare the current/default behavior with `NSWindow.AnimationBehavior.none` on capture overlay panels, using the same real ScreenCaptureKit capture and cold/warm starts. Also compare with synthetic capture to separate capture timing from panel ordering. The experiment must preserve dimming, selection, key handling, and multi-display behavior.
- If disabling the automatic animation removes the reported expansion without introducing a blank/unstyled frame, make `.none` the minimal overlay-specific fix. If it does not, continue checking activation/order/first-frame behavior and only adjust presentation sequencing when evidence points there. Do not add arbitrary delays, change opacity, or suppress dimming as speculative fixes.
- If the flicker cannot be reproduced or tied to a specific cause, leave code behavior unchanged for this subtask and report it as unconfirmed rather than claiming a fix. Verify the resulting build manually on macOS in addition to automated coverage.

## Design and data boundaries

- Bump the settings schema version from 3 to 4, retain the existing quality key, and decode missing `rememberLastRegion`/geometry fields to safe defaults so existing settings migrate without a destructive reset. Decode geometry entries independently so a malformed record cannot discard valid siblings or unrelated preferences.
- Store remembered rectangles in a Codable settings value keyed by persistent display UUID. Geometry is normalized display-local `x`, `y`, `width`, and `height` values; conversion to and from the existing point-based selection geometry belongs at the selection/session boundary.
- Restore selection before overlay panels are shown. Restoration initializes a fresh annotation document and editable selection; it must never reuse prior image or annotation state.
- Update the menu's checked state from the persisted settings result. On write failure, retain the actual persisted state and surface the error through the app's existing safe settings-error path.
- Do not change Screen Recording permissions, capture APIs, output formats, shortcuts, or unrelated annotation/export behavior.

## Validation

- Settings tests cover old/missing fields, fixed quality normalization, preference persistence, clear-on-disable semantics, malformed geometry, and failed writes.
- Geometry/selection tests cover normalized round trips across resolution/scale changes, clamping/minimum size, negative global display origins, and display identity mismatch.
- Session tests cover restoring only the target pointer display, missing display UUID behavior, full-screen exclusion, save-on-completed-geometry-change, and no writes for annotations or drag intermediates.
- Export tests verify both synchronous and asynchronous app exports pass quality 100, including when no settings store is available; PNG/BMP remain unaffected by lossy encoder properties.
- Pasteboard tests emulate append semantics and assert a second copy leaves only its new item; a named, unique pasteboard integration test verifies the native adapter replaces existing items while keeping both representations on one item. Test data must be generated artwork, not screenshots.
- Menu tests verify there is no quality slider and the remembered-region checkmark reflects stored state.
- Run focused tests, `swift build`, `swift test`, and `./scripts/validate.sh`; run signed UI tests and a manual cold/warm comparison of default versus disabled overlay animation when the available macOS signing/runtime permits.

## Acceptance criteria

1. Every VibeShot export uses quality 100, old settings cannot lower it, and the menu exposes no quality control.
2. Remembered-region behavior matches the enabled/disabled, display-specific, geometry-only, and full-screen rules above.
3. A successful Copy replaces prior pasteboard images with the current capture, and obsolete copy tasks cannot overwrite a newer session.
4. Automated validation passes. Flicker is either tied to reproduced evidence and corrected with a minimal fix, or explicitly reported as unresolved; it is not claimed fixed without verification.
