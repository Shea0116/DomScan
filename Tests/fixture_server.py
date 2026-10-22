#!/usr/bin/env python3
"""Local Chromium/Electron fixture, including same-origin and cross-site frames."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import threading
import sys

PORT = int(sys.argv[1]) if __name__ == '__main__' and len(sys.argv) > 1 else 9471
CROSS_PORT = PORT + 1
STYLE = """<style>
*{box-sizing:border-box}body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;background:#101624;color:#e9edf5;margin:0;padding:28px}h1{font-size:27px;font-weight:600}p{color:#9baac0;line-height:1.6}button{background:#a78bfa;color:#171125;border:0;border-radius:8px;padding:12px 18px;font-size:14px;cursor:pointer}input{background:#202a3a;color:white;border:1px solid #39475c;border-radius:7px;padding:11px;margin:10px}iframe{display:block;border:1px solid #33425a;border-radius:10px;width:100%;height:200px;margin-top:18px}section{background:#192234;padding:18px;border-radius:12px;margin-bottom:16px}small{color:#6ee7b7}#counter{padding:10px;color:#6ee7b7}
</style>"""


def page(path):
    if path == '/':
        return f"""<!doctype html><meta charset=utf-8><title>Selector Fixture · Desktop</title>{STYLE}
<small>DESKTOP SELECTOR / LOCAL FIXTURE</small><h1>真实元素，真实上下文。</h1>
<p>本地测试界面：包含同源、跨域、嵌套和动态 iframe，以及 Shadow DOM。<br>正常模式下按钮会计数；拾取模式下点击只会选择元素。</p>
<section id=main-card><button id=primary data-testid=save-button onpointerdown="window.pointerCount++" onclick="window.clickCount++;document.querySelector('#counter').textContent=window.clickCount">保存更改</button><input id=editor placeholder="正常输入不受影响"><span id=counter>0</span></section>
<div id=shadow-host></div><iframe id=same title="同源 frame" src=/same.html></iframe>
<iframe id=cross title="跨域 frame" src="http://localhost:{CROSS_PORT}/cross.html"></iframe>
<script>window.clickCount=0;window.pointerCount=0;const sr=document.querySelector('#shadow-host').attachShadow({{mode:'open'}});sr.innerHTML='<button id=shadow-button style="padding:10px;background:#6ee7b7;border:0;border-radius:8px">Shadow DOM 按钮</button>';</script>"""
    title = {'/same.html':'同源 iframe','/cross.html':'跨域 iframe','/nested.html':'嵌套 iframe','/dynamic.html':'动态 iframe'}.get(path,'Frame')
    extra = '<iframe id=nested title="nested frame" src=/nested.html></iframe>' if path == '/cross.html' else ''
    return f"""<!doctype html><meta charset=utf-8><title>{title}</title>{STYLE}<small>{title}</small>
<section><button id=frame-button onclick="window.clickCount++">{title}中的按钮</button><input placeholder="frame 内输入"></section>{extra}<script>window.clickCount=0</script>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = page(self.path.split('?')[0]).encode()
        self.send_response(200)
        self.send_header('Content-Type','text/html; charset=utf-8')
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


if __name__ == '__main__':
    other = ThreadingHTTPServer(('127.0.0.1', CROSS_PORT), Handler)
    threading.Thread(target=other.serve_forever,daemon=True).start()
    print(f'Fixture ready: http://127.0.0.1:{PORT}/ · cross-site port {CROSS_PORT}',flush=True)
    ThreadingHTTPServer(('127.0.0.1',PORT),Handler).serve_forever()
