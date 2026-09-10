#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const text = fs.readFileSync(path.join(root, 'default/omarchy/omarchy-menu.jsonc'), 'utf8')
const rows = Object.fromEntries(text.split('\n').filter(line => /^  "/.test(line)).map(line => {
  const object = JSON.parse('{' + line.trim().replace(/,$/, '') + '}')
  return Object.entries(object)[0]
}))
assert(rows['remove.ai'] && !rows['remove.ai'].action, 'selected AI removers have a reachable parent')
assert(rows['remove.dictation'] && !rows['remove.ai.dictation'], 'Dictation retains its baseline location')
const selected = {'t3-code': ['t3code-bin', '\ue908'], hermes: ['hermes-desktop', '\ue90a'], openclaw: ['openclaw', '\ue90c'], perplexity: ['perplexity', '\ue90b']}
for (const [id, [pkg, glyph]] of Object.entries(selected)) {
  const install = rows[`install.ai.${id}`], remove = rows[`remove.ai.${id}`]
  assert(install && remove, `${id} has install and remove entries`)
  assertEqual(install.when, `omarchy-install-available install.ai.${id} && ! omarchy-pkg-present ${pkg}`, `${id} preserves baseline install visibility`)
  assertEqual(remove.when, `omarchy-pkg-present ${pkg}`, `${id} removal follows package presence`)
  assertEqual(install.icon, glyph, `${id} install uses selected glyph`)
  assertEqual(remove.icon, glyph, `${id} remove uses selected glyph`)
  assertEqual(install.iconFont, 'omarchy', `${id} uses the packaged icon font`)
  assert(fs.existsSync(path.join(root, `bin/omarchy-remove-ai-${id}`)), `${id} remover exists`)
}
assertDeepEqual(Object.keys(rows).filter(k => k.startsWith('remove.ai.')).sort(), Object.keys(selected).map(k => `remove.ai.${k}`).sort(), 'removal prerequisite imports no unselected apps')
assertDeepEqual(Object.keys(rows).filter(k => k.startsWith('setup.default.agent.')).map(k => k.split('.').pop()).sort(), ['claude', 'codex', 'copilot', 'crush', 'cursor-agent', 'gemini', 'grok', 'hermes', 'muse', 'omp', 'openclaw', 'opencode', 'pi'], 'baseline agent choices survive with only selected release agents added')
for (const id of ['setup.default.agent.cursor-agent', 'setup.default.editor.cursor', 'install.editor.cursor']) {
  assertEqual(rows[id].icon, '\ue90d', `${id} uses the upstream Cursor glyph`)
  assertEqual(rows[id].iconFont, 'omarchy', `${id} uses the packaged icon font`)
}
assertEqual(rows['setup.default.editor.cursor'].when, 'omarchy-cmd-present cursor', 'Cursor editor retains baseline default visibility')
assertEqual(rows['install.editor.cursor'].when, 'omarchy-install-available install.editor.cursor && ! omarchy-pkg-present cursor-bin', 'Cursor editor retains baseline install visibility')
assertEqual(rows['setup.default.agent.muse'].icon, '󰛤', 'Muse uses the Nerd infinity glyph')
assert(!rows['setup.default.agent.muse'].iconFont, 'Muse needs no Omarchy font addition')
assert(!fs.existsSync(path.join(root, 'bin/omarchy-theme-set-openclaw')), 'deferred OpenClaw theming is absent')
JS

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"
export TEST_CALLS="$test_tmp/calls"
cat >"$test_tmp/bin/mise" <<'SH'
#!/bin/bash
printf 'mise:%s\n' "$*" >>"$TEST_CALLS"
SH
cat >"$test_tmp/bin/omarchy-mise-install" <<'SH'
#!/bin/bash
printf 'stub:%s\n' "$*" >>"$TEST_CALLS"
SH
cat >"$test_tmp/bin/omarchy-install-hermes-cli" <<'SH'
#!/bin/bash
printf 'hermes:%s\n' "$*" >>"$TEST_CALLS"
exit 1
SH
chmod +x "$test_tmp/bin"/*
PATH="$test_tmp/bin:$PATH" bash -eE "$ROOT/install/user/mise.sh"
grep -qx 'mise:settings set upgrade.auto_prune false' "$TEST_CALLS" || fail "new users retain running mise versions"
grep -qx 'hermes:' "$TEST_CALLS" || fail "new users receive the Hermes CLI stub"
grep -qx 'stub:cursor-agent' "$TEST_CALLS" || fail "new users receive the selected Cursor CLI stub"
grep -Fx 'stub:http:muse[url=https://api.meta.ai/muse-launcher.sh,bin=muse,version_list_url=https://api.meta.ai/muse-code/channels/muse-stable,version_json_path=.version] muse' "$TEST_CALLS" >/dev/null || fail "new users receive the selected official Muse launcher stub"
! grep -Eq 'stub:.*(ori|antigravity|hey-cli)' "$TEST_CALLS" || fail "mise setup avoids unrelated prerequisites"
pass "baseline mise setup tolerates an unfinished Hermes Desktop and disables pruning"
: >"$TEST_CALLS"
PATH="$test_tmp/bin:$PATH" bash -euo pipefail "$ROOT/migrations/1787215483.sh" >/dev/null
grep -qx 'mise:settings set upgrade.auto_prune false' "$TEST_CALLS" || fail "existing users retain running mise versions"
pass "mise migration applies the same no-pruning setting"

# Exercise the documented font workflow, not just fontconfig's charset reader.
# Work on a disposable copy: adding a fixture must never edit the source font.
python3 - "$ROOT" "$test_tmp" <<'PY'
import pathlib
import runpy
import shutil
import struct
import subprocess
import sys

root, temporary = map(pathlib.Path, sys.argv[1:])
tool = root / 'bin/omarchy-dev-font'
font = temporary / 'omarchy.ttf'
shutil.copyfile(root / 'default/fonts/omarchy/omarchy.ttf', font)
api = runpy.run_path(str(tool))

def snapshot():
    data, tables, count = api['load_font'](str(font))
    offsets = api['read_loca'](data, tables, count)
    names = api['read_names'](data, tables['post'][0], count)
    cmap = api['read_cmap'](data, tables['cmap'][0])
    start = tables['glyf'][0]
    glyphs = [data[start + offsets[i]:start + offsets[i + 1]].rstrip(b'\0') for i in range(count)]
    metrics = data[tables['hmtx'][0]:sum(tables['hmtx'])]
    assert struct.unpack_from('>I', data, tables['post'][0])[0] == 0x20000
    return names, cmap, glyphs, metrics

before = snapshot()
assert before[0][before[1][0xE90D]] == 'cursor'
assert 0xE909 not in before[1]
listing = subprocess.check_output([sys.executable, str(tool), 'list', '--font', str(font)], text=True)
for cp, name, _ in api['glyph_list'](str(font)):
    assert f'U+{cp:04X}' in listing and name in listing
assert 'U+E90D' in listing and 'cursor' in listing
print('ok - the shipped font lists its named Cursor mark through the real font tool')

svg = temporary / 'fixture.svg'
svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2 L22 2 L22 22 L2 22 Z"/></svg>')
subprocess.run([sys.executable, str(tool), 'add', 'release-fixture', str(svg), '--font', str(font)], check=True, stdout=subprocess.DEVNULL)
after = snapshot()
assert after[0] == before[0] + ['release-fixture']
assert after[1] == before[1] | {0xE90E: len(before[0])}
assert after[2][:-1] == before[2]
assert after[3].startswith(before[3])
print('ok - adding a local SVG preserves every existing name, codepoint, outline and metric')
listing = subprocess.check_output([sys.executable, str(tool), 'list', '--font', str(font)], text=True)
assert 'U+E90E' in listing and 'release-fixture' in listing and 'cursor' in listing
print('ok - the real font tool lists the newly added disposable glyph')
unchanged = font.read_bytes()
result = subprocess.run([sys.executable, str(tool), 'add', 'collision', str(svg), '--codepoint', 'E90D', '--font', str(font)], capture_output=True, text=True)
assert result.returncode != 0 and 'already used' in result.stderr
assert font.read_bytes() == unchanged
print('ok - adding over Cursor is rejected without changing the font')
PY
