"""Foundation-only cached-standard isolation in unique synthetic test domains."""
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64',
                     'Native bridge controls require Apple Silicon macOS')
class BridgePreferencesTests(unittest.TestCase):
    def test_cached_standard_and_explicit_domains(self):
        with tempfile.TemporaryDirectory(prefix='logic-ara-prefs-test-') as folder:
            executable = Path(folder) / 'preferences-test'
            subprocess.run(['/usr/bin/xcrun', 'clang++', '-arch', 'arm64',
                '-mmacosx-version-min=15.4', '-std=c++17', '-fobjc-arc',
                '-Wno-deprecated-declarations', '-framework', 'Foundation',
                '-framework', 'AppKit', '-framework', 'AudioToolbox',
                '-framework', 'Carbon', str(Path(__file__).with_suffix('.mm')),
                '-o', str(executable)], check=True, capture_output=True, text=True)
            result = subprocess.run([str(executable)], check=True,
                                    capture_output=True, text=True, timeout=30)
            proof = json.loads(result.stdout)
            self.assertTrue(proof['pass'])
            self.assertEqual(proof['checks'], 33)
            self.assertIn('unique synthetic domains only', proof['scope'])


if __name__ == '__main__':
    unittest.main()
