from pathlib import Path
import subprocess,concurrent.futures,time
ROOT=Path('/Users/andre/work/graphics/Fabric')
BASE=['d1015950','f5f3ff13','69c44189','f0640019','c821b86b','6841b082']
REF=['stack/1-undo-foundation','stack/2-publishing-events','stack/3-settings-value','stack/4-create-subgraph','stack/5-declared-ports','stack/6-clone-sets']
OUT=Path('/private/tmp/fabric-copilot-validation');OUT.mkdir(exist_ok=True)
def git(p,*args):return subprocess.check_output(['git',*args],cwd=p)
def run(n):
 p=Path(f'/Users/andre/.codex/worktrees/review-pr{n}/Fabric');base=BASE[n-406];ref='fork/'+REF[n-406]
 assert not git(p,'status','--porcelain').strip(), (n,'dirty')
 production=set(git(p,'diff','--name-only',base,'HEAD','--','Fabric','Fabric Editor').decode().splitlines())
 copilot=set(git(p,'diff','--name-only',base,ref).decode().splitlines())
 paths=production|copilot
 if n==406:paths.add('Tests/UndoFixRegressionTests.swift')
 if n==408:paths.add('Tests/DocumentSaveReviewRegressionTests.swift')
 backups={s:(p/s).read_bytes() if (p/s).exists() else None for s in paths}
 backupdir=OUT/str(n);backupdir.mkdir(exist_ok=True)
 for s,b in backups.items():
  if b is not None:
   target=backupdir/'backup'/s;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(b)
 try:
  for s in production|copilot:
   try:b=git(p,'show',ref+':'+s)
   except subprocess.CalledProcessError:continue
   (p/s).write_bytes(b)
  if n==406:(p/'Tests/UndoFixRegressionTests.swift').unlink()
  if n==408:subprocess.run(['python3','review-artifacts/pr408/make-save-probe.py'],cwd=p,check=True)
  def execute(cmd,label):
   with (backupdir/(label+'.log')).open('w') as log:r=subprocess.run(cmd,cwd=p,stdout=log,stderr=subprocess.STDOUT)
   print(n,label,r.returncode,flush=True)
  execute(['swift','test','--filter','Review|EditUndo|GraphAutoLayout|ProxyPortReplacement|SettingsUndo|GraphConnectionOwnership|PortHydration|GraphDuplication|StringSplitNode'],'copilot-tests')
  execute(['xcodebuild','-project','Fabric.xcodeproj','-scheme','Fabric Editor','-configuration','Debug','-destination','platform=macOS,arch=arm64','-derivedDataPath',f'/private/tmp/fabric-pr{n}-derived','-clonedSourcePackagesDirPath','/private/tmp/fabric-pr406-derived/SourcePackages','-xcconfig','/private/tmp/fabric-pr406-build.xcconfig','-skipMacroValidation','CODE_SIGNING_ALLOWED=NO','build'],'copilot-editor')
 finally:
  for s,b in backups.items():
   if b is None:(p/s).unlink(missing_ok=True)
   else:(p/s).write_bytes(b)
  print(n,'restored',git(p,'status','--porcelain').decode(),flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(run,range(406,412)))
