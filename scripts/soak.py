#!/usr/bin/env python3
"""Measured real-process MCP soak. Usage: binary config workspace seconds."""
from protocol_test import Client
import json, os, statistics, sys, time
binary, config, workspace, seconds = sys.argv[1:]
c = Client(binary, config)
c.tool('azu_index_refresh', workspace=workspace)
start = time.monotonic(); samples=[]; rss=[]; calls=0
try:
    while time.monotonic()-start < int(seconds):
        tick=time.monotonic()
        result=c.tool('azu_docs_search',workspace=workspace,query='Endpoint',repository='azu')
        samples.append((time.monotonic()-tick)*1000)
        c.tool('azu_runtime_snapshot',workspace=workspace)
        c.tool('azu_capabilities',workspace=workspace)
        calls += 3
        if os.path.exists(f'/proc/{c.process.pid}/status'):
            lines=open(f'/proc/{c.process.pid}/status').read().splitlines()
            rss.append(int(next(x for x in lines if x.startswith('VmRSS:')).split()[1]))
        if calls%180 == 0:
            print(json.dumps({'seconds':round(time.monotonic()-start),'calls':calls,'rss_kib':rss[-1] if rss else None}),flush=True)
        time.sleep(max(0,1-(time.monotonic()-tick)))
finally:
    c.close()
ordered=sorted(samples)
print(json.dumps({'elapsed_seconds':time.monotonic()-start,'calls':calls,'search_p95_ms':ordered[int(.95*(len(ordered)-1))], 'rss_initial_kib':rss[0] if rss else None,'rss_max_kib':max(rss) if rss else None,'rss_final_kib':rss[-1] if rss else None,'clean_exit':True}),flush=True)
