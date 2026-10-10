---
name: vibeshot-development
description: Build and review VibeShot, the native macOS menu-bar screenshot capture and annotation app. Use for capture overlays, selection geometry, annotation tools, export, shortcuts, permissions, settings, and VibeShot project planning.
---

# VibeShot Development

Build against the maintained repository documents instead of reconstructing product behavior from
the prompt. Start with [project routing](references/project-routing.md), then read only the documents
needed for the current task.

Preserve these invariants:

- VibeShot is a menu-bar-only macOS app; temporary capture overlays are not a conventional main UI.
- A left click starts region capture. A right click opens commands and settings.
- Keep capture and editing local in the MVP. Network upload is a separately approved phase.
- Keep annotations as vector data until export; do not destructively repaint the source after each edit.
- Treat AppKit point coordinates, global display coordinates, and bitmap pixels as distinct spaces.
- Never capture VibeShot's own overlay windows or commit private screenshots as test fixtures.
- Do not weaken permission, multi-display, Retina, clipboard, or cancellation behavior to simplify an implementation.

For implementation tasks, update the progress and history documents when a milestone, decision, or
known limitation changes. Keep `AGENTS.md` concise; durable detail belongs in `docs/`.
