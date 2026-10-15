# PR #406 trial fixes and reproduction validation

These fixes are applied locally on `codex/pr406-undo-fixes`, based on PR head `d1015950508f4f0a874f51fe702f9b2dc8fece7f`, in `/Users/andre/.codex/worktrees/review-pr406/Fabric`. The fixes, tests, and review artifacts are committed on this local branch; nothing has been pushed or posted to GitHub. The original working checkout's Xcode edits remain untouched.

## Results

| Finding | Unchanged #406 reproduction | With trial fix |
|---|---|---|
| Focused draft skipped by Graph.undo | Node removed; field value remains “After” | Node retained; field value returns to “Before” |
| Undo baseline taken from stale UI mirror | Parameter goes 1 → 2 externally → 3 through UI; undo restores 1 | Undo restores the live pre-edit value 2 |
| Empty Auto Layout creates undo history | Empty graph gains a naming-only undo step | Empty graph gains no undo step |
| Delayed-commit positive control | Undo/redo before the pause expires works | Continues to work |

The original four reproduction tests were not changed. They were rerun on unchanged #406 immediately before editing production source: three failed and the positive control passed. After the fixes, all four passed. See `fix-baseline-probes.log` and `fix-original-probes.log`.

The final combined regression run passed **107 tests in 14 suites**, including the four original probes, ten additional fix regression tests, the PR's own undo tests, and relevant graph ownership, layout, subgraph embedding, lifecycle, input-field, hydration and serialization tests. See `fix-regression-final.log`.

Fabric Editor also rebuilt successfully with the same previously recorded deployment-target and signing overrides. See `fix-build-editor.log`. No new prerequisite or dependency workaround was needed for these changes. The editor was not relaunched for this fix run; the earlier startup smoke check applies to the unmodified PR.

## Proposed fixes and reasoning

### Active drafts participate in the existing flush mechanism

`PendingCommit.hold(on:_:)` registers a draft without starting a timer. `ParameterObservableModel` uses it while an explicit field or drag edit is active. Thus `Graph.undo()` and `redo()` can find the draft without waiting for focus loss or gesture completion. Finishing an edit still commits normally, and a new value after undo starts a fresh baseline even if the same field retains focus.

`Graph.canUndo` also accounts for uncommitted drafts, so a first field edit can enable an Undo command before the undo manager has any committed history. Cancelled drafts, released controls, changes that return to their starting value, and controls without an undo target do not advertise pending undo.

Starting an explicit edit while a pause is already scheduled replaces that timer with an untimed hold. Ordinary unfocused pause-based edits retain their 500 ms debounce. The existing weak registry and cancellation lifecycle are reused.

### Read the baseline from the parameter before writing

The first change of an edit captures `getValue()` before calling `setValue`, rather than the mirror's `oldValue`. Further changes preserve that first baseline. This follows the existing contract that the parameter is authoritative, while UI notifications may be queued and throttled.

### Skip layouts that do not move anything

Auto Layout filters out nodes whose offsets already equal their computed positions, then returns before calling `performEdit` when none remain. This covers both an empty graph and repeating Auto Layout on an already arranged graph. A real layout change keeps its compound edit name, positions and redo behavior.

This is intentionally a call-site fix. The generic `performEdit` helper still assumes its caller is performing an actual edit and can still create naming-only records if invoked with an empty body elsewhere. Reworking its naming protocol would broaden the trial beyond the demonstrated Auto Layout defect and risk the compound undo/redo naming guarantees. Other callers should likewise avoid invoking it for operations that make no changes.

## Why the reproductions are valid, and what they establish

1. **Focused edit:** the probe constructs the real `InputFieldView`, calls the same model methods used by its focus and text-binding callbacks, and invokes the documented `Graph.undo()` entry point. The pending edit is absent from the registry on unchanged #406. The result demonstrates a graph API/model contract violation. It does **not** demonstrate that the current macOS TextField's native Cmd-Z handler routes to that entry point; native keyboard routing is separate, and editor command integration is explicitly deferred to stack layer #408.
2. **Stale mirror:** the additional test explicitly verifies that the model still shows 1 while the live parameter and port both show 2 before the UI edit occurs. Queued delivery makes that gap deterministic without sleeps. Undo and redo are then checked over a multi-change edit, verifying that the initial live baseline is retained rather than overwritten by later changes.
3. **Empty layout:** the reproduction invokes the public graph API with a valid empty graph and undo manager. Additional cases verify that repeating a nonempty but already correct layout creates no history, that an existing redo operation survives a no-op, and that a real layout remains undoable and correctly named through repeated cycles.

All new tests require a real Metal device with `#require`; lack of GPU access cannot silently turn these reproductions into passes.

## Additional regression coverage

`UndoFixRegressionTests.swift` covers:

- First draft enabling Undo, undo/redo without losing focus, continued typing in the same field, and no extra step on focus loss.
- Returning an active edit to its starting value.
- Switching a scheduled pause to an explicit active edit, and ordinary delayed commits continuing to fire.
- A stale UI mirror at the start of a multi-change edit, including redo.
- Draft isolation between document undo managers.
- Cancellation and release removing drafts from undo availability.
- Empty layouts preserving redo, unchanged layouts producing no edit, and actual layouts retaining their names and positions.

The first combined run had one failure in the new timer test because it required a 500 ms timer to have completed within a fixed 650 ms window while other main-actor tests were running. That check passed in isolation (`fix-pause-timer-isolated.log`). The test now waits for the observable commit with a bounded three-second deadline and keeps the control alive across the wait. Production timing remains 500 ms. The corrected combined run passed; the initial failing run is retained as `fix-regression.log`.

## Patch and reproduction

`trial-fixes.patch` includes exactly four production files and the two test files. Generated Xcode `Package.resolved` changes are excluded. The patch was applied to pristine copies of the four files from the PR head; all resulting production and test files matched the fixed worktree byte for byte. A reverse-application check also passed. See `fix-patch-validation.txt`.

To try the patch in a clean checkout at the pinned PR head:

```sh
git apply /Users/andre/work/graphics/Fabric/review-artifacts/pr406/trial-fixes.patch
```

Use the prerequisite and runtime setup in `REVIEW.md`, then run:

```sh
swift test --filter ReviewUndoEdgeCaseTests
swift test --filter 'Undo|EditUndo|GraphConnectionOwnershipTests|GraphAutoLayoutTests|SubgraphEmbeddingTests|GraphNodeLifecycleTests|StringInputFieldTests|PortHydrationTests|NodePortRoundTripContractTests'
xcodebuild -project Fabric.xcodeproj -scheme 'Fabric Editor' -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/fabric-pr406-derived \
  -xcconfig /private/tmp/fabric-pr406-build.xcconfig CODE_SIGNING_ALLOWED=NO build
```

`apply-trial-fixes.py` records how the production edits were originally applied; the patch is the preferred review/apply artifact and also includes the tests. The original `REVIEW.md` and failure logs remain as the historical assessment of unchanged #406.
