"""Check locked Hex package versions against OSV; send no application data."""
import datetime
import hashlib
import json
from pathlib import Path
import re
import sys
import urllib.request

lock = Path('mix.lock').read_bytes()
packages = re.findall(r'"([^"]+)": \{:hex, :[^,]+, "([^"]+)"', lock.decode())
if not packages:
    raise SystemExit('No Hex packages found; refusing an empty audit')
request = urllib.request.Request(
    'https://api.osv.dev/v1/querybatch',
    data=json.dumps({'queries': [
        {'package': {'name': name, 'ecosystem': 'Hex'}, 'version': version}
        for name, version in packages
    ]}).encode(),
    headers={'Content-Type': 'application/json'},
)
with urllib.request.urlopen(request, timeout=30) as response:
    results = json.load(response)['results']
if len(results) != len(packages):
    raise SystemExit('Incomplete advisory response')
findings = [
    {'name': name, 'version': version, 'vulnerabilities': result['vulns']}
    for (name, version), result in zip(packages, results) if result.get('vulns')
]
# Keep version-scoped, expiring applicability reviews visible in the report.
reviews = json.loads(Path('docs/readiness/dependency-exceptions.json').read_text())
versions = dict(packages)
today = datetime.date.today()
unreviewed = []
for finding in findings:
    for vulnerability in finding['vulnerabilities']:
        accepted = any(
            review['id'] == vulnerability['id'] and review['package'] == finding['name']
            and review['version'] == finding['version']
            and today <= datetime.date.fromisoformat(review['review_by'])
            and all(versions.get(name) == version for name, version in review['requires'].items())
            for review in reviews
        )
        if not accepted:
            unreviewed.append({'package': finding['name'], 'id': vulnerability['id']})
report = {
    'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'source': 'https://api.osv.dev/v1/querybatch',
    'lock_sha256': hashlib.sha256(lock).hexdigest(),
    'packages_checked': len(packages), 'findings': findings,
    'unreviewed_findings': unreviewed, 'applicability_reviews': reviews,
}
text = json.dumps(report, indent=2) + '\n'
if len(sys.argv) == 2:
    Path(sys.argv[1]).write_text(text)
print(text)
sys.exit(bool(unreviewed))
