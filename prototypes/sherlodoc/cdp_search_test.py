#!/usr/bin/env python3
# Drive the real odoc search page via Chrome DevTools Protocol:
# navigate -> type a query into .search-bar -> wait for the Web Worker
# (sherlodoc.js + db.js) to render into .search-result -> report hits.
import json, time, sys, urllib.request
import websocket  # websocket-client

PORT = open('/tmp/sherlo_port').read().strip().split('=')[1]
URL = f'http://127.0.0.1:{PORT}/ocaml/Stdlib/index.html'

def ws_url():
    for _ in range(20):
        try:
            tabs = json.load(urllib.request.urlopen('http://127.0.0.1:9222/json'))
            pages = [t for t in tabs if t.get('type') == 'page']
            if pages:
                return pages[0]['webSocketDebuggerUrl']
        except Exception:
            pass
        time.sleep(0.3)
    sys.exit('no CDP page target')

ws = websocket.create_connection(ws_url(), max_size=None)
_id = 0
def call(method, params=None):
    global _id
    _id += 1
    mid = _id
    ws.send(json.dumps({'id': mid, 'method': method, 'params': params or {}}))
    while True:
        msg = json.loads(ws.recv())
        if msg.get('id') == mid:
            if 'error' in msg:
                raise RuntimeError(f"{method}: {msg['error']}")
            return msg.get('result', {})

def ev(expr):
    r = call('Runtime.evaluate',
             {'expression': expr, 'returnByValue': True, 'awaitPromise': True})
    return r.get('result', {}).get('value')

call('Page.enable'); call('Runtime.enable')
call('Network.enable'); call('Network.setCacheDisabled', {'cacheDisabled': True})
call('Page.navigate', {'url': URL + '?v=2'})
time.sleep(2.0)  # let page + odoc_search.js load
print('loaded :', ev('document.location.href'))
print('order  :', ev('typeof search_urls !== "undefined" ? JSON.stringify(search_urls) : "undef"'))

def search(q, timeout=25):
    # odoc_search.js creates the Web Worker lazily on the search bar's "focus"
    # event, then answers "input" events -> focus first, then set value + input.
    js_set = ('(() => { const i = document.querySelector(".search-bar");'
              'if (!i) return false;'
              'i.focus(); i.dispatchEvent(new Event("focus"));'
              'i.value = %s;'
              'i.dispatchEvent(new Event("input", {bubbles:true}));'
              'return true; })()' % json.dumps(q))
    if not ev(js_set):
        return '<<no .search-bar on page>>'
    deadline = time.time() + timeout
    last = ''
    while time.time() < deadline:
        txt = ev('(() => { const r = document.querySelector(".search-result");'
                 'return r ? r.innerText : ""; })()') or ''
        if txt.strip():
            last = txt
            # give it a beat to finish appending all hits, then settle
            time.sleep(0.6)
            txt2 = ev('(() => { const r = document.querySelector(".search-result");'
                      'return r ? r.innerText : ""; })()') or ''
            return txt2 or last
        time.sleep(0.4)
    return last or '<<no results before timeout>>'

queries = [
    ('STDLIB name',            'List.map'),
    ('STDLIB type (polarity)', ': (\'a -> \'b) -> \'a list -> \'b list'),
    ('COMPILER-LIBS name',     'Cmt_format.read'),
    ('COMPILER-LIBS produce',  ': Env.t'),
]
for label, q in queries:
    print(f'\n===== {label}: {q!r} =====')
    res = search(q)
    lines = [l for l in res.splitlines() if l.strip()][:5]
    print('\n'.join('  ' + l for l in lines) if lines else '  (empty)')

ws.close()
