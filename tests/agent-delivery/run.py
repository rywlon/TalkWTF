"""Exercise delivery against a real loopback receiver; no external services."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import subprocess
import tempfile
import threading

received = []
class Receiver(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/redirect':
            self.send_response(307)
            self.send_header('Location', '/leak')
        elif self.path == '/fail':
            self.send_response(503)
        else:
            received.append((self.path, json.loads(body)))
            self.send_response(202)
        self.end_headers()
    def log_message(self, *_): pass

root = Path(__file__).resolve().parents[2]
server = ThreadingHTTPServer(('127.0.0.1', 0), Receiver)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory() as directory:
        executable = str(Path(directory) / 'agent-tests')
        subprocess.run(['swiftc', str(root / 'macos/TalkWTF/AgentTransport.swift'), str(root / 'macos/TalkWTF/AgentPairing.swift'), str(Path(__file__).with_name('pairing-checks.swift')), str(Path(__file__).with_name('main.swift')), '-o', executable], check=True)
        fixture = Path(directory) / 'fixture-agent'
        fixture.write_text('''#!/usr/bin/python3
import json, os, sys
args = sys.argv[1:]
if args == ['login', 'status']:
    sys.exit(0)
assert args[0] == '-C' and os.path.samefile(args[1], os.getcwd())
base = ['-C', args[1], '-s', 'workspace-write', 'exec']
expected = base + (['resume'] if 'resume' in args else []) + ['--skip-git-repo-check', '--json'] + (['fixture-session'] if 'resume' in args else []) + ['-']
assert args == expected, args
text = sys.stdin.read()
if text == 'timeout':
    import time
    print(json.dumps({'type': 'thread.started', 'thread_id': 'fixture-session'}), flush=True)
    time.sleep(30)
print(json.dumps({'type': 'thread.started', 'thread_id': 'fixture-session'}))
print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': text}}))
print(json.dumps({'type': 'turn.completed'}))
''')
        fixture.chmod(0o700)
        subprocess.run([executable, f'http://127.0.0.1:{server.server_port}', str(fixture), directory], check=True)
    assert received == [('/', {'text': '原样发送 $(touch /tmp/talkwtf-should-not-exist)', 'conversation': 'project-a', 'source': 'TalkWTF'})], received
    print('Loopback payload, failure, redirect and literal command-stdin checks passed')

    with tempfile.TemporaryDirectory() as directory:
        router = str(Path(directory) / 'router-tests')
        main = Path(directory) / 'main.swift'
        main.write_text('import Foundation\nrunRouterChecks()\n')
        subprocess.run([
            'swiftc', '-O',
            str(root / 'macos/TalkWTF/AgentTransport.swift'),
            str(root / 'macos/TalkWTF/AgentRouter.swift'),
            str(Path(__file__).with_name('router-checks.swift')),
            str(main), '-o', router,
        ], check=True)
        subprocess.run([router], check=True)
finally:
    server.shutdown()
