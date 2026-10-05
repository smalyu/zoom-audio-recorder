"""Create a persistent private build identity, without changing system trust."""
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile

folder = Path.home() / 'Library/Application Support/Zoom Audio Recorder Build Signing'
folder.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(folder, 0o700)
keychain = folder / 'signing.keychain-db'
password_file = folder / 'keychain-password'
certificate = folder / 'certificate.pem'

def run(args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise SystemExit('Local signing setup failed: ' + result.stderr.strip())
    return result.stdout.strip()

if not keychain.exists():
    password = secrets.token_urlsafe(40)
    password_file.write_text(password)
    os.chmod(password_file, 0o600)
    old_search_list = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
    with tempfile.TemporaryDirectory(prefix='zoom-signing-') as temporary:
        path = Path(temporary)
        config = path / 'openssl.cnf'
        config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=signing\nprompt=no\n'
            '[dn]\nCN=Zoom Audio Recorder Local Code Signing\n'
            '[signing]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n'
            'extendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n')
        run(['openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256',
             '-days', '3650', '-config', str(config), '-keyout', str(path / 'private.pem'),
             '-out', str(certificate)])
        run(['openssl', 'pkcs12', '-export', '-inkey', str(path / 'private.pem'),
             '-in', str(certificate), '-out', str(path / 'identity.p12'),
             '-passout', 'pass:' + password, '-legacy'])
        try:
            run(['/usr/bin/security', 'create-keychain', '-p', password, str(keychain)])
            run(['/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain)])
            run(['/usr/bin/security', 'import', str(path / 'identity.p12'), '-k', str(keychain),
                 '-P', password, '-T', '/usr/bin/codesign'])
            run(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
                 '-s', '-k', password, str(keychain)])
        finally:
            run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *old_search_list])
else:
    run(['/usr/bin/security', 'unlock-keychain', '-p', password_file.read_text(), str(keychain)])

print(str(keychain))
