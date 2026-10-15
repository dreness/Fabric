from pathlib import Path
import subprocess,re,time
ROOT=Path('/Users/andre/.codex/worktrees');TMP=Path('/private/tmp/fabric-copilot-validation')
BASE={406:'d1015950',407:'f5f3ff13',408:'69c44189',409:'f0640019',410:'c821b86b',411:'6841b082'}
REF={406:'stack/1-undo-foundation',407:'stack/2-publishing-events',408:'stack/3-settings-value',409:'stack/4-create-subgraph',410:'stack/5-declared-ports',411:'stack/6-clone-sets'}
NOTES={
406:'Retain local production fix. Candidate fails compilation (optional-Void closure); after a closure type annotation it still fails 5 assertions: draft Undo availability, active pause timer, and engine change after focus. Two local tests of our private PendingCommit API were excluded from this candidate experiment; all behavioral tests remained. New test: CopilotUndoResponseTests.engineChangeAfterFocus.',
407:'Retain local production fix. Candidate cannot access private topology state. Temporary repair exposes a shared refresh helper and calls it from SubgraphNode; all 4 review reproductions then pass. Local fix already uses a shared helper, updates topology callbacks, and avoids extra refreshes on every add/remove/reorder.',
408:'Retain local production fix. Candidate invokes a main-actor method from a nonisolated save method; its new SwiftPM test also cannot see FabricDocument (editor target). Temporary assumeIsolated bridges plus our existing verbatim save-method harness pass both main/worker cases. Local fix has no forced Result unwrap and acquires the graph inside the synchronized snapshot.',
409:'Retain local production fix. Candidate builds but merely renames the eager proxy constructor; all 7 original failing assertions remain (live value loss and callbacks). Candidate additions do not assert supported-port value preservation after canProxy.',
410:'Candidate accepted as equivalent; no production changes needed. ParameterPort.adoptID matches our existing fix apart from formatting. Candidate selected tests and Fabric Editor build pass, including our formatter undo/redo and factory regressions.',
411:'Retain local production fix. Candidate has duplicate apply overrides. Temporary removal of the older override permits tests: 9 assertions fail across String Split clone/round-trip behavior and a nested identity-container helper case. Candidate still lacks complete setStrategy capture and parked-only encoding; its UUID identity context leaks into ordinary fields nested below an identity key. New test: CopilotUUIDResponseTests.nestedIdentityContainer.'}
for n in BASE:
 p=ROOT/f'review-pr{n}/Fabric';out=p/f'review-artifacts/pr{n}';logs=TMP/str(n)
 localtests=(logs/'local-tests.log').read_text();editor=(logs/'local-editor.log').read_text()
 while '** BUILD SUCCEEDED **' not in editor and '** BUILD FAILED **' not in editor:
  time.sleep(2)
  editor=(logs/'local-editor.log').read_text()
 assert 'Test run with' in localtests and re.search(r'Test run with .* passed',localtests),n
 assert '** BUILD SUCCEEDED **' in editor,n
 ref='fork/'+REF[n]
 sha=subprocess.check_output(['git','rev-parse',ref],cwd=p,text=True).strip()
 (out/'copilot-candidate.patch').write_bytes(subprocess.check_output(['git','diff',BASE[n],ref,'--','Fabric','Fabric Editor','Tests'],cwd=p))
 if (logs/'compile-repairs.patch').exists():(out/'copilot-compile-repairs.patch').write_bytes((logs/'compile-repairs.patch').read_bytes())
 sections=[f'Fork practice PR #{n-404}; upstream layer #{n}; Copilot candidate {sha}',NOTES[n],
 'Validation: real macOS/Metal; exact candidates tested first. Temporary compile repairs were diagnostic experiments only and were not adopted. No upstream comments or remote changes were made in this validation run.',
 'Exact candidate command: swift test --filter "Review|EditUndo|GraphAutoLayout|ProxyPortReplacement|SettingsUndo|GraphConnectionOwnership|PortHydration|GraphDuplication|StringSplitNode"',
 'Diagnostic repair command: swift test --filter "Copilot|Review|UndoFix" (406 omits two tests coupled to local PendingCommit APIs; 408 second run restores upstream SettingsUndoTests to use the save harness).',
 'Editor command: xcodebuild -project Fabric.xcodeproj -scheme "Fabric Editor" -configuration Debug -destination platform=macOS,arch=arm64 -derivedDataPath /private/tmp/fabric-prNNN-derived -clonedSourcePackagesDirPath /private/tmp/fabric-pr406-derived/SourcePackages -xcconfig /private/tmp/fabric-pr406-build.xcconfig -skipMacroValidation CODE_SIGNING_ALLOWED=NO build',
 'Focused excerpts below; full transient build output omitted. Existing shader diagnostics emitted by expected negative shader tests are not test failures.']
 for name in ['copilot-tests','copilot-editor','repaired-compile-tests','repaired-behavior-tests','local-tests','local-editor']:
  log=logs/(name+'.log')
  if not log.exists():continue
  selected=[]
  for line in log.read_text().splitlines():
   if ('recorded an issue' in line or 'Test run with' in line or '** BUILD ' in line or re.search(r':\d+:\d+: error:',line)) and not line.lstrip().startswith('|'):
    selected.append(line)
  sections+=['\n== '+name+' ==',*dict.fromkeys(selected)]
 (out/'copilot-validation.log').write_text('\n'.join(sections)+'\n')
 env=out/'environment.txt';e=env.read_text();e+='\nCopilot response validation (2026-10-15):\n'+f'Fork PR: https://github.com/dreness/Fabric/pull/{n-404}\nCandidate head: {sha}\n'+NOTES[n]+'\n'+next(l for l in localtests.splitlines() if 'Test run with' in l)+'\nFabric Editor Debug macOS arm64: BUILD SUCCEEDED.\n'
 env.write_text(e)
 # Include new tracked regression code in the refreshed portable local patch.
 subprocess.run(['git','add','--','Tests'],cwd=p,check=True)
 (out/'trial-fixes.patch').write_bytes(subprocess.check_output(['git','diff',BASE[n],'--','Fabric','Fabric Editor','Tests'],cwd=p))
 if n==406:
  for script in ['validate-copilot-fabric.py','validate-copilot-behavior.py','add-copilot-response-probes.py','validate-local-fabric-review.py','package-copilot-validation.py']:
   (out/script).write_bytes((Path('/private/tmp')/script).read_bytes())
 subprocess.run(['git','add','--',f'review-artifacts/pr{n}'],cwd=p,check=True)
 subprocess.run(['git','diff','--cached','--check','--','Fabric','Fabric Editor','Tests'],cwd=p,check=True)
 subprocess.run(['git','commit','-m',f'Validate Copilot response to practice review #{n-404}\n\nRetain the tested local fix and record focused candidate validation evidence.\n\nVia GPT-6'],cwd=p,check=True)
 print(n,subprocess.check_output(['git','rev-parse','--short','HEAD'],cwd=p,text=True).strip(),flush=True)
