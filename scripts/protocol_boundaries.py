#!/usr/bin/env python3
"""Negative framing and live compiler cancellation against the native binary."""
import json, os, pathlib, select, subprocess, sys, tempfile, time
binary=os.path.abspath(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='azu-mcp-boundaries-') as directory:
    root=pathlib.Path(directory); (root/'src').mkdir()
    (root/'src/main.cr').write_text('value = 1\n')
    (root/'shard.yml').write_text('name: probe\nversion: 0.1.0\n')
    compiler=root/'compiler'; child=root/'child.pid'
    compiler.write_text(f'#!/bin/sh\nsleep 60 &\necho $! > "{child}"\nwait\n');compiler.chmod(0o700)
    config=root/'config.json'
    config.write_text(json.dumps({'state_dir':str(root/'state'),'workspaces':{'probe':{'root':str(root),'trusted':True,'crystal':str(compiler)}}}))
    p=subprocess.Popen([binary,'serve','--config',str(config)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    def send(value):
        p.stdin.write((json.dumps(value)+'\n').encode());p.stdin.flush()
    def read():
        assert select.select([p.stdout],[],[],5)[0], 'Response deadline exceeded'
        return json.loads(p.stdout.readline())
    def req(id,method,params=None):
        data={'jsonrpc':'2.0','id':id,'method':method}
        if params is not None:data['params']=params
        send(data);return read()
    assert 'error' in req(1,'initialize',{})
    assert 'result' in req(2,'initialize',{'protocolVersion':'2025-06-18','clientInfo':{'name':'negative-test','version':'1'},'capabilities':{}})
    assert 'tools' in req(3,'tools/list')['result']
    send({'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'azu_type_at','arguments':{'workspace':'probe','path':'src/main.cr','line':0,'character':0}}})
    deadline=time.monotonic()+5
    while not child.exists() and time.monotonic()<deadline:time.sleep(.01)
    assert child.exists(), 'Compiler fixture did not start'
    send({'jsonrpc':'2.0','method':'notifications/cancelled','params':{'requestId':4,'reason':'test'}})
    response=req(5,'ping');assert response['id']==5 and 'result' in response
    pid=int(child.read_text())
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        try:
            os.kill(pid,0)
            status=pathlib.Path(f'/proc/{pid}/stat')
            if status.exists() and status.read_text().split()[2]=='Z':break
        except ProcessLookupError:break
        time.sleep(.01)
    else:raise AssertionError('Compiler descendant survived cancellation')
    p.stdin.close();p.wait(timeout=10);assert p.returncode==0,p.stderr.read().decode()
    p=subprocess.Popen([binary,'serve','--config',str(config)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:p.stdin.write(b'x'*(1048576+1)+b'\n');p.stdin.flush()
    except BrokenPipeError:pass
    p.wait(timeout=10);assert p.returncode==0
print('Invalid initialization recovery, omitted params, compiler cancellation, descendant cleanup and oversized framing passed')
