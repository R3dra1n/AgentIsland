#!/usr/bin/env python3
"""Publication gate: locations only, no secret values. Not a full history audit."""
from pathlib import Path
import re
import subprocess
import sys
import argparse

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    'personal-home-path': re.compile(rb'/Users/[A-Za-z0-9_.-]+/'),
    'common-token': re.compile(rb'(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{20,})'),
    'private-key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----'),
    'credentials-in-url': re.compile(rb'https?://[^\s/:@]+:[^\s/@]+@[^\s/]+'),
}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, help='Scan the packaged app, including its binary')
    args = parser.parse_args()
    if args.app:
        if args.app.is_symlink() or not args.app.is_dir():
            parser.error('App directory does not exist')
        app_root = args.app.absolute()
        paths = [(str(Path('app') / p.relative_to(app_root)), p)
                 for p in app_root.rglob('*') if p.is_file() or p.is_symlink()]
    else:
        names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).split(b'\0')
        paths = [(name.decode(), ROOT / name.decode()) for name in sorted(set(names)) if name]
    findings = []
    for relative, path in sorted(paths, key=lambda item: item[0]):
        if path.is_symlink():
            findings.append((relative, 'symlink-requires-review'))
            continue
        if not path.is_file():
            continue
        content = path.read_bytes()
        for category, pattern in PATTERNS.items():
            if pattern.search(content):
                findings.append((relative, category))
    for relative, category in findings:
        print(f'{relative}: {category}')
    print(f'Publication gate: {len(findings)} findings ({"app bundle" if args.app else "working tree"}; excludes history).')
    return bool(findings)

if __name__ == '__main__':
    sys.exit(main())
