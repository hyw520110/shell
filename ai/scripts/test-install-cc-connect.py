"""离线验收安装、校验失败保护及 AI Hub 安装钩子，不访问真实用户配置。"""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('install-cc-connect.sh')
CONFIG = SCRIPT.parents[1] / 'conf/tools/cli/codex.json'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cc-connect-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'user home'
        self.home.mkdir()
        self.tools = self.root / 'mock tools'
        self.tools.mkdir()
        self.runtime = self.root / 'temporary files'
        self.runtime.mkdir()
        self.target = self.home / 'my bin/cc-connect'
        self.fixture = self.root / 'fixture.tar.gz'
        member = tarfile.TarInfo('cc-connect-v1.5.3-darwin-amd64')
        binary = b'#!/bin/bash\nprintf "cc-connect v1.5.3\\n"\n'
        member.size, member.mode = len(binary), 0o755
        with tarfile.open(self.fixture, 'w:gz') as archive:
            archive.addfile(member, io.BytesIO(binary))
        digest = hashlib.sha256(self.fixture.read_bytes()).hexdigest()
        self.sums = self.root / 'checksums.txt'
        self.sums.write_text(digest + '  cc-connect-v1.5.3-darwin-amd64.tar.gz\n')
        self.downloads = self.root / 'downloads'
        self.env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.runtime),
                        CC_CONNECT_BIN_DIR=str(self.target.parent), CC_CONNECT_VERSION='v1.5.3',
                        PATH=str(self.tools) + os.pathsep + os.environ['PATH'],
                        TEST_FIXTURE=str(self.fixture), TEST_SUMS=str(self.sums),
                        TEST_DOWNLOADS=str(self.downloads))
        self.write_executable(self.tools / 'uname',
                              '#!/bin/bash\ncase "$1" in -s) echo "${TEST_OS:-Darwin}";; -m) echo "${TEST_ARCH:-x86_64}";; esac\n')
        self.write_executable(self.tools / 'curl', f'''#!{sys.executable}
import json, os, pathlib, sys
args = sys.argv[1:]
out = pathlib.Path(args[args.index('--output') + 1])
url = args[-1]
with open(os.environ['TEST_DOWNLOADS'], 'a') as f: f.write(url + '\\n')
if os.environ.get('TEST_FAIL'):
    out.write_bytes(b'partial')
    sys.exit(22)
if url.endswith('/latest'):
    out.write_text(json.dumps({{'tag_name': 'v1.5.3'}}))
else:
    key = 'TEST_SUMS' if url.endswith('checksums.txt') else 'TEST_FIXTURE'
    out.write_bytes(pathlib.Path(os.environ[key]).read_bytes())
''')

    @staticmethod
    def write_executable(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(0o755)

    def run_script(self, *args, ok=True):
        result = subprocess.run(['/bin/bash', str(SCRIPT), *args], env=self.env,
                                cwd=self.root, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def existing_install(self):
        self.write_executable(self.target, '#!/bin/bash\necho "cc-connect v1.5.2"\n')
        config = self.home / '.cc-connect/config.toml'
        config.parent.mkdir()
        config.write_text('private fixture config')
        return config

    def test_install_verified_archive_and_cleanup(self):
        result = self.run_script('install')
        self.assertTrue(os.access(self.target, os.X_OK))
        self.assertIn('work_dir', result.stdout)
        self.assertIn('daemon install', result.stdout)
        self.assertFalse(list(self.runtime.iterdir()))
        self.assertFalse((self.home / '.cc-connect').exists())

    def test_reinstall_preserves_program_and_private_config_without_network(self):
        config = self.existing_install()
        before = self.target.read_bytes()
        result = self.run_script('install')
        self.assertEqual(self.target.read_bytes(), before)
        self.assertEqual(config.read_text(), 'private fixture config')
        self.assertNotIn('private fixture config', result.stdout)
        self.assertFalse(self.downloads.exists())

    def test_checksum_failure_preserves_existing_install(self):
        config = self.existing_install()
        before = self.target.read_bytes()
        self.sums.write_text('0' * 64 + '  cc-connect-v1.5.3-darwin-amd64.tar.gz\n')
        result = self.run_script('update', ok=False)
        self.assertIn('SHA-256', result.stderr)
        self.assertEqual(self.target.read_bytes(), before)
        self.assertTrue(config.exists())
        self.assertFalse(list(self.runtime.iterdir()))

    def test_update_keeps_rollback_copy_and_config(self):
        config = self.existing_install()
        before = self.target.read_bytes()
        self.run_script('update')
        backups = list((self.home / '.local/share/cc-connect/backups').iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        self.assertEqual(config.read_text(), 'private fixture config')

    def test_other_supported_release_archives(self):
        for system, cpu, platform, architecture in (
                ('Linux', 'x86_64', 'linux', 'amd64'),
                ('Linux', 'aarch64', 'linux', 'arm64'),
                ('Darwin', 'arm64', 'darwin', 'arm64')):
            with self.subTest(system=system, cpu=cpu):
                self.target.unlink(missing_ok=True)
                self.env.update(TEST_OS=system, TEST_ARCH=cpu)
                name = f'cc-connect-v1.5.3-{platform}-{architecture}'
                binary = b'#!/bin/bash\nprintf "cc-connect v1.5.3\\n"\n'
                member = tarfile.TarInfo(name)
                member.size, member.mode = len(binary), 0o755
                with tarfile.open(self.fixture, 'w:gz') as archive:
                    archive.addfile(member, io.BytesIO(binary))
                digest = hashlib.sha256(self.fixture.read_bytes()).hexdigest()
                self.sums.write_text(f'{digest}  {name}.tar.gz\n')
                self.run_script('install')
                self.assertTrue(self.target.is_file())

    def test_network_failure_cleans_partial_download(self):
        self.existing_install()
        self.env['TEST_FAIL'] = '1'
        self.run_script('update', ok=False)
        self.assertFalse(list(self.runtime.iterdir()))
        self.assertIn('v1.5.2', self.target.read_text())

    def test_dry_run_does_not_create_install_or_download(self):
        result = self.run_script('install', '--dry-run')
        self.assertIn('预览', result.stdout)
        self.assertEqual(result.stderr, '')
        self.assertFalse(self.target.parent.exists())
        self.assertFalse(self.downloads.exists())

    def test_invalid_version_and_unsupported_platform_stop_before_download(self):
        self.run_script('install', '--version', '../invalid', ok=False)
        self.env['TEST_OS'] = 'Windows'
        self.run_script('install', ok=False)
        self.assertFalse(self.downloads.exists())

    @unittest.skipUnless(shutil.which('jq'), 'latest 模式要求 jq')
    def test_latest_resolves_official_release_metadata(self):
        self.run_script('install', '--version', 'latest')
        self.assertIn('/releases/latest', self.downloads.read_text())
        self.assertIn('/v1.5.3/', self.downloads.read_text())

    def test_post_install_hook_works_from_other_directory_with_spaces(self):
        self.existing_install()
        hub = self.root / 'AI Hub directory'
        (hub / 'scripts').mkdir(parents=True)
        shutil.copyfile(SCRIPT, hub / 'scripts' / SCRIPT.name)
        self.env['AI_HUB_SCRIPT_DIR'] = str(hub)
        config = json.loads(CONFIG.read_text())
        command = config['post_install'][0]['command']
        result = subprocess.run(['/bin/bash', '-c', command], cwd=self.root,
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('cc-connect 配置指南', result.stdout)
        self.assertFalse(self.downloads.exists())

    def test_uninstall_preserves_user_config(self):
        config = self.existing_install()
        self.run_script('uninstall', '--dry-run')
        self.assertTrue(self.target.exists())
        self.run_script('uninstall')
        self.assertFalse(self.target.exists())
        self.assertTrue(config.exists())

    def test_short_help_succeeds(self):
        self.run_script('-h')


if __name__ == '__main__':
    unittest.main()
