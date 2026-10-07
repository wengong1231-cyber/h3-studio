#!/usr/bin/env python3
"""Two different disposable binaries must satisfy one certificate-bound identity."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--isolated-test-identity', action='store_true', help='Create and remove only a disposable test keychain')
    args = parser.parse_args()
    signer = module('sign-app')
    setup = module('create-local-signing-identity')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    checks = []

    def check(name, passed):
        checks.append({'name': name, 'passed': bool(passed)})
        if not passed:
            raise AssertionError(name)

    with tempfile.TemporaryDirectory(prefix='h3-signing-continuity-') as directory:
        temporary = Path(directory)
        keychain = temporary / 'fixture.keychain-db' if args.isolated_test_identity else None
        original_search_list = subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user'],
                                              check=True, capture_output=True).stdout
        try:
            if keychain:
                # A fixed, empty password is ONLY for this disposable test fixture.
                # It is never used for the persistent identity or login keychain.
                subprocess.run(['/usr/bin/security', 'create-keychain', '-p', '', str(keychain)], check=True, capture_output=True)
                # codesign requires the identity's keychain on the search list,
                # even with --keychain. Remove only this fixture in finally.
                keys = shlex.split(subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user'],
                                                 check=True, capture_output=True, text=True).stdout)
                if str(keychain) not in keys:
                    subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *keys, str(keychain)],
                                   check=True, capture_output=True)
                config = setup.create_identity(keychain, 'H3 Disposable Signing Test ' + stamp, temporary / 'identity.json')
                fingerprint = config['certificateSHA1']
                identities = subprocess.run(['/usr/bin/security', 'find-identity', '-p', 'codesigning', str(keychain)],
                                            check=True, capture_output=True, text=True)
                if fingerprint not in identities.stdout.upper():
                    raise RuntimeError('Disposable identity not discoverable after import: ' + identities.stdout.strip())
                print(identities.stdout.strip(), flush=True)
            else:
                fingerprint, keychain = signer.load_identity(signer.DEFAULT_CONFIG)
            apps = []
            for version in [1, 2]:
                app = temporary / ('v' + str(version)) / '镜生 H3.app'
                executable = app / 'Contents/MacOS/WanshenjiH3Studio'
                executable.parent.mkdir(parents=True)
                (app / 'Contents/Resources').mkdir()
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleIdentifier': signer.BUNDLE_ID, 'CFBundleExecutable': executable.name,
                    'CFBundlePackageType': 'APPL', 'CFBundleVersion': str(version)}))
                source = temporary / ('v' + str(version) + '.c')
                source.write_text('int main(void) { return ' + str(version) + '; }\n')
                subprocess.run(['/usr/bin/xcrun', 'clang', str(source), '-o', str(executable)], check=True, capture_output=True)
                signer.sign(app, fingerprint, keychain)
                apps.append(app)
            hashes = [hashlib.sha256((a / 'Contents/MacOS/WanshenjiH3Studio').read_bytes()).hexdigest() for a in apps]
            check('different executable hashes', hashes[0] != hashes[1])
            requirements = [subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(a)],
                                          check=True, capture_output=True, text=True).stdout.strip() for a in apps]
            check('identical nonempty designated requirements', bool(requirements[0]) and requirements[0] == requirements[1])
            check('certificate bound, not identifier alone', 'certificate leaf' in requirements[0] and 'cdhash' not in requirements[0])
            for index, app in enumerate(apps):
                result = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + signer.requirement(fingerprint), str(app)], capture_output=True)
                check('version ' + str(index + 1) + ' satisfies persistent identity', result.returncode == 0)
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(apps[1])], check=True, capture_output=True)
            result = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + signer.requirement(fingerprint), str(apps[1])], capture_output=True)
            check('ad-hoc replacement cannot satisfy prior identity', result.returncode != 0)
            (apps[0] / 'Contents/Resources/tampered.txt').write_text('unsealed change')
            result = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(apps[0])], capture_output=True)
            check('tampered resources rejected', result.returncode != 0)
        finally:
            if args.isolated_test_identity and keychain and keychain.exists():
                subprocess.run(['/usr/bin/security', 'delete-keychain', str(keychain)], check=True, capture_output=True)
        after = subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user'], check=True, capture_output=True).stdout
        check('user keychain search list unchanged', original_search_list == after)
    evidence = {'verifiedAt': stamp, 'checks': checks, 'isolatedIdentity': args.isolated_test_identity,
                'TCCModified': False, 'trustSettingsModified': False, 'appsInstalledOrLaunched': False,
                'limitation': 'Cryptographic update identity proof; does not simulate a user TCC authorization or claim a real post-update permission prompt was observed.'}
    output = ROOT / 'Evidence' / ('signing-continuity-' + stamp + '.json')
    output.write_text(json.dumps(evidence, indent=2) + '\n')
    print(str(output))


if __name__ == '__main__':
    main()
