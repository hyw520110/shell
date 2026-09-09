"""Offline regression checks: python3 -m unittest discover -s ai/tests -v."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
HUB = ROOT / 'ai/ai-hub.sh'
TRAE = ROOT / 'ai/ide/trae/install-trae.sh'
BACKEND = ROOT / 'ide/install-trae.sh'


class HubTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.env = dict(os.environ, AI_HUB_CACHE_DIR=str(self.work / 'cache'),
                        AI_HUB_STATUS_CACHE_FILE=str(self.work / 'status'),
                        AI_HUB_CACHE_FILE=str(self.work / 'values'))

    def shell(self, code, timeout=15):
        return subprocess.run(['/bin/bash', '-c', code], cwd=ROOT, env=self.env,
                              capture_output=True, text=True, timeout=timeout)

    def hub(self, code):
        result = self.shell(f'source {shlex.quote(str(HUB))}\nset_log_level quiet\n' + code)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_metadata_fields_and_cache_invalidation(self):
        folder = self.work / 'tools' / 'cli'
        folder.mkdir(parents=True)
        config = folder / 'sample.json'
        data = {'id': 'sample', 'name': 'Sample', 'description': 'line1\nline2',
                'install': {'methods': [{'type': 'npm', 'command': 'npm install -g @scope/pkg@latest',
                                         'check': 'command -v sample || test -f /sample'}]},
                'commands': {'start': 'sample --serve'}, 'config': {'path': '$HOME/.sample'},
                'group': 'samples', 'sort_order': 7}
        config.write_text(json.dumps(data))
        command = f'parse_all_tool_configs {shlex.quote(str(folder.parent))}'
        cold = self.hub(command)
        self.assertEqual(cold, self.hub(command))
        fields = cold.rstrip('\n').split('\x1f')
        self.assertEqual(len(fields), 16)
        self.assertEqual(fields[:4], ['sample', 'Sample', '@scope/pkg@latest', 'npm'])
        self.assertEqual(fields[7], 'sample')
        self.assertEqual(fields[9:11], ['line1 line2', 'ai-coding'])
        self.assertEqual(fields[12], data['install']['methods'][0]['check'])
        self.assertEqual(fields[13:], ['7', 'Sample', 'samples'])
        data['name'] = 'Changed'
        config.write_text(json.dumps(data))
        self.assertIn('Changed', self.hub(command))
        config.rename(folder / 'renamed.json')
        self.assertIn('renamed.json', self.hub(command))

    def test_invalid_json_fails_without_replacing_cache(self):
        folder = self.work / 'tools'
        folder.mkdir()
        config = folder / 'sample.json'
        config.write_text('{"id":"sample"}')
        self.hub(f'parse_all_tool_configs {shlex.quote(str(folder))}')
        previous = (self.work / 'cache/tools_compiled.txt').read_bytes()
        config.write_text('{invalid')
        result = self.shell(f'source {shlex.quote(str(HUB))}; parse_all_tool_configs {shlex.quote(str(folder))}')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(previous, (self.work / 'cache/tools_compiled.txt').read_bytes())

    def test_category_checks_are_lazy_and_full_scan_fills_missing(self):
        output = self.hub('''
TOOLS=('a|A||bash|||||||ai-coding' 'b|B||bash|||||||ai-ide')
_check_single_tool_fast() { printf '%s\n' "${1%%|*}" >> "$AI_HUB_CACHE_FILE"; echo true; }
detect_tool_status fast ai-coding >/dev/null
printf '%s\n' "${TOOL_STATUS[*]}"
detect_tool_status fast ai-coding >/dev/null
detect_tool_status fast >/dev/null
printf '%s\n' "${TOOL_STATUS[*]}"
cat "$AI_HUB_CACHE_FILE"
''')
        self.assertEqual(output.splitlines(), ['true unknown', 'true true', 'a', 'b'])

    def test_workers_preserve_order_and_failures(self):
        output = self.hub('''
TOOLS=('a|A||bash|||||||ai-coding' 'b|B||bash|||||||ai-coding')
MAX_CONCURRENT_PROCS=2
_check_single_tool_fast() {
    case "$1" in a*) sleep 0.15; echo true ;; *) echo false ;; esac
}
detect_tool_status fast >/dev/null
printf '%s\n' "${TOOL_STATUS[*]}"
''')
        self.assertEqual(output.strip(), 'true false')

    def test_menu_does_not_execute_version_commands(self):
        output = self.hub('''
TOOLS=('sample|Sample||bash|||||||ai-coding'); TOOL_STATUS=(true)
get_tool_version() { echo called > "$AI_HUB_CACHE_FILE"; echo 9.9; }
get_tool_display_status 0
''')
        self.assertEqual(output.strip(), '已安装')
        self.assertFalse((self.work / 'values').exists())

    def test_timeout_fallback_returns_fast_and_preserves_exit_code(self):
        prelude = f'''source {shlex.quote(str(ROOT / 'ai/lib/utils.sh'))}
command() {{
    if [[ "$1" == -v && ( "$2" == timeout || "$2" == gtimeout ) ]]; then return 1; fi
    builtin command "$@"
}}
'''
        start = time.monotonic()
        result = self.shell(prelude + 'run_with_timeout 2 /bin/bash -c "exit 7"')
        self.assertEqual(result.returncode, 7)
        self.assertLess(time.monotonic() - start, 0.9)
        result = self.shell(prelude + 'run_with_timeout 1 sleep 3')
        self.assertEqual(result.returncode, 124)

    def test_trae_multiple_selection_deduplicates_and_links_regions(self):
        result = self.shell(f'bash {shlex.quote(str(TRAE))} --versions "2,4 2" --dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            'TraeCode 国内版 | https://www.trae.cn/ide/download',
            'TraeCode 国际版 | https://www.trae.ai/download'])
        result = self.shell(f'bash {shlex.quote(str(TRAE))} --versions all --dry-run')
        self.assertEqual(len(result.stdout.splitlines()), 4)

    def test_trae_invalid_cancel_and_eof_do_not_install(self):
        for choice in ['1 9', '0', '   ']:
            result = self.shell(f'bash {shlex.quote(str(TRAE))} --versions {shlex.quote(choice)} --dry-run')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('https://', result.stdout)
        result = self.shell(f'bash {shlex.quote(str(TRAE))} --dry-run </dev/null')
        self.assertNotEqual(result.returncode, 0)

    def test_trae_work_manifest_selects_solo_payload_not_ide_manifest(self):
        fixture = self.work / 'manifest.json'
        fixture.write_text(json.dumps({'data': {'manifest': {'darwin': {'download': [
            {'region': 'cn', 'apple': 'https://example.com/TraeCode_CN-darwin-arm64.dmg'}
        ]}}, 'solo': {'darwin': {'download': [
            {'region': 'cn', 'apple': 'https://example.com/TraeWork_CN-darwin-arm64.dmg', 'intel': 'https://example.com/TraeWork_CN-darwin-x64.dmg'}
        ]}}}}))
        result = self.shell(
            f'source {shlex.quote(str(BACKEND))}; TRAE_PRODUCT=TraeWork; '
            f'TRAE_DOWNLOAD_API={shlex.quote(fixture.as_uri())}; TRAE_DOWNLOAD_REGION=cn; '
            'resolve_download_url arm64'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('TraeWork_CN-darwin-arm64', result.stdout)
        self.assertNotIn('TraeCode_CN', result.stdout)

    def test_trae_single_hub_entry_uses_new_installer(self):
        configs = [json.loads(p.read_text()) for p in (ROOT / 'ai/conf/tools/ide').glob('*.json')]
        entries = [c for c in configs if 'trae' in c.get('id', '').lower()]
        self.assertEqual(len(entries), 1)
        config = entries[0]
        self.assertEqual(config['install']['methods'][0]['command'], 'bash ide/trae/install-trae.sh')
        self.assertEqual(config['update']['command'], 'bash ide/trae/install-trae.sh')

    def test_official_manifest_selects_exact_region_and_architecture(self):
        fixture = self.work / 'manifest.json'
        fixture.write_text(json.dumps({'data': {'manifest': {'darwin': {'download': [
            {'region': 'cn', 'apple': 'https://example.com/cn-arm.dmg'},
            {'region': 'sg', 'apple': 'https://example.com/sg-arm.dmg', 'intel': 'https://example.com/sg-intel.dmg'}
        ]}}}}))
        prefix = f'source {shlex.quote(str(BACKEND))}; TRAE_DOWNLOAD_API={shlex.quote(fixture.as_uri())}; '
        for region, arch, expected in [('cn', 'arm64', 'cn-arm'), ('sg', 'x64', 'sg-intel')]:
            result = self.shell(prefix + f'TRAE_DOWNLOAD_REGION={region}; resolve_download_url {arch}')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout)
        result = self.shell(prefix + 'TRAE_DOWNLOAD_REGION=cn; resolve_download_url x64')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('sg-intel', result.stdout)

    def test_npm_presence_check_avoids_dependency_tree_scan(self):
        package = self.work / 'npm' / '@scope' / 'sample'
        package.mkdir(parents=True)
        (package / 'package.json').write_text('{}')
        output = self.hub(f'''
run_with_timeout() {{ echo unexpected > "$AI_HUB_CACHE_FILE"; return 1; }}
_check_single_tool_fast 'sample|Sample|@scope/sample|npm|||||||ai-coding||npm list -g @scope/sample --depth=0' {shlex.quote(str(self.work / 'npm'))}
''')
        self.assertEqual(output.strip(), 'true')
        self.assertFalse((self.work / 'values').exists())

    def test_domestic_manifest_is_not_just_a_cdn_region(self):
        for region, suffix in [('cn', '/trae/cn/latest'), ('sg', '/trae/latest')]:
            result = self.shell(f'''unset TRAE_DOWNLOAD_API
TRAE_DOWNLOAD_REGION={region}
source {shlex.quote(str(BACKEND))}
printf '%s' "$TRAE_DOWNLOAD_API"
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.endswith(suffix), result.stdout)

    def test_download_failure_does_not_mount(self):
        marker = self.work / 'mounted'
        result = self.shell(f'''source {shlex.quote(str(BACKEND))}
resolve_download_url() {{ return 1; }}
hdiutil() {{ touch {shlex.quote(str(marker))}; }}
install_trae
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())


    def group_setup(self):
        rows = []
        for tool_id, name in [('demo', 'Demo (国际版)'), ('demo-cn', 'Demo (中国版)')]:
            fields = [tool_id, name, '', 'npm', '', '', '', tool_id, '', '', 'ai-coding', '', '', '5000', name, 'demo']
            rows.append(shlex.quote('\x1f'.join(fields)))
        return 'TOOLS=(' + ' '.join(rows) + '); TOOL_STATUS=(false true); detect_tool_status() { :; };\n'

    def test_group_is_single_entry_in_main_and_install_menu(self):
        output = self.hub(self.group_setup() + '''
opts=(); idxs=()
build_tool_menu_options all opts idxs
printf '%s:%s\n' "${#opts[@]}" "${idxs[*]}"
menu_select() { shift 6; printf '%s\n' "$@" > "$AI_HUB_CACHE_FILE"; echo EXIT; }
select_tool_interactive
''')
        self.assertEqual(output.strip(), '1:0')
        menu = (self.work / 'values').read_text()
        self.assertEqual(menu.count('Demo'), 1)
        self.assertIn('1/2', menu)
        self.assertNotIn('中国版', menu)

    def test_install_menu_selects_only_requested_variant_once(self):
        output = self.hub(self.group_setup() + '''
menu_select() {
    case "$1" in
        *选择版本*) echo '1 0' ;; # 选择中国版，光标位于国际版
        *) echo '0 0' ;; # 选择唯一分组，光标重复同一项
    esac
}
operate_tool() { printf '%s:%s\n' "$1" "$2"; TOOL_STATUS=(); }
install_or_update_menu
''')
        self.assertEqual(output.strip(), '1:update')

    def test_variant_status_snapshot_survives_first_install(self):
        output = self.hub(self.group_setup() + '''
menu_select() { echo '0 1 0'; }
operate_tool() { printf '%s:%s\n' "$1" "$2"; TOOL_STATUS=(); }
_show_group_variant_menu demo
''')
        self.assertEqual(output.splitlines(), ['0:install', '1:update'])

    def test_variant_enter_and_cancel(self):
        output = self.hub(self.group_setup() + '''
menu_select() { echo 1; }
operate_tool() { printf '%s:%s\n' "$1" "$2"; }
_show_group_variant_menu demo
menu_select() { echo EXIT; }
_show_group_variant_menu demo
''')
        self.assertEqual(output.strip(), '1:update')

    def test_trae_cleans_only_after_copy_and_unmount_succeed(self):
        mount = self.work / 'mounted'
        (mount / 'TraeCode.app').mkdir(parents=True)
        destination = self.work / 'Applications'
        destination.mkdir()
        dmg = self.work / 'install.dmg'
        sidecar = self.work / 'install.dmg.url'
        unrelated = self.work / 'keep.dmg'
        unrelated.write_text('unrelated')
        for failure in ['copy', 'detach', 'none']:
            dmg.write_text('installer')
            sidecar.write_text('url')
            code = f'''source {shlex.quote(str(BACKEND))}
INSTALL_DIR={shlex.quote(str(destination))}
download_trae() {{ printf '%s\n' {shlex.quote(str(dmg))}; }}
hdiutil() {{ [[ "$1" != detach || {failure} != detach ]]; }}
grep() {{ cat >/dev/null; printf '%s\n' {shlex.quote(str(mount))}; }}
cp() {{ [[ {failure} != copy ]] || return 1; command cp "$@"; }}
install_trae
'''
            result = self.shell(code)
            self.assertEqual(result.returncode == 0, failure == 'none', result.stderr)
            self.assertEqual(dmg.exists(), failure != 'none')
            self.assertEqual(sidecar.exists(), failure != 'none')
            self.assertTrue(unrelated.exists())


if __name__ == '__main__':
    unittest.main()
