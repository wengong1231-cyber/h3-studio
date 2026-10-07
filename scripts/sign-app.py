#!/usr/bin/env python3
"""Sign local releases with one certificate; never fall back to ad-hoc signing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

BUNDLE_ID = 'com.wengong.WanshenjiH3Studio'
DEFAULT_CONFIG = Path.home() / 'Library/Application Support' / BUNDLE_ID / 'Signing/identity.json'


def load_identity(path):
    config = json.loads(Path(path).read_text())
    if config.get('schema') != 'jingsheng-local-signing-identity-v1':
        raise ValueError('Unknown signing identity configuration')
    fingerprint = config.get('certificateSHA1', '')
    keychain = Path(config.get('keychainPath', ''))
    if not re.fullmatch(r'[A-Fa-f0-9]{40}', fingerprint) or not keychain.is_absolute() or not keychain.is_file():
        raise ValueError('A fixed certificate fingerprint and existing absolute keychain path are required')
    return fingerprint.upper(), keychain


def requirement(fingerprint):
    if not re.fullmatch(r'[A-Fa-f0-9]{40}', fingerprint):
        raise ValueError('Invalid certificate fingerprint')
    # A bundle identifier alone is NOT an identity. Pin the actual certificate.
    return f'identifier "{BUNDLE_ID}" and certificate leaf = H"{fingerprint.lower()}"'


def sign(app, fingerprint, keychain):
    constraint = requirement(fingerprint)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', fingerprint,
                    '--keychain', str(keychain), '--identifier', BUNDLE_ID,
                    '--requirements', '=designated => ' + constraint,
                    '--timestamp=none', str(app)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + constraint, str(app)], check=True)
    return constraint


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path(os.environ.get('H3_SIGNING_CONFIG', str(DEFAULT_CONFIG))))
    parser.add_argument('--check', action='store_true')
    parser.add_argument('app', nargs='?', type=Path)
    args = parser.parse_args()
    try:
        fingerprint, keychain = load_identity(args.config)
    except (OSError, ValueError) as exc:
        raise SystemExit('Persistent signing identity unavailable. Configure the existing certificate or run '
                         'scripts/create-local-signing-identity.py --create after authorizing local key creation. '
                         'No ad-hoc release was produced. ' + str(exc))
    listing = subprocess.run(['/usr/bin/security', 'find-identity', '-p', 'codesigning', str(keychain)],
                             check=True, capture_output=True, text=True).stdout
    if fingerprint not in listing.upper():
        raise SystemExit('Configured private signing identity is unavailable; refusing to generate a replacement.')
    if args.check:
        print('Persistent signing identity is available; key material was not exported.')
        return
    if not args.app:
        parser.error('app is required unless --check is supplied')
    constraint = sign(args.app, fingerprint, keychain)
    print(json.dumps({'signedApp': str(args.app), 'persistentIdentity': True,
                      'designatedRequirementSHA256': hashlib.sha256(constraint.encode()).hexdigest()}))


if __name__ == '__main__':
    main()
