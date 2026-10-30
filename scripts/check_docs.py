#!/usr/bin/env python3
import pathlib,re,sys
root=pathlib.Path(__file__).resolve().parents[1]
errors=[]
for path in [root/'README.md',*(root/'docs').glob('*.md')]:
    text=path.read_text()
    for link in re.findall(r'\]\(([^)]+)\)',text):
        if '://' in link or link.startswith('#'):continue
        if not (path.parent/link.split('#')[0]).exists():errors.append(f'{path}: missing {link}')
summary=(root/'docs/SUMMARY.md').read_text()
for page in (root/'docs').glob('*.md'):
    if page.name!='SUMMARY.md' and f'({page.name})' not in summary:errors.append(f'Not in SUMMARY: {page.name}')
source=(root/'src/azu_mcp/server.cr').read_text();docs=(root/'docs/tools.md').read_text()
for tool in set(re.findall(r'"(azu_[a-z_]+)"',source)):
    if f'`{tool}`' not in docs:errors.append(f'Undocumented tool: {tool}')
if errors:print('\n'.join(errors));sys.exit(1)
print('GitBook links, navigation and tool coverage passed')
