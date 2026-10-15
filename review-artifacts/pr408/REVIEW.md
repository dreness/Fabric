# PR 408 review — Settings value

**One P1 finding; local fix and regression included.** Review only `f5f3ff13..69c44189`, not local `main`.

## P1: a background save can write the old shader

Upstream `Fabric Editor/FabricDocument.swift:392–413` dispatches shader reconciliation asynchronously to the main queue, then encodes the graph immediately on the background writer. Edit a Live Image shader on disk, then save from a background thread while the main queue is busy: that save contains the previous shader. The queued edit can also race encoding. Depending on a later save loses the normal guarantee that this save contains the edit already on disk.

**Fix:** perform shader reconciliation, file-reference rewriting, graph encoding and `lastWrittenGraph` assignment together on the main thread. A background writer synchronously waits for that snapshot; a main-thread writer executes directly. Shader capture remains a graph settings edit, so undo restores the old source and open drafts follow it. No mutation moved back into `Node.encode`.

**Reproduction:** `DocumentSaveReviewRegressionTests` executes a verbatim copy of the actual `fileWrapper` body in a minimal document shell. A shader is edited on disk, a worker saves while the main queue is briefly held, and the saved bytes and undo result are checked. Both main-thread and worker cases run. On upstream: main-thread case passes, worker case fails two assertions. With fix: both pass. `make-save-probe.py --upstream` regenerates the upstream method; without the flag it copies the local method. Expectations are unchanged. This is a save-method integration harness, not a full SwiftUI document/UI test.

## Guidelines and scope

The migration follows the settings-value design: shared `NodeSettings`, public settings initializers, graph-owned undo groups, drafts and flattened existing document keys. Reviewed the node/view migrations, port restoration, menu-state caching and shader saving against AGENTS, ARCHITECTURE, GLOSSARY and NODES. The fix preserves those contracts and removes the save's asynchronous sequencing hazard. Main-thread snapshot/compilation can block the UI for a large graph; native save-dialog/autosave behavior was not exercised. A future immutable document snapshot would allow encoding off the UI thread safely.

Port declaration/order is explicitly deferred to #410 and Create Subgraph to #409. Earlier local review fixes are not included; this branch starts at the upstream #408 head.

An exploratory nil-value finding was **discarded**. `ParameterPort.value` intentionally replaces nil with its parameter's resting value. The original probe failed to assert its precondition and tested an impossible state; its failures are not PR defects. No nil-restoration changes remain. The discarded source/logs are retained as analysis evidence only.

## Validation

- Original PR: Editor build succeeds; 229 tests / 22 suites pass.
- Confirmed save reproduction: 1 parameterized test / 2 cases, upstream fails 2 assertions only in worker case; fixed passes.
- Fixed branch: 230 tests / 23 suites pass, including settings undo, publishing/proxies, port hydration, JavaScript/Math Expression, graph ownership/lifecycle and native typing-undo tests.
- Fixed Editor: **BUILD SUCCEEDED** (Debug arm64, signing off).
- Actual Metal required by the added regression; absence fails instead of silently skipping.

Build flags, toolchain, exact PR metadata/diff, dependency resolutions, discussions, portable patch and raw logs are alongside this report. Large logs are gzip compressed to keep the branch diff readable. `commands.txt` contains the build/test commands. Package resolution changes from Xcode were captured and reverted, not included as source changes. No push or upstream comment/review.
