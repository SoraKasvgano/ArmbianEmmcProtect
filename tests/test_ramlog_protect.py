"""Pure conversion tests; no host services or mounts are touched."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "ramlog_protect", Path(__file__).resolve().parents[1] / "lib" / "ramlog-protect.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

FIXTURE = '''#!/bin/bash
[ -f /etc/default/armbian-ramlog ] && . /etc/default/armbian-ramlog
LOG_OUTPUT="tee -a $LOG2RAM_LOG"
syncToDisk () {
    echo write-to-disk
}
syncFromDisk () {
    echo restore-from-disk
}
case "$1" in
    start)
        syncFromDisk
        RecreateLogs
        ;;
    stop)
        syncToDisk
        umount -l "$RAM_LOG"
        ;;
    postrotate)
        echo replay-from-disk
        ;;
esac
'''


class RamlogPatchTests(unittest.TestCase):
    def test_returns_before_io_and_keeps_mount_lifecycle(self):
        patched = MODULE.patch_ramlog(FIXTURE)
        self.assertIn("syncToDisk () {\n\treturn 0", patched)
        self.assertIn("syncFromDisk () {\n\treturn 0", patched)
        self.assertIn("postrotate)\n\t\texit 0", patched)
        self.assertIn("LOG_OUTPUT=cat", patched)
        self.assertIn('umount -l "$RAM_LOG"', patched)
        self.assertIn("RecreateLogs", patched)

    def test_repeated_patch_is_identical(self):
        patched = MODULE.patch_ramlog(FIXTURE)
        self.assertEqual(patched, MODULE.patch_ramlog(patched))

    def test_unknown_vendor_structure_rejected(self):
        variants = [
            FIXTURE.replace("syncToDisk () {", "syncToDisk () { echo inline;"),
            FIXTURE + "syncToDisk () {\n}\n",
            FIXTURE.replace('LOG_OUTPUT="tee -a $LOG2RAM_LOG"', 'LOG_OUTPUT="tee /unknown"'),
            FIXTURE.replace("postrotate)", "rotate)"),
            FIXTURE.replace('case "$1" in', 'case "$ACTION" in'),
            FIXTURE.replace("\n", "\r\n"),
        ]
        for fixture in variants:
            with self.subTest(fixture=fixture):
                with self.assertRaises(ValueError):
                    MODULE.patch_ramlog(fixture)

    def test_cli_same_path_and_invalid_input_preservation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ramlog"
            path.write_text(FIXTURE, encoding="utf-8", newline="\n")
            path.chmod(0o750)
            command = [sys.executable, str(SPEC.origin), str(path), str(path)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            first = path.read_bytes()
            self.assertEqual(0, subprocess.run(command, capture_output=True).returncode)
            self.assertEqual(first, path.read_bytes())
            if os.name == "posix":
                self.assertEqual(0o750, path.stat().st_mode & 0o777)
            path.write_text("unsupported vendor revision\n", encoding="utf-8", newline="\n")
            before = path.read_bytes()
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(1, result.returncode)
            self.assertIn("unsupported ramlog interpreter", result.stderr)
            self.assertEqual(before, path.read_bytes())


if __name__ == "__main__":
    unittest.main()
