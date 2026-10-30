#!/usr/bin/env python3
"""Create an isolated synthetic eight-repository protocol fixture."""
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]).resolve();root.mkdir(parents=True,exist_ok=True)
app=root/'app';app.mkdir(exist_ok=True)
(app/'shard.yml').write_text('name: fixture\nversion: 0.1.0\n')
repos={}
for name in ['azu','azu_cli','cql','joobq','joobq-pro','authly','session','schema']:
    repo=root/name;(repo/'src').mkdir(parents=True,exist_ok=True)
    (repo/'shard.yml').write_text(f'name: {name}\nversion: 1.0.0\n')
    (repo/'src/endpoint.cr').write_text('module Endpoint\n  # Deterministic protocol fixture, not a toolkit implementation.\nend\n')
    repos[name]=str(repo)
config={'state_dir':str(root/'state'),'workspaces':{'fixture':{'root':str(app),'repositories':repos}}}
(root/'config.json').write_text(json.dumps(config));print(root/'config.json')
