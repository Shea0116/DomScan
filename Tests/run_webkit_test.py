"""Launch only a disposable WKWebView fixture and clean up its local HTTP servers."""
from pathlib import Path
import plistlib
import subprocess
import sys
import threading
from http.server import ThreadingHTTPServer
from fixture_server import Handler

app = Path(sys.argv[1]).resolve()
with (app / 'Contents/Info.plist').open('wb') as file:
    plistlib.dump({
        'CFBundleIdentifier': 'io.github.shea0116.domscan.wkfixture',
        'CFBundleExecutable': 'WKFixture', 'CFBundleName': 'WKFixture',
        'CFBundlePackageType': 'APPL',
        'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
    }, file)
servers = [ThreadingHTTPServer(('127.0.0.1', port), Handler) for port in (9471, 9472)]
for server in servers:
    threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    modes = set(sys.argv[2].split('-'))
    if 'sandbox' in modes:
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements',
                        str(Path(__file__).with_name('WKFixture.entitlements')), str(app)], check=True)
    flags = (['--serve'] if 'serve' in modes else []) + (['--observe'] if 'observe' in modes else [])
    result = subprocess.run([str(app / 'Contents/MacOS/WKFixture')] + flags,
                            timeout=1800 if 'serve' in modes else 120)
    sys.exit(result.returncode)
finally:
    for server in servers:
        server.shutdown()
        server.server_close()
