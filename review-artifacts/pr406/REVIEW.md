# Fabric PR #406 review

Follow-up: proposed local fixes, before/after validation, and an applyable patch are documented in [FIXES.md](FIXES.md). The review below describes the original PR revision.

Reviewed October 14, 2026 (America/Los_Angeles). This is a local review; no GitHub review or comments were submitted.

PR: https://github.com/Fabric-Project/Fabric/pull/406

Head: `d1015950508f4f0a874f51fe702f9b2dc8fece7f`

Base and merge base: `d2407796672b53ef3eb88c23b87256a804ca403d`

Isolated worktree: `/Users/andre/.codex/worktrees/review-pr406/Fabric`

Recommendation: address the two parameter undo issues before accepting this layer. The graph-owned undo architecture follows the project's direction, and the editor builds, but the additional probes show its undo contract is incomplete.

## Stack relationship

These are sequential layers, not independent patches against one shared base. GitHub metadata shows that each later PR's base SHA is exactly the preceding PR's head SHA. #406's description explicitly says “1 of 6” and identifies work intentionally deferred to later layers.

| PR | Base branch | Base SHA | Head SHA |
|---|---|---|---|
| #406 | main | d2407796672b | d1015950508f |
| #407 | stack/1-undo-foundation | d1015950508f | f5f3ff13ca33 |
| #408 | stack/2-publishing-events | f5f3ff13ca33 | 69c441898f8e |
| #409 | stack/3-settings-value | 69c441898f8e | f064001906f4 |
| #410 | stack/4-create-subgraph | f064001906f4 | c821b86b3cc8 |
| #411 | stack/5-declared-ports | c821b86b3cc8 | 6841b08270e2 |

Review incremental diffs against the preceding layer and build each cumulative head. Merging or rebasing earlier layers will require updating the later bases. This run reviewed and built #406 only. `stack-metadata.json` preserves the full live snapshot, including descriptions and SHAs.

## Findings

### P2: Register active field edits so Graph.undo can flush them

Location: `Fabric/Views/Parameters/ParameterObservableModel.swift:107-118`, together with `Fabric/Graph/Graph.swift:509-512` and `Fabric/Views/Parameters/InputFieldView.swift:39-48`.

`InputFieldComponentView` calls `setEditing(true)` on focus. While that flag is true, `commitUnlessEditing()` returns without registering anything in `PendingCommit`. `Graph.undo()` flushes only that registry. Consequently, a caller using the newly documented graph undo entry point while a field remains focused skips the field's edit and undoes an older graph operation.

Reproduction `focusedEditIsFlushed`: add a String Split node as one undo step; construct its actual `InputFieldView`; begin editing; change “Before” to “After”; call `graph.undo()` before ending editing. The node is deleted and its parameter remains “After”, rather than reverting the value while preserving the node. Both expectations fail. This is a model-level reproduction of the focus callbacks, not a claim that a specific native text-field keyboard event was tested end to end. App-level Undo/Redo command changes are explicitly deferred to #408, but those commands will depend on this API.

Suggested change: register active drafts with the graph's flush mechanism as well as delayed commits, and restart their edit baseline correctly if focus remains after undo/redo. Cover focus-preserving undo in a regression test.

### P2: Capture the live parameter value as the undo baseline

Location: `Fabric/Views/Parameters/ParameterObservableModel.swift:22-26`.

`editStart = oldValue` captures the previous UI mirror, even though the parameter is authoritative. Engine notifications reach that mirror asynchronously through `.receive(on:)` and a 16 ms throttle. If a parameter changes before its notification reaches the UI, a control edit records the stale value and undo restores the wrong state.

Reproduction `undoBaselineFollowsParameter`: initialize parameter and model to 1; set the parameter to 2; set `model.uiValue` to 3 before the queued notification arrives; undo. Actual result is 1; expected result is 2, the value immediately before the user's edit. The timing gap is deliberately exercised synchronously; no arbitrary sleeps are used.

Suggested change: initialize `editStart` from `getValue()` before writing the UI value, while preserving the original baseline for an edit already in progress.

### P3: Avoid naming-only undo records for edits that do no work

Location: `Fabric/Graph/Graph.swift:567-569` and `Fabric/Graph/GraphAutoLayout.swift:26-32`.

`performEdit` unconditionally registers two action-name handlers. Calling Auto Layout on an empty graph therefore changes `canUndo` from false to true despite making no document change. Previously the empty grouping contained no registered operations. Similar callers can acquire empty history entries.

Reproduction `emptyLayoutHasNoUndoStep`: create an empty graph with an undo manager whose `groupsByEvent` is false; invoke `autoLayout()`; require `canUndo` to remain false. It is true. This is lower severity than the value-history errors.

Suggested change: avoid opening a named edit when the operation has no changes, or make the compound helper add its name preservation only when substantive undo steps exist.

## Design and contribution assessment

The review used the base revision's `AGENTS.md` as the pre-existing engineering contract, and read the PR's additions separately. `ARCHITECTURE.md`, `GLOSSARY.md`, `NODES.md`, `README.md`, and `PLUGINS.md` supplied context. There is no separate CONTRIBUTING file in the reviewed tree. The advertised `PUBLISHING_AND_SETTINGS.md` design reference is an unresolved `(link)` in the PR description and that file is absent at both base and head; its contents could not be assessed.

| Requirement | Assessment |
|---|---|
| Graph owns topology; GraphRenderer owns lifecycle execution | Preserved in the inspected changes. Undo reuses graph operations and lifecycle-review invalidation; it adds no calls to node lifecycle methods. Relevant lifecycle regression tests pass. |
| Stable identities and predictable graph contracts | ID-based node, graph-path and wire snapshots are a good fit. Node deletion restores original array order. Undo target tests pass. |
| Separation of responsibilities and readable APIs | Central registration and explicit compound-edit helpers improve consistency. `ParameterObservableModel` remains `@MainActor @Observable`. PendingCommit is a dedicated debounce helper; the active-edit gap needs correction. |
| Parameter hydration, synchronization, registry-driven serialization | No new serialization format or port-registration scheme. Hydration and every-node encode/decode/encode regression tests pass. The stale undo baseline violates the parameter-as-authority principle even though ordinary value propagation remains intact. |
| Surgical, reversible changes | The 32-file change is substantial, but largely consists of necessary undo call-site migration and control plumbing. No new third-party dependency or framework is introduced. |
| SwiftUI and Swift conventions | No new UIKit/AppKit dependency, force-try, force-unwrap, or single-parameter onChange callback was found in the additions. Existing discouraged patterns in touched files were not counted as new PR violations. The new `.onChange(of: focused) { ... }` uses the permitted zero-argument overload. |
| Commit messages | All five PR commits use a final `Via Claude Opus 5.5` line and no co-authorship trailer. |
| New undo-specific rules in this PR | Core direct-registration source test passes. Focused drafts are not actually covered by the advertised flush contract. |

Do not treat the described temporary Create Subgraph implementation, StrategyNode registration, missing app Undo/Redo commands, or the future proxy-event redesign as accidental omissions in this layer: the PR identifies their later stack owners (#409, #408, #408 and #407 respectively). Whether those later implementations fulfill the contract still requires their own reviews.

## Build and validation

Host: Apple M5 Max, macOS 27.0.1, Xcode 27.0 build 27A266a, Swift 6.4. Full output: `environment.txt`.

| Check | Result |
|---|---|
| PR head and merge base | Exact SHAs verified locally |
| Pinned recursive submodules | Initialized; SHAs retained in `submodule-revisions.txt` |
| Syphon prerequisite | Repository script succeeds unchanged |
| Hap prerequisite, repository script unchanged | Fails: old deployment targets unsupported by Xcode 27 and unavailable Mac Development certificate |
| Hap with local xcconfig overrides | Succeeds with deployment target 15.0 and signing disabled; no tracked source changes |
| Fabric Editor Debug, arm64 macOS | BUILD SUCCEEDED with the local xcconfig overrides |
| Original undo-focused tests | 26 tests, 7 suites, all pass after supplying Sparkle at runtime |
| Related graph regression tests | 73 tests, 7 suites, all pass |
| Additional review probes | 4 tests: delayed-commit undo/redo passes; the other 3 fail as documented above |
| Whitespace check | `git diff --check d240779...HEAD` succeeds |
| Editor startup smoke | Process launches, New Document opens the starter graph's editor UI, and the temporary document closes without saving. This does not establish visual-rendering correctness or exercise every UI control. |

The original test run compiled successfully but failed before running any tests because Hap links Sparkle and the SwiftPM runner could not locate it. Setting DYLD_FRAMEWORK_PATH alone did not fix the runner's lookup. Copying the already-built Sparkle.framework into SwiftPM's `Products/Debug/PackageFrameworks` fixed it. These are dependency/build-environment issues, not changes introduced by #406 (the manifest, build scripts and submodule pins are unchanged by this PR).

Xcode and standalone SwiftPM resolve different allowed dependency versions. Xcode also rewrote the workspace resolution metadata and three tag revisions while preserving their version numbers; `xcode-resolution.diff` records this. Both actual resolution files are saved. Accordingly, the editor build and SwiftPM test runs are separate validations and should not be described as using one identical dependency graph. No dependency or source fixes were committed.

Built app: `/private/tmp/fabric-pr406-derived/Build/Products/Debug/Fabric Editor.app`. DerivedData and SwiftPM build products remain available locally; temporary build paths are not durable distribution artifacts.

## Reproduction commands

Run from the isolated worktree unless stated otherwise. These are the commands/settings used, with logs alongside this report.

```sh
git fetch origin refs/pull/406/head
git checkout --detach d1015950508f4f0a874f51fe702f9b2dc8fece7f
git submodule update --init --recursive
./scripts/build-syphon-xcframework.sh
./scripts/build-hapinavfoundation-xcframework.sh
# The unchanged Hap command fails on this host; retry with:
XCODE_XCCONFIG_FILE=/private/tmp/fabric-pr406-build.xcconfig ./scripts/build-hapinavfoundation-xcframework.sh
xcodebuild -project Fabric.xcodeproj -scheme 'Fabric Editor' -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/fabric-pr406-derived \
  -xcconfig /private/tmp/fabric-pr406-build.xcconfig CODE_SIGNING_ALLOWED=NO build
swift test --filter 'Undo|EditUndo'
# Supply the runtime dependency built by Xcode:
ditto /private/tmp/fabric-pr406-derived/Build/Products/Debug/Sparkle.framework \
  .build/out/Products/Debug/PackageFrameworks/Sparkle.framework
swift test --skip-build --filter 'Undo|EditUndo'
swift test --skip-build --filter 'GraphConnectionOwnershipTests|GraphAutoLayoutTests|SubgraphEmbeddingTests|GraphNodeLifecycleTests|StringInputFieldTests|PortHydrationTests|NodePortRoundTripContractTests'
# Only after the original tests, add the review-only probe file:
cp /Users/andre/work/graphics/Fabric/review-artifacts/pr406/ReviewUndoEdgeCaseTests.swift Tests/
swift test --filter ReviewUndoEdgeCaseTests
```

The xcconfig content is retained as `local-build.xcconfig`. Test probes require a real Metal device using `#require`, rather than silently returning when Metal is unavailable.

## Artifact inventory and workspace state

This directory contains the full PR diff, PR metadata, review/comment snapshots, full stack metadata, base and head engineering specifications, architecture references, exact resolved dependencies and submodule revisions, build settings, complete build/test logs, and the four standalone reproduction tests. The GitHub review and comment lists were empty when captured.

The original checkout's existing `Fabric.xcodeproj/project.pbxproj` edits and user workspace data were preserved. The only addition there is this untracked review-artifacts directory. The isolated worktree contains the review-only test file and Xcode's generated Package.resolved changes; production source is unchanged. No branch was merged and no review was posted.
