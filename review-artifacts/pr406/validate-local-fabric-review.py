from pathlib import Path
import subprocess,concurrent.futures
OUT=Path('/private/tmp/fabric-copilot-validation')
SELECTION='Settings|TypingUndo|Undo|Publishing|ProxyPort|SubgraphEmbedding|GraphConnectionOwnership|GraphNodeLifecycle|PortHydration|MathExpression|JavaScript|Timeline|Routing|DeviceOutput|DeclaredPorts|CloneSet|GraphDuplication|NoteCoding|StringSplit|FormatString|StringFormatter|ReviewRegression|ReviewUndo|UndoFix|Copilot|GraphAutoLayout|EditUndo'
def run(n):
 p=Path(f'/Users/andre/.codex/worktrees/review-pr{n}/Fabric');out=OUT/str(n)
 commands=[(['swift','test','--filter',SELECTION],'local-tests'),(['xcodebuild','-project','Fabric.xcodeproj','-scheme','Fabric Editor','-configuration','Debug','-destination','platform=macOS,arch=arm64','-derivedDataPath',f'/private/tmp/fabric-pr{n}-derived','-clonedSourcePackagesDirPath','/private/tmp/fabric-pr406-derived/SourcePackages','-xcconfig','/private/tmp/fabric-pr406-build.xcconfig','-skipMacroValidation','CODE_SIGNING_ALLOWED=NO','build'],'local-editor')]
 for command,label in commands:
  with (out/(label+'.log')).open('w') as log:r=subprocess.run(command,cwd=p,stdout=log,stderr=subprocess.STDOUT)
  print(n,label,r.returncode,flush=True)
 subprocess.run(['git','restore','--source=HEAD','--','Fabric.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'],cwd=p,check=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(run,range(406,412)))
