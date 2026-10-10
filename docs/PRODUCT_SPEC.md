# VibeShot product specification

## Product intent

VibeShot should make the common flow—capture a region, mark it up, and paste or save it—feel
immediate. It is a native macOS menu-bar utility with temporary full-screen overlays and no normal
main window.

## Supported platform and product boundary

- Native macOS application, initially targeting macOS 14 or later.
- Swift and AppKit for status-item, windows, mouse/keyboard input, and overlay rendering.
- ScreenCaptureKit for screen capture.
- Local-first MVP: no account, server upload, telemetry, or silent network access.
- Works on Retina and non-Retina displays and common multi-display arrangements.

## Primary interaction

### Menu-bar icon

- Left click: begin region capture immediately.
- Right click: open the VibeShot menu.
- The app does not appear in the Dock during ordinary operation (`LSUIElement`).

### Right-click menu

The menu contains:

1. Capture Region.
2. Capture Full Screen, with a display submenu when multiple displays exist.
3. Shortcut settings for region capture and full-screen capture.
4. Launch at Login toggle.
5. Output Format: PNG, JPEG, HEIC, and BMP.
6. Image Quality: a static 100% label. PNG/BMP remain lossless; JPEG/HEIC receive quality 100.
7. Remember Last Region: off by default; when enabled, restore the previous completed rectangle on
   the same display for region capture. Turning it off erases remembered rectangles.
7. Save Destination: Ask Every Time or the most recently selected folder.
8. Capture History (later milestone).
9. About and Quit.

Settings persist across launches.

## Capture state and behavior

1. Verify Screen Recording permission before capture. Explain how to enable it when denied.
2. Snapshot all active displays before showing VibeShot overlays so the app never captures itself.
3. Show a dimmed borderless overlay on every display.
4. Drag on any display to create a rectangular region. Show live pixel dimensions.
5. On mouse-up, retain the region and expose eight resize handles plus move behavior.
6. Support crossing display boundaries only when coordinate conversion and scale handling are correct;
   otherwise clamp MVP selections to one display and state that limitation visibly (M3 shows a
   cross-display drag hint while retaining the source display selection).
7. `Command+A` selects the full current display. `Escape` cancels and returns to idle.
8. Full-screen capture from the menu bypasses region dragging but opens the same annotation state.

## Annotation experience

Match the compact Lightshot layout shown in the reference image:

- A vertical tool strip anchored near the selection: freehand pen, straight line, arrow, rectangle,
  highlighter/marker, text, color, and undo.
- A horizontal action strip near the selection: copy, save, share, print, and cancel. Cloud upload and
  similar-image search are later-phase actions.
- Reposition either toolbar when it would fall outside the visible display.

Annotation requirements:

- Tools: select/move, freehand pen, line, arrow, rectangle, highlighter, and text.
- Color palette plus remembered last color.
- Stroke-width choices and remembered last width.
- Resize or move the selected capture boundary after initial selection.
- Undo and redo annotation commands. Deleting a selected annotation is desirable after MVP.
- Text editing commits on Enter or focus change; Escape cancels the entire capture, including uncommitted text.
- Annotation coordinates are relative to the selected region so resizing/moving the screen-space
  selection does not corrupt geometry.
- Export composites the source pixels and vector annotations at native pixel resolution.

## Keyboard and actions

- Configurable global shortcuts for Region Capture and Full-Screen Capture.
- Default Region Capture shortcut: `Command+Shift+9`, matching the published Lightshot shortcut on
  macOS; users may replace or disable it.
- `Command+C`: composite and copy the selected image to the general pasteboard, then close capture.
- `Command+S`: save using the most recent folder when available; otherwise show `NSSavePanel`.
- `Command+Shift+S`: always show Save As.
- `Command+P`: print the composited image.
- `Command+Z` / `Command+Shift+Z`: undo / redo.
- `Command+A`: expand selection to current display.
- `Escape`: cancel the entire capture from any focused editor control, export task, or owned system panel.
- `Command+Q`: cancel capture and quit, including while text or an owned system panel has focus.
- Return/Enter: optional quick copy action, disabled while editing text.

## Export rules

- Preserve native pixel density; never silently downscale a Retina capture.
- PNG and BMP are lossless. JPEG and HEIC use quality 100.
- JPEG/BMP exports flatten transparency against a defined background color.
- File names default to `VibeShot YYYY-MM-DD at HH.mm.ss` with a collision-safe suffix.
- Copy replaces the clipboard with one current image item containing PNG and TIFF representations.
- A success notification is optional; errors must be visible and actionable.

Action lifecycle:

- Copy and save close only after a successful write/copy; cancellation or errors retain the editor.
- Print closes only when the print operation is accepted/completed.
- Share closes only after the selected sharing service reports success; picker dismissal or errors
  retain the editor.
- Save, print, share, and export errors temporarily hide every capture overlay so macOS dialogs remain
  visible. Dismissal restores only the still-active capture. Copy and Save prepare images away from
  the UI thread. Cancellation before a file write prevents it; an atomic write already underway may
  finish, and a durably written file remains a successful save.
- If the main thread stops responding for 30 seconds during capture, a background watchdog exits
  VibeShot to release its windows. Unsaved capture/annotation work is lost in this emergency path.
  Sleep time does not count, and ordinary responsive panels do not trigger it.

## Lightshot feature inventory

Verified public Lightshot behavior used for parity planning:

- Fast selected-area capture and multi-display desktop support.
- Immediate editor with pen/freehand, line, arrow, rectangle, marker/highlighter, text, color, and undo.
- Selection resizing and full-screen maximize.
- Copy, local save, print, cancel, and keyboard shortcuts.
- PNG, JPEG/JPG, and BMP save formats.
- Upload to a hosted service and receive a short link.
- Share through social/internet services.
- Search for visually similar images.
- Open the selected image in an online editor.
- Account-backed uploaded screenshot history/gallery.

VibeShot scope mapping:

| Capability | MVP | Later |
| --- | --- | --- |
| Region/full-screen capture | Yes | — |
| Multi-display support | Yes | Improve cross-display selection if needed |
| Selection resize/move | Yes | — |
| Pen, line, arrow, rectangle, marker, text, color | Yes | Blur/pixelate, numbered steps |
| Undo/redo | Yes | Object selection/delete |
| Copy/save/print | Yes | — |
| macOS share sheet | Yes | Custom integrations |
| Configurable shortcuts, launch at login, format, quality | Yes | Profiles/presets |
| Local history | No | Opt-in, bounded retention |
| Cloud upload + share link | No | Requires explicit backend/privacy design |
| Similar-image search | No | Requires an explicit provider and upload consent |
| Online editor | No | Redundant initially; reconsider with cloud phase |
| Account/gallery sync | No | Only after authentication and data-deletion design |

Potential VibeShot enhancements such as window capture and delayed capture are backlog ideas, not
verified Lightshot parity requirements and not part of MVP.

## Privacy and safety

- Never upload by default. Network actions must be explicit and visibly disclose the destination.
- Do not retain screenshot pixels for history unless the user enables it.
- Do not log clipboard image contents, screen pixels, entered annotation text, or saved paths at info level.
- Local release diagnostics, when enabled, are numeric-only durations/counts/byte estimates with no
  network destination or user-content fields.
- Test fixtures must be generated artwork, not captures of a developer's desktop.

## MVP acceptance summary

The MVP is complete when a user can launch VibeShot, grant permission, use a configurable shortcut
or left-click the icon, select and resize a region on each attached display, annotate with every core
tool, undo/redo, and reliably copy/save/print at correct pixel scale. Right-click settings must persist,
Launch at Login must reflect system state, and all cancellation/error paths must restore normal input.
