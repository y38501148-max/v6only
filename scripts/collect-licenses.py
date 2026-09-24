"""Collect notices from the exact Go module versions used by release builds."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
subprocess.run(['go', 'mod', 'download'], cwd=root/'core', check=True)
manifest = json.loads(subprocess.check_output(['go', 'mod', 'edit', '-json'], cwd=root/'core', text=True))
required = [module['Path'] for module in manifest['Require']]
data = subprocess.check_output(['go', 'list', '-m', '-json', *required], cwd=root/'core', text=True)
decoder = json.JSONDecoder()
modules = []
while data.strip():
    module, end = decoder.raw_decode(data.lstrip())
    data = data.lstrip()[end:]
    if module.get('Main'):
        continue
    source = Path(module['Dir'])
    notices = [p for p in source.iterdir() if p.is_file() and p.name.upper().split('.')[0] in ('LICENSE', 'COPYING', 'NOTICE', 'PATENTS')]
    if not notices:
        raise RuntimeError(f"No license found for {module['Path']}")
    target = out/(module['Path'].replace('/', '_')+'@'+module['Version'])
    target.mkdir(exist_ok=True)
    for notice in notices:
        shutil.copyfile(notice, target/notice.name)
    modules.append(f"- {module['Path']} {module['Version']}")
goroot = Path(subprocess.check_output(['go', 'env', 'GOROOT'], text=True).strip())
go_license = next((p for p in (goroot/'LICENSE', goroot.parent/'LICENSE') if p.is_file()), None)
if go_license is None:
    raise RuntimeError('Go distribution license is missing')
shutil.copyfile(go_license, out/'Go-LICENSE')
(out/'README.txt').write_text('Third-party components in v6only. See each component\'s license and notices.\n\n'+'\n'.join(modules)+'\n', encoding='utf-8')
