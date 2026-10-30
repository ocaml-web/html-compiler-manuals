#!/usr/bin/env python3
import json, time, urllib.request, websocket

PORT = open('/tmp/sherlo_port').read().strip().split('=')[1]
BASE = f'http://127.0.0.1:{PORT}'
URL = f'{BASE}/ocaml/Stdlib/index.html'
tabs = json.load(urllib.request.urlopen('http://127.0.0.1:9222/json'))
ws_url = [t for t in tabs if t.get('type') == 'page'][0]['webSocketDebuggerUrl']
ws = websocket.create_connection(ws_url, max_size=None)
_id = 0
def call(m, p=None):
    global _id; _id += 1; mid=_id
    ws.send(json.dumps({'id': mid, 'method': m, 'params': p or {}}))
    while True:
        r = json.loads(ws.recv())
        if r.get('id') == mid: return r.get('result', {})
def ev(expr):
    r = call('Runtime.evaluate', {'expression': expr, 'returnByValue': True, 'awaitPromise': True})
    if 'exceptionDetails' in r: return {'EXC': str(r['exceptionDetails'])[:200]}
    return r.get('result', {}).get('value')

call('Page.enable'); call('Runtime.enable')
call('Page.navigate', {'url': URL}); time.sleep(1.5)

def probe(order):
    urls = ','.join("'%s/%s'" % (BASE, u) for u in order)
    js = r'''
    new Promise((resolve) => {
      try {
        const blob = new Blob(["importScripts(%s);"], {type:"application/javascript"});
        const w = new Worker(URL.createObjectURL(blob));
        let done=false;
        w.onmessage=(e)=>{if(done)return;done=true; let d=e.data;
          resolve({ok:true, n: Array.isArray(d)?d.length:("not-array:"+typeof d),
                    sample: Array.isArray(d)?d.slice(0,3).map(x=>(x.html||"").replace(/<[^>]*>/g,"").replace(/\s+/g," ").trim().slice(0,70)):d});};
        w.onerror=(e)=>{if(done)return;done=true; resolve({ok:false, err:e.message, line:e.lineno});};
        w.postMessage("List.map");
        setTimeout(()=>{if(!done){done=true;resolve({ok:false,err:"timeout"});}},25000);
      } catch(e){ resolve({ok:false, err:String(e)}); }
    })''' % urls
    return ev(js)

for order in (['sherlodoc.js','db.js'], ['db.js','sherlodoc.js']):
    print('import order', order, '->')
    print('  ', json.dumps(probe(order), ensure_ascii=False))
ws.close()
