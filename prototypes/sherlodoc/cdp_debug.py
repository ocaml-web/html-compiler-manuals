#!/usr/bin/env python3
import json, time, urllib.request, websocket, sys

PORT = open('/tmp/sherlo_port').read().strip().split('=')[1]
URL = f'http://127.0.0.1:{PORT}/ocaml/Stdlib/index.html'

tabs = json.load(urllib.request.urlopen('http://127.0.0.1:9222/json'))
ws_url = [t for t in tabs if t.get('type') == 'page'][0]['webSocketDebuggerUrl']
ws = websocket.create_connection(ws_url, max_size=None)
_id = 0
def call(method, params=None):
    global _id; _id += 1; mid = _id
    ws.send(json.dumps({'id': mid, 'method': method, 'params': params or {}}))
    while True:
        m = json.loads(ws.recv())
        if m.get('id') == mid:
            if 'error' in m: raise RuntimeError(m['error'])
            return m.get('result', {})
def ev(expr, timeout=40):
    r = call('Runtime.evaluate', {'expression': expr, 'returnByValue': True,
                                  'awaitPromise': True, 'timeout': timeout*1000})
    if 'exceptionDetails' in r:
        return {'EXC': r['exceptionDetails'].get('text'),
                'detail': str(r['exceptionDetails'].get('exception', {}).get('description',''))[:300]}
    return r.get('result', {}).get('value')

call('Page.enable'); call('Runtime.enable')
call('Page.navigate', {'url': URL}); time.sleep(2.0)

print('location :', ev('document.location.href'))
print('has bar  :', ev('!!document.querySelector(".search-bar")'))
print('resolved search_urls:', ev(
  '(function(){try{return search_urls.map(u=>{let p=location.href.split("/");'
  'p[p.length-1]=u;return p.join("/");});}catch(e){return "ERR:"+e;}})()'))

# Build the worker exactly like odoc, post a query, capture message/error.
probe = r'''
new Promise((resolve) => {
  try {
    const urls = search_urls.map(u => { let p = location.href.split("/"); p[p.length-1]=u; return '"'+p.join("/")+'"'; });
    const blob = new Blob(["importScripts("+urls.join(",")+");"], {type:"application/javascript"});
    const w = new Worker(URL.createObjectURL(blob));
    let done = false;
    w.onmessage = (e) => { if(done) return; done=true;
      let d = e.data;
      resolve({kind:"message", n: Array.isArray(d)?d.length:("not-array:"+typeof d),
               sample: Array.isArray(d)? d.slice(0,3).map(x=>({url:x.url, html:(x.html||"").replace(/<[^>]*>/g,"").slice(0,80)})) : d});
    };
    w.onerror = (e) => { if(done) return; done=true; resolve({kind:"error", msg: e.message, filename:e.filename, lineno:e.lineno}); };
    w.postMessage("List.map");
    setTimeout(()=>{ if(!done){done=true; resolve({kind:"timeout"});} }, 30000);
  } catch(e) { resolve({kind:"throw", err: String(e)}); }
})
'''
print('\n=== direct worker probe (query "List.map") ===')
print(json.dumps(ev(probe), indent=2, ensure_ascii=False))
ws.close()
