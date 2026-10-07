#!/usr/bin/env python3
"""Provision one local-only signing key. No trust-store, TCC, or system policy edits."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile

SUPPORT = Path.home() / 'Library/Application Support/com.wengong.WanshenjiH3Studio/Signing'
LABEL = 'Jingsheng H3 Local Signing'


def create_identity(keychain, label, config_path):
    if config_path.exists():
        raise RuntimeError('Signing configuration already exists; reuse or investigate it, never rotate silently.')
    existing = subprocess.run(['/usr/bin/security', 'find-certificate', '-c', label, str(keychain)],
                              capture_output=True)
    if existing.returncode == 0:
        raise RuntimeError('A certificate with this label already exists; recover its configuration instead of duplicating it.')
    with tempfile.TemporaryDirectory(prefix='jingsheng-signing-') as directory:
        temporary = Path(directory)
        os.chmod(temporary, 0o700)
        private_key, certificate, archive = [temporary / name for name in ('private.pem', 'certificate.pem', 'identity.p12')]
        specification = temporary / 'certificate.cnf'
        specification.write_text('[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=usage\n'
                                 '[subject]\nCN=' + label + '\n'
                                 '[usage]\nbasicConstraints=critical,CA:FALSE\n'
                                 'keyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n'
                                 'subjectKeyIdentifier=hash\n')
        subprocess.run(['/usr/bin/openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-sha256',
                        '-nodes', '-days', '3650', '-config', str(specification), '-keyout', str(private_key),
                        '-out', str(certificate)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        os.chmod(private_key, 0o600)
        der = subprocess.run(['/usr/bin/openssl', 'x509', '-in', str(certificate), '-outform', 'DER'],
                             check=True, capture_output=True).stdout
        # macOS Security does not reliably import LibreSSL archives using an
        # empty password. This one-use wrapping password is never saved or logged.
        wrapping_password = secrets.token_urlsafe(32)
        subprocess.run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(private_key), '-in', str(certificate),
                        '-name', label, '-out', str(archive), '-passout', 'stdin'], input=wrapping_password.encode(),
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        os.chmod(archive, 0o600)
        # Only Apple's codesign is allowed to use this non-exportable key.
        # No -A (all applications), no root trust, no search-list or TCC edits.
        imported = subprocess.run(['/usr/bin/security', 'import', str(archive), '-k', str(keychain), '-P', wrapping_password,
                                   '-x', '-T', '/usr/bin/codesign'], capture_output=True, text=True)
        if imported.returncode:
            # security diagnostics contain the error, not the PKCS12 contents.
            raise RuntimeError('Keychain identity import failed: ' + imported.stderr.replace(wrapping_password, '[redacted]').strip()[:2000])
        config = {'schema': 'jingsheng-local-signing-identity-v1', 'certificateSHA1': hashlib.sha1(der).hexdigest().upper(),
                  'certificateSHA256': hashlib.sha256(der).hexdigest(), 'keychainPath': str(keychain),
                  'label': label, 'localDevelopmentOnly': True, 'trustSettingsModified': False}
        config_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with config_path.open('x') as stream:
            os.chmod(config_path, 0o600)
            json.dump(config, stream, indent=2)
            stream.write('\n')
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--create', action='store_true', help='Explicitly authorize creation of the private signing identity')
    args = parser.parse_args()
    keychain = Path.home() / 'Library/Keychains/login.keychain-db'
    destination = SUPPORT / 'identity.json'
    if not args.create:
        print(json.dumps({'action': 'create one non-exportable local code-signing key', 'label': LABEL,
                          'keychain': str(keychain), 'publicConfiguration': str(destination),
                          'allowedKeyClient': '/usr/bin/codesign', 'requiresPrivateKeyCreationAuthorization': True,
                          'trustOrTCCChanges': False, 'configurationExists': destination.exists()}, indent=2))
        return
    old_umask = os.umask(0o077)
    try:
        config = create_identity(keychain, LABEL, destination)
    finally:
        os.umask(old_umask)
    print(json.dumps({'created': True, 'publicConfiguration': str(destination),
                      'certificateSHA256': config['certificateSHA256'], 'privateKeyExportedToRepository': False}))


if __name__ == '__main__':
    main()
