#!/usr/bin/env python3
"""Independent stdlib client; newline JSON MCP, never SDK implementation mocks."""
import json, os, subprocess, sys, time, select

class Client:
    def __init__(self, binary, config):
        self.process = subprocess.Popen([binary, 'serve', '--config', config], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.number = 0
        self.call('initialize', {'protocolVersion':'2025-06-18','clientInfo':{'name':'azu-integration','version':'1'},'capabilities':{}})
        self.notify('notifications/initialized', {})
    def notify(self, method, params):
        self.process.stdin.write((json.dumps({'jsonrpc':'2.0','method':method,'params':params})+'\n').encode()); self.process.stdin.flush()
    def call(self, method, params):
        self.number += 1
        message = {'jsonrpc':'2.0','id':self.number,'method':method,'params':params}
        self.process.stdin.write((json.dumps(message)+'\n').encode()); self.process.stdin.flush()
        if not select.select([self.process.stdout],[],[],90)[0]: raise TimeoutError(method)
        line = self.process.stdout.readline()
        if not line: raise RuntimeError(self.process.stderr.read().decode())
        result = json.loads(line)
        assert result['id'] == self.number, result
        assert 'error' not in result, result
        return result['result']
    def tool(self, name, **args):
        value = self.call('tools/call',{'name':name,'arguments':args})
        assert not value.get('isError'), value
        return value['structuredContent']
    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert self.process.returncode == 0, self.process.stderr.read().decode()

if __name__ == '__main__':
    binary, config, workspace = sys.argv[1:4]
    c = Client(binary,config)
    names = [t['name'] for t in c.call('tools/list',{})['tools']]
    assert len(names) == len(set(names)) and len(names) >= 30
    for t in c.call('tools/list',{})['tools']:
        assert t['inputSchema']['additionalProperties'] is False
    assert len(c.call('prompts/list',{})['prompts']) == 5
    assert len(c.call('resources/list',{})['resources']) >= 4
    c.call('prompts/get',{'name':'diagnose_job','arguments':{'workspace':workspace}})
    c.call('resources/read',{'uri':f'azu://{workspace}/context'})
    listing = c.tool('azu_toolkit_list',workspace=workspace)['result']
    assert len(listing)==8
    assert {x['repository'] for x in listing} == {'azu','azu_cli','cql','joobq','joobq-pro','authly','session','schema'}
    c.tool('azu_workspace_inspect',workspace=workspace)
    c.tool('azu_index_refresh',workspace=workspace)
    search = c.tool('azu_docs_search',workspace=workspace,query='Endpoint',repository='azu')
    assert search['results'], search
    for args in [dict(workspace=workspace,repository='authority',path='README.md'),dict(workspace=workspace,repository='azu',path='../README.md'),dict(workspace=workspace,repository='azu',path='.env')]:
        assert c.call('tools/call',{'name':'azu_source_read','arguments':args})['isError']
    assert c.call('tools/call',{'name':'azu_workspace_inspect','arguments':{'workspace':workspace,'approved':True}})['isError']
    c.tool('azu_runtime_snapshot',workspace=workspace)
    c.close()
    print('Protocol discovery, prompts/resources, indexing, citations, exclusion and argument-boundary checks passed')
