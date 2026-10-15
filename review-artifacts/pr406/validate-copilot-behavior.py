from pathlib import Path
import subprocess,concurrent.futures
ROOT=Path('/Users/andre/.codex/worktrees');OUT=Path('/private/tmp/fabric-copilot-validation')
BASE={406:'d1015950',407:'f5f3ff13',408:'69c44189',409:'f0640019',410:'c821b86b',411:'6841b082'}
REF={406:'stack/1-undo-foundation',407:'stack/2-publishing-events',408:'stack/3-settings-value',409:'stack/4-create-subgraph',410:'stack/5-declared-ports',411:'stack/6-clone-sets'}
def git(p,*a):return subprocess.check_output(['git',*a],cwd=p)
for n in BASE:
 p=ROOT/f'review-pr{n}/Fabric'
 subprocess.run(['git','restore','--source=HEAD','--','Fabric.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'],cwd=p,check=True)
subprocess.run(['python3','/private/tmp/add-copilot-response-probes.py'],check=True)
def run(n):
 p=ROOT/f'review-pr{n}/Fabric';ref='fork/'+REF[n];out=OUT/str(n)
 production=set(git(p,'diff','--name-only',BASE[n],'HEAD','--','Fabric','Fabric Editor').decode().splitlines())
 changed=set(git(p,'diff','--name-only',BASE[n],ref).decode().splitlines())
 paths=production|changed|{'Tests/UndoFixRegressionTests.swift' if n==406 else 'Tests/DocumentSaveReviewRegressionTests.swift'}
 backup={s:(p/s).read_bytes() if (p/s).exists() else None for s in paths}
 try:
  for s in production|changed:(p/s).write_bytes(git(p,'show',ref+':'+s))
  if n==406:
   source=p/'Fabric/Views/Parameters/ParameterObservableModel.swift';source.write_text(source.read_text().replace('let commit = {','let commit: () -> Void = {'))
   source=p/'Tests/UndoFixRegressionTests.swift';t=source.read_text();a=t.index('    @Test("Flushing one manager');b=t.index('    @Test("An empty layout');source.write_text(t[:a]+t[b:])
  if n==407:
   source=p/'Fabric/Graph/Node/Node.swift';source.write_text(source.read_text().replace('private func refreshConnectionTopology()', 'internal func refreshConnectionTopology()'))
   source=p/'Fabric/Nodes/Object/SubGraph/SubgraphNode.swift';source.write_text(source.read_text().replace('self.inputNodes = self.calcInputNodes()\n        self.outputNodes = self.calcOutputNodes()\n        self.graph?.markNodeForLifecycleReview(self)','self.refreshConnectionTopology()'))
  if n==408:
   source=p/'Fabric Editor/FabricDocument.swift';source.write_text(source.read_text().replace('try self.synchronizeGraphSnapshotForSave(graph: graph)','try MainActor.assumeIsolated { try self.synchronizeGraphSnapshotForSave(graph: graph) }'))
   subprocess.run(['python3','review-artifacts/pr408/make-save-probe.py'],cwd=p,check=True)
  if n==411:
   source=p/'Fabric/Nodes/Parameters/String/StringSplitNode.swift';t=source.read_text();a=t.index('    /// Parks what the Separator');b=t.index('    /// The String inlet survives',a);source.write_text(t[:a]+t[b:])
  # This patch contains only the temporary compilation repairs, relative to Copilot.
  (out/'compile-repairs.patch').write_bytes(git(p,'diff',ref,'--','Fabric','Fabric Editor'))
  def execute(label):
   with (out/(label+'.log')).open('w') as log:r=subprocess.run(['swift','test','--filter','Copilot|Review|UndoFix'],cwd=p,stdout=log,stderr=subprocess.STDOUT)
   print(n,label,r.returncode,flush=True)
  execute('repaired-compile-tests')
  if n in [407,408]:
   for s in changed:
    if s.startswith('Tests/'):(p/s).write_bytes(git(p,'show',BASE[n]+':'+s))
   execute('repaired-behavior-tests')
 finally:
  for s,b in backup.items():
   if b is None:(p/s).unlink(missing_ok=True)
   else:(p/s).write_bytes(b)
  print(n,'restored',flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(run,[406,407,408,411]))
