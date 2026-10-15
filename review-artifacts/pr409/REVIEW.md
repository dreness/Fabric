# PR 409 review — Create Subgraph

**One P1 finding; local fix and regressions included.** Review only `69c44189..f0640019`, not local `main`.

## P1: proxy preflight clears live values and fires callbacks

Upstream `Fabric/Nodes/Object/SubGraph/SubgraphNode.swift:181–185` implements `canProxy` by constructing and immediately discarding a real proxy. Proxy construction writes the inner port's value; `NodePort.deinit → teardown` clears it through the proxy's forwarding setter. Merely checking a plain Float output holding 42 leaves it nil and fires two value callbacks. Creating either a regular or Deferred Subgraph therefore clears a boundary outlet's last value. If a later boundary is unsupported, the supposedly atomic rejection has already fired callbacks on supported ports. Those callbacks may have their own effects even when parameter-backed values reseat themselves.

**Fix:** resolve a factory without constructing a proxy. Both `canProxy` and actual proxy creation use the same type switch; validation and creation cannot drift. Real proxies keep their existing lifecycle and ownership behavior.

**Reproduction:** `SubgraphReviewRegressionTests` checks read-only preflight, a rejected mixed supported/unsupported selection, and preservation of 42 on boundary outputs for both subgraph classes. An additional nested-history test checks fan-out, a disabled wire, duplicate selection, settings edits before and after embedding, and repeated root undo/redo. On upstream: 7 failed assertions in 3 tests (4 parameter cases); nested-history probe passes. With fix: all 4 tests (5 cases) pass unchanged.

## Guidelines and scope

The public-API compound edit follows the project's graph-owned undo and lifecycle separation: no bespoke embedding object, no suppressed registration inside Create Subgraph, and no lifecycle calls in editing code. Normal/Deferred subgraphs, prior undo targets and serialization are covered by the selected suites. The preflight bug breaks the documented refusal-without-change guarantee and stable state requirement; its factory fix preserves the DRY supported-type list.

This branch starts at upstream #409 and contains only this review's fix; previous local fixes for #406–408 are not incorporated. Inherited findings remain separate. Declared ports and clone sets are intentionally deferred to #410/#411.

## Validation

- Original Editor: **BUILD SUCCEEDED** (Debug arm64, signing off).
- Original combined selected run: 236 tests / 22 suites, one shader-hydration failure. The exact failing test passed on isolated retry; the subsequent full selected run also passes. Both original logs retained; no source claim that this transient failure was fixed by the proxy change.
- New probes on upstream: 4 tests, 7 assertion failures; logs retained.
- Fixed selected suites: **240 tests / 23 suites pass**, including settings/publishing/proxies, graph ownership/lifecycle, embedding/undo, hydration and native typing-undo tests.
- Fixed Editor: **BUILD SUCCEEDED**.
- Added context-dependent tests require actual Metal rather than silently skipping.

Build flags, toolchain, exact incremental PR metadata/diff, dependency resolutions, discussions, portable patch and logs are alongside this report. Large logs are gzip compressed. `commands.txt` contains the build/test commands. Xcode's resolution changes were saved and reverted. No push or upstream comment/review. Full editor GUI/render-output correctness was not claimed.
