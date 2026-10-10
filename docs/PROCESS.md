# Development process

## Work unit

A normal work unit is one implementation milestone or one focused defect. Do not combine unrelated
milestones merely because they touch adjacent files.

## Plan → implement → verify

1. Read `docs/PROGRESS.md` and the source-of-truth documents routed by `docs/PROJECT_MAP.md`.
2. `planner` inspects the relevant code and produces an implementation-ready plan with files, symbols,
   data flow, error paths, acceptance criteria, and tests.
3. The main agent resolves only decisions that materially change product behavior or architecture.
4. `implementer` owns code changes and focused tests. Planner/tester remain read-only.
5. `tester` reviews the diff first, then runs focused validation and the applicable manual checks.
6. On FAIL, return the concrete finding to the same implementer and verify again. Stop after two repair
   rounds and report evidence if the issue remains.
7. Update `PROGRESS.md`; update `HISTORY.md` only for durable decisions or changed limitations.

## Definition of ready

- Expected behavior and non-goals are clear.
- Relevant milestone and acceptance criteria exist.
- Privacy/permission impact is understood.
- Required product decision is recorded or explicitly requested from the user.

## Definition of done

- Behavior matches `PRODUCT_SPEC.md` and module boundaries match `ARCHITECTURE.md`.
- New pure logic and regressions have tests.
- Relevant build/test commands pass without hiding warnings or failures.
- Permission denied, cancellation, and failure paths restore the app to idle.
- Tester returns PASS, or a precise external blocker is documented.
- `PROGRESS.md` and affected source-of-truth documentation are current.

## Documentation maintenance

- Product behavior changed → update `PRODUCT_SPEC.md`.
- Ownership/data flow changed → update `ARCHITECTURE.md` and possibly `PROJECT_MAP.md`.
- Work order/exit criterion changed → update `IMPLEMENTATION_PLAN.md`.
- Durable decision changed → append a superseding entry to `HISTORY.md`.
- Milestone state changed → update `PROGRESS.md`.
- Do not create a second document for information already owned by one of these files.

## Release discipline

- Complete M0–M7 in order for the first MVP.
- Run the release gate in `TESTING.md`.
- Keep cloud/history work on separately approved scope with its own privacy and retention decisions.
- Never use real desktop captures as committed fixtures or release artifacts.
