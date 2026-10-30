import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { readFileSync } from 'node:fs';
import { setTimeout as delay } from 'node:timers/promises';
const [binary, config, workspace, duration = '1800'] = process.argv.slice(2);
const client = new Client({name:'azu-concurrent-soak',version:'1'});
const transport = new StdioClientTransport({command:binary,args:['serve','--config',config],stderr:'pipe'});
await client.connect(transport);
transport.stderr.on('data', () => {});
const call = async (name, args = {}) => {
  const result = await client.callTool({name,arguments:{workspace,...args}});
  if(result.isError) throw Error(JSON.stringify(result));
  return result;
};
await call('azu_index_refresh');
const started = performance.now(), latency = [], memory = [];
let calls = 0, tick = 0;
try {
  while(performance.now() - started < Number(duration)*1000) {
    const begin = performance.now();
    await Promise.all([
      (async () => { const at=performance.now(); await call('azu_docs_search',{query:'Endpoint',repository:'azu'}); latency.push(performance.now()-at); })(),
      call('azu_runtime_snapshot'), call('azu_capabilities'),
      ...(tick % 60 === 0 ? [call('azu_index_refresh')] : [])
    ]);
    calls += tick % 60 === 0 ? 4 : 3;
    try { memory.push(Number(readFileSync(`/proc/${transport.pid}/status`,'utf8').match(/VmRSS:\s+(\d+)/)[1])); } catch {}
    if (++tick % 60 === 0) console.log(JSON.stringify({seconds:Math.round((performance.now()-started)/1000),calls,rss_kib:memory.at(-1)}));
    await delay(Math.max(0,1000-(performance.now()-begin)));
  }
} finally { await client.close(); }
latency.sort((a,b)=>a-b);
console.log(JSON.stringify({elapsed_seconds:(performance.now()-started)/1000,calls,concurrent_requests:4,search_p95_ms:latency[Math.floor(.95*(latency.length-1))],rss_initial_kib:memory[0],rss_max_kib:memory.length?Math.max(...memory):null,rss_final_kib:memory.at(-1),clean_exit:true}));
