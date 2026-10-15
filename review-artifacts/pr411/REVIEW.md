# PR 411 review

Reviewed `c821b86b3cc855af15a5f5dedf9b9fe14b985912..6841b08270e213f7c2686e83329bc1da844cf5d8` (the declared base, PR 410's head).
Local branch: `codex/pr411-review`. Starts at the original PR head; earlier review fixes are not carried forward. Nothing pushed or posted upstream.

## Findings and fixes

**P2 — Restrict UUID substitution as well as UUID collection.** Graph.findAllUUIDs collects only identity-key values, but remapUUIDs still substitutes every matching string. Set a StringLength node's input or userName to its own node/port UUID, then duplicate it: the text changes to the new UUID. The existing upstream test uses an unrelated random UUID and misses this collision. Fix: carry identity-key context through substitution, including arrays; preserve ordinary values and the existing explicit key exclusions. Duplicate and paste share this helper. Tests cover actual node-id and port-id collisions, input text and rename text, and identity arrays versus value arrays. This uses the PR's identity-key convention (`id`, `*ID`, `*IDs`), not a new plugin serialization schema.

**P2 — Carry String Split's parked separator as settings when patching a clone.** Clone patching assumes a changed node's non-placement/non-port state is represented by its NodeSettings. String Split gives only its strategy, while its encoded customSeparator survives outside Custom mode. Edit the separator to `::` and switch to Comma through setStrategy: the source parks `::`, its sibling parks its own old separator, and the sibling is no longer in step. Undo/redo and saving/reopening retain the divergence. Even unrelated edits can leave two members with different published separator values marked out of step because encode duplicates the live inlet into this unfiltered field.

Fix: give String Split one StringSplitSettings value carrying the strategy and parked separator, with a procedural initializer and backward-compatible decoding defaults. The strategy API commits both; applying the complete value carries the parked design state. Encode the live separator in its port and the parked separator separately, so published inlet values remain each member's own. Legacy strategy-only apply calls still park the current inlet as before. The clone patch machinery can then use its existing Graph.setSettings path without bespoke knowledge of String Split.

## Reproductions and validation

`CloneSetReviewRegressionTests` contains 5 tests / 6 cases. Identical test source run against original and fixed production files:

- Actual-id text collision on duplicate (2 cases), and the shared JSON substitution helper.
- Clone mode change, settings sync, Graph.undo/redo, stored-design agreement, save/reopen.
- Giving/taking the complete settings of a node with a parked separator.
- Unrelated clone edit with different published separator values: each remains local and siblings remain in step.

Before: **5 tests fail, 14 assertions**. After: **all 5 pass**.

- Original Fabric Editor Debug arm64 build: success. Baseline selection: **366 tests / 28 suites passed** (including upstream clone contract/model suites).
- Final expanded selection: **405 tests / 31 suites passed**.
- Fixed Fabric Editor Debug arm64 build: **success**.
- Actual Metal required by new tests; portable production-plus-test patch verified on pristine upstream files and byte-compared to the reviewed source.

## Design and contribution assessment

Reviewed clone-set storage/instantiation, design-vs-member values, coordinator group-close behavior, planned in-place patches, membership/unlinking, identity remapping, serialization changes, navigation, context-menu and parameter-view changes against AGENTS.md, README, ARCHITECTURE, GLOSSARY and NODES. In-place settings edits and graph-owned undo/topology follow the project design; existing tests cover nested sets, failure atomicity, retained node objects, independent values, and undo after sibling changes. The String Split gap violates the whole-settings-value contract on which the patcher relies; the fix restores that contract and reuses the public graph edit path. No new frameworks, lifecycle calls from editing paths, or project settings changes.

## Limits and reuse

macOS arm64 Debug and model/API tests only. Context-menu/alert/breadcrumb interaction and iOS/visionOS builds were not exercised. No claim of full rendered visual correctness. Intentionally invalid script/shader probes emit compiler diagnostics while passing their expected-failure tests. Earlier PR review fixes remain separate and may still be required when integrating the whole stack.

See exact commands, PR metadata/discussions, compressed incremental diff, original/fixed build and test logs, before/after reproductions, guideline snapshots, package resolutions, `trial-fixes.patch`, and checksums. Xcode resolved within manifest ranges; its actual pins and diff are retained and the tracked pin file restored.
