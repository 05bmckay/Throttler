"""Exercise a built release against a disposable local TLS PostgreSQL database.

Required: TEST_RELEASE_DATABASE_URL (fresh throttle_readiness_* database),
TEST_RELEASE_CA_CERT, RELEASE_BIN. The PostgreSQL certificate must match localhost.
No HubSpot traffic is sent; only synthetic signing credentials are used.
"""
import hashlib
import hmac
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

url = os.environ['TEST_RELEASE_DATABASE_URL']
parsed = urllib.parse.urlparse(url)
assert parsed.hostname in ('localhost', '127.0.0.1')
assert parsed.path.startswith('/throttle_readiness_')
release = os.environ['RELEASE_BIN']
ca = os.environ['TEST_RELEASE_CA_CERT']
port = os.environ.get('TEST_RELEASE_PORT', '55440')
env = os.environ.copy()
env.update(DATABASE_URL=url, DATABASE_CA_CERT_PATH=ca,
    SECRET_KEY_BASE='local-release-smoke-only-' * 4,
    ENCRYPTION_KEY=base64.b64encode(bytes([1]) * 32).decode(),
    HUBSPOT_CLIENT_ID='fake-local-id', HUBSPOT_CLIENT_SECRET='fake-local-secret',
    THROTTLE_ADMISSION_ENABLED='false', THROTTLE_DISPATCH_ENABLED='false',
    PORT=port, BASE_URL='localhost', POOL_SIZE='4', RELEASE_DISTRIBUTION='none')
# An inherited monitoring key must never send local test data to a real account.
env['APPSIGNAL_ACTIVE'] = 'false'
results = {}
logs = Path(tempfile.mkdtemp(prefix='throttler-release-smoke-'))

def status(path, method='GET', body=None, signed=False):
    headers = {'Content-Type': 'application/json'}
    if signed:
        timestamp = str(int(time.time() * 1000))
        raw = method.encode() + ('http://127.0.0.1:' + port + path).encode() + body + timestamp.encode()
        headers['x-hubspot-request-timestamp'] = timestamp
        headers['x-hubspot-signature-v3'] = base64.b64encode(hmac.new(b'fake-local-secret', raw, hashlib.sha256).digest()).decode()
    request = urllib.request.Request('http://127.0.0.1:' + port + path, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code

def boot_check(enabled, before_migration=False):
    env['THROTTLE_ADMISSION_ENABLED'] = 'true' if enabled else 'false'
    env['THROTTLE_DISPATCH_ENABLED'] = 'true' if enabled else 'false'
    with (logs / 'server.log').open('a') as log:
        process = subprocess.Popen([release, 'start'], env=env, stdout=log, stderr=log)
        try:
            for _ in range(100):
                if process.poll() is not None:
                    raise RuntimeError('Release exited; inspect ' + str(logs))
                try:
                    health = status('/api/health')
                    break
                except (OSError, urllib.error.URLError):
                    time.sleep(.1)
            else:
                raise RuntimeError('Release did not start')
            assert health == (200 if enabled else 503)
            assert status('/api/live') == 200
            assert status('/nonexistent-readiness-probe') == 404
            results['unknown_route'] = 404
            results['premigration_paused_health' if before_migration else 'active_health' if enabled else 'paused_health'] = health
            if enabled:
                assert status('/api/config/1/2') == 401
                assert status('/api/hubspot/action', 'POST', b'{}') == 401
                results.update(unauthenticated_config=401, unsigned_webhook=401)
            else:
                body = json.dumps({'callbackId': 'smoke-never-admitted', 'origin': {'portalId': 901, 'actionDefinitionId': 903}, 'context': {'workflowId': 902}, 'inputFields': {'maxThroughPut': '1', 'time': '1', 'period': 'days'}}).encode()
                assert status('/api/hubspot/action', 'POST', body, signed=True) == 503
                results['paused_signed_webhook'] = 503
        finally:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

boot_check(False, before_migration=True)
with (logs / 'migration.log').open('w') as log:
    subprocess.run([release, 'eval', 'Throttle.Release.migrate()'], env=env, stdout=log, stderr=log, check=True, timeout=90)
boot_check(True)
boot_check(False)
untrusted = env.copy()
untrusted.pop('DATABASE_CA_CERT_PATH')
expression = 'Application.ensure_all_started(:ssl); Application.ensure_all_started(:ecto_sql); Application.ensure_all_started(:postgrex); Application.load(:throttle); {:ok, _} = Throttle.Repo.start_link(); case Throttle.Repo.query("SELECT 1", [], timeout: 1500) do {:error, _} -> IO.puts("EXPECTED_TLS_REJECTION"); {:ok, _} -> raise "untrusted TLS accepted" end'
with (logs / 'tls-rejection.log').open('w') as log:
    done = subprocess.run([release, 'eval', expression], env=untrusted, stdout=log, stderr=log, timeout=30)
rejection = (logs / 'tls-rejection.log').read_text()
assert done.returncode == 0 and 'EXPECTED_TLS_REJECTION' in rejection
assert 'Unknown CA' in rejection or 'unknown_ca' in rejection
results.update(verified_database_tls=True, untrusted_database_certificate_rejected=True,
    scope='local production release; synthetic credentials; no HubSpot traffic',
    elixir='1.19.5', otp='28', postgres='15')
Path('docs/readiness/release-smoke-results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
print('Local diagnostic logs: ' + str(logs))
