#!/usr/bin/env python3
"""Sequential, isolated CPU regressions tied to one source and signed binary."""
from pathlib import Path
import datetime
import hashlib
import json
import subprocess
import sys
import time

root = Path(__file__).resolve().parent.parent
binary = root / 'build/release/镜生 H3.app/Contents/MacOS/WanshenjiH3Studio'
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
output = root / 'Evidence' / ('release-checks-' + stamp)
output.mkdir(exist_ok=False)

def identity():
    files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted((root / 'Sources').glob('*.swift'))}
    return {'sourceDigest': hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
            'files': files, 'executableSHA256': hashlib.sha256(binary.read_bytes()).hexdigest()}

verified = identity()
names = sys.argv[1:] or ['receipt-rebind', 'ready-frontier', 'execution-focus', 'video-review',
    'action-revision', 'static-input', 'queue-execution', 'execution-activity', 'ui-gpu',
    'startup', 'migration', 'core', 'h3', 'readiness', 'history', 'h3-ab', 'automation',
    'preview', 'first-shot', 'queue']
records = []
for name in names:
    assert identity() == verified, 'Source or binary changed during testing'
    destination = output / name
    flag = '--self-test-core' if name == 'core' else '--' + name + '-self-test'
    started = time.monotonic()
    with (output / (name + '.log')).open('wb') as stream:
        result = subprocess.run([str(binary), flag, str(destination)], cwd=root,
                                stdout=stream, stderr=subprocess.STDOUT, timeout=240)
    reports = list(destination.glob('*test-report.json'))
    data = json.loads(reports[0].read_text()) if len(reports) == 1 else []
    checks = data.get('checks', []) if isinstance(data, dict) else data
    record = {'suite': name, 'exitCode': result.returncode, 'checks': len(checks),
              'passed': sum(bool(c['passed']) for c in checks),
              'failed': [c for c in checks if not c['passed']],
              'seconds': round(time.monotonic() - started, 3)}
    records.append(record)
    summary = {'identity': verified, 'suites': records, 'sequential': True,
               'realH3Started': False, 'productionWorkspaceWritten': False}
    (output / 'verification.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(record, ensure_ascii=False), flush=True)
    if result.returncode or record['failed'] or not checks:
        print('Failure log: ' + str(output / (name + '.log')), flush=True)
        raise SystemExit(1)
assert identity() == verified
print('Verified: ' + str(output / 'verification.json'), flush=True)
