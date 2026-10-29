import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('public_source', ROOT / 'scripts/check_public_source.py')
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)

class PublicSourceTests(unittest.TestCase):
    def test_detects_common_secret_forms_without_echoing_values(self):
        samples = [
            ('common-token', ('xoxb-' + 'A' * 24).encode()),
            ('common-token', ('ASIA' + 'A' * 16).encode()),
            ('private-key', ('-----BEGIN ' + 'ENCRYPTED PRIVATE KEY-----').encode()),
            ('credentials-in-url', ('https://user:' + 'password@example.org').encode()),
            ('personal-home-path', ('/Users/' + 'example/project').encode()),
        ]
        for category, value in samples:
            with self.subTest(category=category):
                self.assertIsNotNone(scanner.PATTERNS[category].search(value))
        self.assertIsNone(scanner.PATTERNS['credentials-in-url'].search(b'https://example.org/path'))

    def test_external_app_reports_symlinks_without_revealing_absolute_path(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Example.app'
            app.mkdir()
            (app / 'data').write_text('safe')
            (app / 'link').symlink_to(app / 'data')
            result = subprocess.run(['/usr/bin/python3', str(ROOT / 'scripts/check_public_source.py'), '--app', str(app)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('app/link: symlink-requires-review', result.stdout)
            self.assertNotIn(directory, result.stdout)
