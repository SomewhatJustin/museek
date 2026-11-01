"""Offline contract checks; these do not assert Apple signing works."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseCI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        RUNNER_TEMP=str(self.base), TMPDIR=str(self.base), GITHUB_RUN_ID='123',
                        GITHUB_RUN_ATTEMPT='2', ASC_KEY_ID='fake-id',
                        ASC_ISSUER_ID='fake-issuer', ASC_PRIVATE_KEY='fake-key',
                        LOG=str(self.base / 'commands'))
        self.key_dir = self.base / 'museek-asc-123-2'
        for name in ('xcodegen', 'plutil'):
            self.mock(name, '#!/bin/bash\nexit 0\n')
        self.mock('xcrun', '#!/bin/bash\nprintf "%s\\n" "$*" >> "$LOG"\n')

    def mock(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def run_script(self, name):
        # xcodegen is mocked so these checks never rewrite the real project.
        return subprocess.run(['bash', str(ROOT / 'scripts' / name)],
                              env=self.env, capture_output=True, text=True)

    def test_upload_key_permissions_and_cleanup(self):
        self.mock('xcodebuild', '''#!/bin/bash
set -eu
[[ -f "$ASC_KEY_PATH" ]]
[[ "$(cat "$ASC_KEY_PATH")" == fake-key ]]
[[ -z "${ASC_PRIVATE_KEY+x}" ]]
python3 -c 'import os,stat; assert stat.S_IMODE(os.stat(os.environ["ASC_KEY_PATH"]).st_mode)==0o600'
printf '%s\n' "$*" >> "$LOG"
''')
        result = self.run_script('ci_testflight.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.key_dir.exists())
        commands = Path(self.env['LOG']).read_text()
        self.assertIn('test', commands)
        self.assertIn('archive', commands)
        self.assertIn('-exportArchive', commands)
        self.assertIn('ExportOptions-CI.plist', commands)
        self.assertIn('altool --upload-package', commands)
        self.assertIn('--wait', commands)
        export_command = next(line for line in commands.splitlines() if '-exportArchive' in line)
        self.assertNotIn('-allowProvisioningUpdates', export_command)
        self.assertNotIn('-authenticationKey', export_command)

    def test_failure_cleans_key(self):
        self.mock('xcodebuild', '#!/bin/bash\nexit 42\n')
        result = self.run_script('ci_testflight.sh')
        self.assertEqual(result.returncode, 42)
        self.assertFalse(self.key_dir.exists())

    def test_missing_secret_fails_before_creating_key(self):
        del self.env['ASC_PRIVATE_KEY']
        result = self.run_script('ci_testflight.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.key_dir.exists())

    def test_release_rejects_other_apple_teams_before_building(self):
        self.env['APPLE_TEAM_ID'] = 'OTHERTEAM1'
        self.mock('xcodebuild', '#!/bin/bash\ntouch "$LOG"\n')
        result = self.run_script('upload_testflight.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('personal team JSKJUMBXQ3', result.stderr)
        self.assertFalse(Path(self.env['LOG']).exists())

    def test_verify_is_unsigned_sdk_only(self):
        self.mock('xcodebuild', '#!/bin/bash\nprintf "%s\\n" "$*" > "$LOG"\n')
        result = self.run_script('verify_ios.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        command = Path(self.env['LOG']).read_text()
        for expected in ('generic/platform=iOS Simulator', 'build-for-testing',
                         'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO'):
            self.assertIn(expected, command)
        self.assertNotIn('name=iPhone', command)
        self.assertNotIn('archive', command)
        self.assertFalse(self.key_dir.exists())


if __name__ == '__main__':
    unittest.main()
