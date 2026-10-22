import asyncio, json, os, pathlib, signal, subprocess, sys, tempfile, time, urllib.request
import websockets

project = pathlib.Path(__file__).resolve().parents[1]
profile = pathlib.Path(tempfile.mkdtemp(prefix='ds-engine.', dir='/private/tmp'))
logs = pathlib.Path(sys.argv[1]).resolve()
logs.mkdir(parents=True, exist_ok=True)
server = subprocess.Popen(['python3', str(project/'Tests/fixture_server.py')], stdout=subprocess.DEVNULL)
log = (logs/'custom-chromium-host.log').open('w')
process = None
launch_report = logs/'inspection-launch-process.json'
if launch_report.exists(): launch_report.unlink()
def get_json(url):
    with urllib.request.urlopen(url, timeout=2) as response:
        return json.load(response)
async def navigate_fixture(socket, target):
    async with websockets.connect(socket, max_size=2**20, proxy=None) as ws:
        await ws.send(json.dumps({'id': 1, 'method': 'Target.attachToTarget',
                                 'params': {'targetId':target, 'flatten':True}}))
        while True:
            reply = json.loads(await asyncio.wait_for(ws.recv(), 10))
            if reply.get('id') == 1:
                if 'error' in reply: raise RuntimeError(str(reply['error']))
                session = reply['result']['sessionId']; break
        async def evaluate(number, expression):
            await ws.send(json.dumps({'id':number,'sessionId':session,'method':'Runtime.evaluate',
                                     'params':{'expression':expression,'returnByValue':True}}))
            while True:
                reply=json.loads(await asyncio.wait_for(ws.recv(),10))
                if reply.get('id')==number:
                    if 'error' in reply: raise RuntimeError(str(reply['error']))
                    return reply.get('result',{}).get('result',{}).get('value')
        for attempt in range(100):
            ready=await evaluate(10+attempt,
                'document.readyState === "complete" && location.href.includes("index.html")')
            if ready: break
            await asyncio.sleep(.2)
        else: raise RuntimeError('Isolated application renderer not ready')
        await asyncio.sleep(.5)
        # Navigate only this disposable application window after its bootstrap has finished.
        await ws.send(json.dumps({'id':200,'sessionId':session,'method':'Page.navigate',
                                 'params':{'url':'http://127.0.0.1:9471/'}}))
        while True:
            reply=json.loads(await asyncio.wait_for(ws.recv(),10))
            if reply.get('id')==200:
                if 'error' in reply: raise RuntimeError(str(reply['error']))
                break

try:
    time.sleep(.5)
    if server.poll() is not None: raise RuntimeError('Fixture server failed')
    process = subprocess.Popen(['/Applications/ChatGPT.app/Contents/MacOS/ChatGPT',
        '--user-data-dir='+str(profile), '--remote-debugging-port=0',
        '--remote-debugging-address=127.0.0.1', '--no-first-run', '--no-default-browser-check',
        'about:blank'], stdout=log, stderr=log, start_new_session=True)
    deadline = time.monotonic()+20
    while time.monotonic()<deadline:
        port_file = profile/'DevToolsActivePort'
        if port_file.exists(): break
        if process.poll() is not None: raise RuntimeError('Isolated app exited')
        time.sleep(.2)
    port = int(port_file.read_text().splitlines()[0])
    endpoint = 'http://127.0.0.1:'+str(port)
    version = get_json(endpoint+'/json/version')
    for _ in range(100):
        targets=get_json(endpoint+'/json/list')
        pages=[t for t in targets if t.get('type') in ('page','webview')]
        if pages: break
        time.sleep(.2)
    else: raise RuntimeError('No HTML target after startup; types: '+str([t.get('type') for t in targets]))
    asyncio.run(navigate_fixture(version['webSocketDebuggerUrl'],pages[0]['id']))
    for _ in range(100):
        targets = get_json(endpoint+'/json/list')
        if any(t.get('title')=='Selector Fixture · Desktop' for t in targets): break
        time.sleep(.2)
    else: raise RuntimeError('Fixture page not ready')
    print('PASS custom Chromium exposes a local target in an isolated profile', flush=True)
    entry = subprocess.run([str(logs/'engine-entry-test'),str(process.pid),str(project)],
                           capture_output=True,text=True,timeout=50)
    print(entry.stdout,flush=True)
    (logs/'renamed-entry-test.log').write_text(entry.stdout+entry.stderr)
    if entry.returncode: raise RuntimeError(entry.stdout+entry.stderr)
    core = subprocess.run([str(logs/'integration-test'),str(project/'Resources/picker.js'),
        endpoint,str(logs/'renamed-engine-capture')],capture_output=True,text=True,timeout=100)
    print(core.stdout,flush=True)
    (logs/'renamed-core-test.log').write_text(core.stdout+core.stderr)
    if core.returncode: raise RuntimeError(core.stdout+core.stderr)
    if os.environ.get('SELECTOR_RUN_LAUNCH_TEST')=='1':
        launch_root=tempfile.mkdtemp(prefix='ds-launch.',dir='/private/tmp')
        launch=subprocess.run([str(logs/'inspection-launch-test'),str(process.pid),str(project),
            launch_root,str(launch_report)],capture_output=True,text=True,timeout=90)
        print(launch.stdout,flush=True)
        (logs/'inspection-launch-test.log').write_text(launch.stdout+launch.stderr)
        if launch.returncode: raise RuntimeError(launch.stdout+launch.stderr)
    if os.environ.get('SELECTOR_HOLD_TEST_HOST')=='1':
        print('Holding isolated fixture for UI verification, maximum 180 seconds', flush=True)
        release=logs/'release-renamed-host'
        for _ in range(900):
            if release.exists(): break
            time.sleep(.2)
finally:
    if launch_report.exists():
        owned=json.loads(launch_report.read_text())
        if str(owned.get('profile','')).startswith('/private/tmp/ds-launch.'):
            try: os.kill(int(owned['pid']),signal.SIGTERM)
            except ProcessLookupError: pass
    if process:
        try: os.killpg(process.pid,signal.SIGTERM)
        except ProcessLookupError: pass
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL); process.wait(timeout=3)
    server.terminate()
    server.wait(timeout=5)
    log.close()
