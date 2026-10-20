"""Release boundary checks; source assertions are not native UI acceptance."""
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def source_tree(tmp_path):
    for relative in (ROOT / 'scripts/public-source-files.txt').read_text().splitlines():
        destination = tmp_path / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, destination)
    return tmp_path


def check(root):
    return subprocess.run(['bash', 'scripts/check-source-manifest.sh'], cwd=root,
                          capture_output=True, text=True)


def test_approved_manifest(source_tree):
    assert check(source_tree).returncode == 0


@pytest.mark.parametrize('relative', ['scripts/private-backup.txt', 'plugin/config.json',
                                     'app/Sources/A0Notch/notes.txt', 'tests/unreviewed.py'])
def test_unexpected_file_refused(source_tree, relative):
    (source_tree / relative).write_text('not approved')
    result = check(source_tree)
    assert result.returncode != 0
    assert 'Unexpected source files' in result.stderr


def test_missing_approved_file_refused(source_tree):
    (source_tree / 'README.md').unlink()
    assert check(source_tree).returncode != 0


def test_linked_input_refused(source_tree):
    path = source_tree / 'README.md'
    path.unlink()
    path.symlink_to(ROOT / 'README.md')
    assert check(source_tree).returncode != 0


def test_submission_clears_transient_password():
    source = (ROOT / 'app/Sources/A0Notch/ConnectionSettings.swift').read_text()
    submit = source.split('private func run(test: Bool) {', 1)[1]
    assert submit.index('store.connectLive(') < submit.index('password = ""')
    assert 'savePassword = false' in submit


def test_discovery_does_not_choose_another_chat():
    source = (ROOT / 'app/Sources/A0Notch/IslandStore.swift').read_text()
    loop = source.split('while !Task.isCancelled {', 1)[1].split('try await Task.sleep', 1)[0]
    assert 'self.focus(created)' in loop  # explicit new-chat operation only
    assert 'self.creationSelection == self.selection' in loop
    assert 'if !self.focusedID.isEmpty { self.clearSelection() }' in loop
    assert '.first' not in loop
    refresh = source.split('func refreshSelectedChat() {', 1)[1]
    assert 'permits(target)' in refresh.split('detailTask = Task', 1)[0]
