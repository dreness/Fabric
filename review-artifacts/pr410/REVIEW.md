# PR 410 review

Reviewed `f064001906f45621462b1023494a8a50b15c0b85..c821b86b3cc855af15a5f5dedf9b9fe14b985912` (the declared base, PR 409's head).
Local branch: `codex/pr410-review`. Starts at the original PR head; earlier review fixes are not carried forward. Nothing pushed or posted upstream.

## Finding and fix

**P1 — Re-key a replacement's parameter along with its port.** `PortRegistry.make` calls `Port.adoptID` when a declaration factory returns a port with another id. The preconstructed-port declaration used by String Formatter does exactly that when `{amount:f}` changes to `{amount:d}`. The port retains its old UUID but its IntParameter retains a new UUID. `Graph.registerValueChange` finds the owning graph by object, then its undo handler looks up the port by `parameter.id`; that lookup fails, so Undo silently does nothing. A generic declaration factory that ignores its supplied id has the same defect.

Fix: override `adoptID` in ParameterPort, call super and re-key the backing parameter. This keeps the responsibility beside its existing hydrate/take identity handling; no new graph responsibilities.

Reproduction: `DeclaredPortsReviewRegressionTests.formatterParameterIdentity` retypes a real StringFormatterNode, asserts both identities, records a real value change, and checks Graph.undo/redo. `factoryParameterIdentity` covers a preconstructed parameter factory independently. Same test source before/after: two tests, three failed assertions upstream; both pass after the fix.

## Design and contribution assessment

The declared-interface / registry-diff / graph-edit separation follows AGENTS.md and keeps typed ports, settings-owned topology, declaration order and document hydration apart. Reviewed the central reconciliation/decode paths and node migrations, including source-driven interfaces, routing, device outputs, materials, strings and subgraphs. Existing seeded invariant tests exercise more than 50 node types; decode ordering/wire retention and settings undo/redo coverage pass. The confirmed parameter identity violation breaks the stable identity and public-API undo contracts and is corrected here. No added frameworks, project settings changes, lifecycle calls from editing code, or undo suppression in compound edits.

The public API migration removes several prior port-edit helpers and deprecates addDynamicPort; plugin authors will need to migrate to declaredPorts. This is stated in the PR, not a hidden behavioral finding.

## Validation

- Original editor build: success. Baseline selection: 244 tests / 24 suites passed.
- Focused before: 2 tests fail with 3 assertions. Focused after: 2 pass.
- Final expanded selection (settings, undo, publishing, topology/lifecycle, hydration, expression/script, declared ports, string split/formatting): **280 tests / 27 suites passed**.
- Fixed Fabric Editor Debug arm64 build: **success**.
- Actual Metal device required by the new tests; host/toolchain details and exact commands retained.
- Portable production-plus-test patch checked against pristine upstream files, applied and byte-compared; checksums cover the evidence bundle.

## Limits and reuse

macOS arm64 Debug only; no iOS/visionOS build, GUI interaction pass, or claim of pixel-perfect rendered output. Source-compilation failure probes emit shader diagnostics intentionally. Prior PR findings remain separate local patches and are not silently mixed into this review.

See `commands.txt`, `review-context.json`, `pr.json`, compressed incremental diff, original/fixed build and test logs, reproduction logs, `trial-fixes.patch`, dependency resolutions, guideline snapshots and `SHA256SUMS.json`.
