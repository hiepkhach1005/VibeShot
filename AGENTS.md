# Codex development workflow

## Project context

VibeShot is a native macOS menu-bar screenshot and annotation utility. For VibeShot product or code
work, use the repository skill at `.agents/skills/vibeshot-development/SKILL.md`. Route detail through
`docs/PROJECT_MAP.md`; do not load every project document for every task.

## Goal

Use the smallest amount of agent work that can reliably complete the task. Preserve the
main thread for requirements, decisions, and the final result.

## Agent policy

- Do not spawn subagents for explanations, tiny edits, formatting, or a single obvious fix.
- For a substantial feature or multi-file behavioral change, run this sequence:
  1. Ask `planner` for a compact implementation brief.
  2. Review the brief in the main thread and resolve only material ambiguity.
  3. Ask `coder` to implement the accepted brief.
  4. After implementation completes, ask `tester` to verify the diff and behavior.
  5. On FAIL, send the concrete findings back to the same `coder`, then have
     `tester` verify again. Limit this repair loop to two rounds before escalating.
- Keep plan, implementation, and dependent testing sequential. Parallelize only independent
  read-only investigation when it clearly saves time.
- Only `coder` owns application-code edits. `planner` and `tester` stay read-only.
- Wait for each required agent and summarize its result; do not paste raw logs into the
  main thread.

## Cost and token controls

- Default delegated work uses GPT-6 Luna with low reasoning (Light).
- `planner` uses GPT-6 Sol/high for implementation-ready plans; keep plans information-dense
  and normally under 1,600 words.
- `coder` uses GPT-6 Sol/low (Light) for focused implementation.
- `tester` uses GPT-6 Luna/low (Light) and begins with focused validation.
- Spawn these agents with the specified model and reasoning effort. Use the default agent type
  when a named role has a fixed model that differs from this configuration.
- Report security-sensitive code, concurrency, migrations, persistent failures, or conflicting
  evidence to the parent; preserve these model profiles unless the user requests a change.
- Search before reading files, read targeted ranges, avoid repeated summaries, and prefer
  focused tests before full suites.

## Completion gate

Finish only when relevant validation passes, or report the exact blocker and evidence.
The final response should list the outcome, changed files, validation performed, and any
remaining risk without repeating intermediate agent reports.

## Project rules

- Follow `docs/ENGINEERING_RULES.md` for VibeShot implementation and review.
- Implement one milestone or focused behavior at a time; do not silently pull post-MVP cloud features
  into local capture work.
- Keep `docs/PROGRESS.md` current and record durable decisions in `docs/HISTORY.md`.
- Use the verified validation commands appropriate to the change:
  - `swift build` for fast compiler feedback.
  - `swift test` for fast unit-test feedback.
  - `./scripts/validate.sh` for the full unsigned Debug build/unit-test and Release build gate.
- The UI test target is built but skipped by the unsigned validation script because its runner requires
  signing to bootstrap. Run UI tests separately with signing enabled when the task requires them.
