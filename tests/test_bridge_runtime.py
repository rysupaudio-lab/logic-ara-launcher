"""Compile/run only the native setup wrapper's offline owned-object controls."""
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64',
                     'Native bridge compile controls require Apple Silicon macOS')
class BridgeRuntimeTests(unittest.TestCase):
    def test_native_setup_preservation_and_degradation(self):
        source = Path(__file__).with_suffix('.mm')
        with tempfile.TemporaryDirectory(prefix='logic-ara-runtime-test-') as folder:
            executable = Path(folder) / 'guard-test'
            subprocess.run(['/usr/bin/xcrun', 'clang++', '-arch', 'arm64',
                '-mmacosx-version-min=15.4', '-std=c++17', '-fobjc-arc',
                '-Wno-deprecated-declarations', '-framework', 'Foundation',
                '-framework', 'AppKit', '-framework', 'AudioToolbox',
                '-framework', 'Carbon', str(source), '-o', str(executable)],
                check=True, capture_output=True, text=True)
            result = subprocess.run([str(executable)], check=True,
                                    capture_output=True, text=True)
            proof = json.loads(result.stdout)
            self.assertTrue(proof['pass'])
            self.assertEqual(proof['checks'], 50)
            self.assertIn('no Logic/plugin launch', proof['scope'])


if __name__ == '__main__':
    unittest.main()
