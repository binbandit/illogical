#!/usr/bin/env python3
"""Retain exact upstream notices for modules linked into the service.
Run after go mod changes. Uses go list for the active platform compile closure.
Names are unique when Xcode copies synchronized resource groups.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get('NOTICE_OUTPUT', str(ROOT/'illogical/Resources/Licenses/GoModules')))
platform = os.environ.get('GOOS', 'darwin')
go = os.environ.get('GO', 'go')
env = os.environ.copy()
env.setdefault('PKG_CONFIG_PATH', str(ROOT/'.build/ghostty/share/pkgconfig'))
raw = subprocess.check_output([go, 'list', '-deps', '-json', './cmd/illogical'], cwd=ROOT/'service', env=env, text=True)
decoder = json.JSONDecoder()
selected={}
while raw.strip():
    item, end = decoder.raw_decode(raw.lstrip())
    raw = raw.lstrip()[end:]
    module=item.get('Module')
    if module and not module.get('Main'):
        selected[module['Path']]=module
modules=[selected[path] for path in sorted(selected)]
OUT.mkdir(parents=True, exist_ok=True)
manifest=[]
missing=[]
for module in modules:
    directory=Path(module['Dir']) if module.get('Dir') else None
    if directory is None:
        downloaded=json.loads(subprocess.check_output([go,'mod','download','-json',module['Path']+'@'+module['Version']],cwd=ROOT/'service',text=True))
        directory=Path(downloaded['Dir'])
    files=sorted(p for p in directory.rglob('*') if p.is_file() and re.fullmatch(r'(LICENSE(?:\..*)?|COPYING(?:\..*)?|NOTICE(?:\..*)?|PATENTS(?:\..*)?)',p.name,re.I))
    if not files:
        missing.append(module['Path'])
    for source in files:
        relative=source.relative_to(directory)
        filename='GoModule-'+re.sub(r'[^a-zA-Z0-9.-]', '_', module['Path']+'-'+str(relative))+'.txt'
        dest=OUT/filename
        dest.parent.mkdir(parents=True,exist_ok=True)
        data=source.read_bytes()
        dest.write_bytes(data)
        manifest.append({'module':module['Path'],'version':module['Version'],'source':str(relative),'file':str(dest.relative_to(OUT)),'sha256':hashlib.sha256(data).hexdigest()})
if missing:
    raise SystemExit('Missing license files: '+', '.join(missing))
(OUT/'GoModules-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
lines=['# Go module notices ('+platform+')','','Exact upstream license, notice and patent files for modules in the selected platform service compile closure (`go list -deps ./cmd/illogical`). File SHA-256 values and original module-relative paths are in [GoModules-manifest.json](GoModules-manifest.json).','','| Module | Version | Retained notices |','| --- | --- | --- |']
for module in modules:
    entries=[entry for entry in manifest if entry['module']==module['Path']]
    links=', '.join('['+entry['source']+']('+entry['file']+')' for entry in entries)
    lines.append('| '+module['Path']+' | '+module['Version']+' | '+links+' |')
(OUT/'GoModules-INDEX.md').write_text('\n'.join(lines)+'\n')
print(f'Retained {len(manifest)} notice files for {len(modules)} modules')
