# PR #407 review

**Recommendation: fix the replacement topology regression before merging.**

Reviewed https://github.com/Fabric-Project/Fabric/pull/407 at `f5f3ff13ca330ae3c855d43a9b73afd073eacabb`, against its declared base `d1015950508f4f0a874f51fe702f9b2dc8fece7f` (#406). This is the second sequential layer, not a sibling against main. Local branch: `codex/pr407-publishing-review`. The #406 trial fixes are intentionally absent so this review isolates #407. No upstream comments, pushes, or PR changes were made.

## Finding

### [P1] Refresh dependency caches after installing a replacement port

Upstream locations: `Fabric/Graph/Node/Node.swift:450–456`; `Fabric/Nodes/Object/SubGraph/SubgraphNode.swift:104–109`.

`rebindWires` refreshes `inputNodes`/`outputNodes` while the old port is still in the node's registry (or proxy array). The old port has already lost its wires, and the replacement is not visible yet. Installing the replacement subsequently leaves those caches empty. The wire and its endpoint references remain valid, but `GraphRenderer.reconcileNode` uses these caches to decide whether a processor is connected, so the processor can stop executing. Auto Layout and graph traversal also consume the stale caches.

Concrete reproduction: connect a Number Binary Operator output to Sample and Hold's Value inlet, using Float settings. Start the renderer, change Sample and Hold to Int, and synchronize lifecycle. The compatible wire survives and points to the new inlet, but Sample and Hold changes from `.started` to `.stopped`. Direct inlet/outlet replacement and a type-changing published proxy reproduce the same missing dependencies.

**Fix applied locally:** refresh the connected-node caches and topology callback after the replacement is installed; do the same after a subgraph's proxy collection changes. Reuse one internal helper for the existing connect/disconnect cache updates. No lifecycle methods are invoked by editing code.

All four unchanged reproduction cases fail on the upstream head (six assertions), then pass with this fix. See `reproduction-before.log`, `fix-tests.log`, and `Tests/PublishingReviewRegressionTests.swift`.

## Design and contribution assessment

The event-based ownership follows AGENTS.md: the graph owns publication edits and undo registration; SubgraphNode owns proxies; nested publishing recurses through ordinary graph APIs; wire IDs remain stable. Read-only external publishing state closes the previous notification bypass. The fix restores the documented topology-cache and lifecycle contract without adding frameworks, changing serialization, or calling execution lifecycle from editing code.

Reviewed the changed production paths, tests, AGENTS.md, ARCHITECTURE.md, GLOSSARY.md, NODES.md and README.md. No separate contribution guide was found. Settings undo (#408), the temporary embedding path (#409), declared ports (#410), and clone proxy IDs (#411) are explicitly deferred by this PR and were not reported as #407 defects. Previously established #406 issues are not counted again.

## Validation

| Check | Result |
|---|---|
| Unmodified PR targeted publishing/undo/embedding/ownership/hydration/lifecycle suites | 91 tests passed |
| Added reproduction cases on unmodified production code | 4 tests failed, 6 assertions |
| Fixed publishing/proxy/undo/embedding/ownership/hydration/lifecycle/expression/signature/layout/round-trip suites | 153 tests in 17 suites passed |
| Unmodified Fabric Editor Debug build | Succeeded after macro approval cache workaround |
| Fixed Fabric Editor Debug build | Succeeded |
| Fix patch against pristine PR head source files | Applies cleanly; resulting source/tests match byte for byte |
| Source/test whitespace check | Passed |

The new tests require an actual Metal device, including a real renderer lifecycle check; they do not silently pass when Metal is unavailable. No native UI interaction or visual rendering claim is made for this review. Tests are targeted, not the entire repository suite.

## Reproduction and environment

Run from this branch's worktree. `local-build.xcconfig` disables signing and sets deployment target 15.0. Frameworks were reused from the #406 builds at identical submodule revisions; the SwiftPM dependency cache was copied using APFS clones. The copied SwiftPM runtime includes Sparkle.framework under `.build/out/Products/Debug/PackageFrameworks`, required by Hap's loader. For a clean setup, use the repository's Syphon and Hap build scripts and the #406 review's documented Sparkle runtime step.

```sh
swift test --filter PublishingReviewRegressionTests
swift test --filter 'Publishing|ProxyPort|Undo|EditUndo|SubgraphEmbedding|GraphConnectionOwnership|PortHydration|GraphNodeLifecycle|MathExpressionNode|JavaScriptNodeSignature|GraphAutoLayout|NodePortRoundTripContract'
xcodebuild -project Fabric.xcodeproj -scheme 'Fabric Editor' -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/fabric-pr407-derived -clonedSourcePackagesDirPath /private/tmp/fabric-pr406-derived/SourcePackages -xcconfig review-artifacts/pr407/local-build.xcconfig -skipMacroValidation CODE_SIGNING_ALLOWED=NO build
```

The first Xcode attempt stopped at `MLXHuggingFaceMacros` because the cached approval no longer matched its resolved package. `-skipMacroValidation` was used only for these local builds; no project settings were changed. `build-editor.log` preserves that failure, `build-editor-retry.log` the successful original build, and `fix-build-editor.log` the successful fixed build. Xcode and standalone SwiftPM resolved different permitted dependency versions; both resolutions and Xcode's generated lockfile diff are saved. The generated tracked lockfile was restored and is excluded from the fix.

Use `trial-fixes.patch` to apply the two production changes and four regression tests to the upstream head. `pr407.diff` is the incremental upstream diff; metadata and discussion snapshots identify the reviewed revision. SHA256SUMS.json covers all artifact files except itself. Build paths in raw logs are local evidence, not portable requirements.
