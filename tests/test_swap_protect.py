"""No test reads host swap, invokes swapoff, or removes a real swap file."""
import contextlib
import importlib.util
import io
from pathlib import Path
import stat
import subprocess
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('swap_protect', Path(__file__).resolve().parents[1] / 'lib' / 'swap-protect.py')
swap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(swap)

META = dict(dev=1, ino=2, regular=True, nlink=1)
FILE = dict(path='/swap file', type='file', size_kib=1024, used_kib=10, **META)
ZRAM = dict(path='/dev/zram0', type='partition', size_kib=2048, used_kib=1)


class SwapTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.run = self.stack.enter_context(patch.object(swap.subprocess, 'run'))
        self.unlink = self.stack.enter_context(patch.object(swap.os, 'unlink'))

    def mock_flow(self, sequence):
        self.stack.enter_context(patch.object(swap, 'read_swaps', side_effect=sequence))
        self.stack.enter_context(patch.object(swap, 'zram_name', side_effect=lambda p: 'zram0' if p == '/dev/zram0' else None))
        self.stack.enter_context(patch.object(swap, 'healthy_zram', return_value=True))
        self.stack.enter_context(patch.object(swap, 'identity', return_value=dict(META)))
        self.stack.enter_context(patch.object(swap, 'sufficient_memory', return_value=True))

    def test_proc_path_escapes(self):
        content = 'Filename Type Size Used Priority\n/swap\\040space\\134040\\011tab\\012line file 123 5 -2\n'
        with patch.object(swap.Path, 'read_text', return_value=content):
            rows = swap.read_swaps()
        self.assertEqual(rows[0]['path'], '/swap space\\040\ttab\nline')
        self.assertEqual(rows[0]['used_kib'], 5)

    def test_fstab_exact_type_and_zram_preservation(self):
        original = '# /old none swap sw 0 0\n/dev/zram0 none swap sw 0 0\nUUID=root / ext4 defaults 0 1\n/swap\\040file none swap sw 0 0\nUUID=swap none swap sw 0 0\n'
        with patch.object(swap.Path, 'read_text', return_value=original), patch.object(swap.Path, 'write_text') as write, patch.object(swap, 'zram_name', return_value=None):
            swap.disable_fstab('/fake/fstab', '/fake/out')
        result = write.call_args[0][0]
        self.assertTrue(result.startswith('# /old none swap sw 0 0\n/dev/zram0'))
        self.assertIn('UUID=root / ext4 defaults 0 1\n', result)
        self.assertIn('# emmc-protect: /swap\\040file none swap', result)
        self.assertIn('# emmc-protect: UUID=swap none swap', result)

    def test_zram_backing_device_disqualifies_it(self):
        with patch.object(swap, 'zram_name', return_value='zram0'), patch.object(swap.Path, 'read_text', return_value='/dev/mmcblk0p2'):
            self.assertFalse(swap.healthy_zram([ZRAM]))

    def test_zram_without_writeback_supported(self):
        with patch.object(swap, 'zram_name', return_value='zram0'), patch.object(swap.Path, 'read_text', side_effect=FileNotFoundError):
            self.assertTrue(swap.healthy_zram([ZRAM]))

    def test_mixed_zram_writeback_is_not_healthy(self):
        for values in (['none', '/dev/mmcblk0p2'], ['/dev/mmcblk0p2', 'none']):
            with self.subTest(values=values), patch.object(swap, 'zram_name', side_effect=lambda p: p.rsplit('/', 1)[-1]), patch.object(swap.Path, 'read_text', side_effect=values):
                self.assertFalse(swap.healthy_zram([ZRAM, dict(ZRAM, path='/dev/zram1')]))

    def test_zram_requires_block_device(self):
        with patch.object(swap.os.path, 'realpath', return_value='/dev/zram0'), patch.object(swap.os, 'stat', return_value=types.SimpleNamespace(st_mode=stat.S_IFREG)):
            self.assertIsNone(swap.zram_name('/dev/zram0'))

    def test_memory_reserve(self):
        with patch.object(swap.Path, 'read_text', return_value='MemTotal: 1048576 kB\nMemAvailable: 104860 kB\n'):
            self.assertFalse(swap.sufficient_memory([FILE]))
        with patch.object(swap.Path, 'read_text', return_value='MemTotal: 1048576 kB\nMemAvailable: 104900 kB\n'):
            self.assertTrue(swap.sufficient_memory([FILE]))

    def test_off_never_deletes_and_uses_argv(self):
        self.mock_flow([[FILE, ZRAM], [ZRAM], [ZRAM]])
        swap.retire({'disk_swaps': [FILE]})
        self.run.assert_called_once_with(['swapoff', '--', '/swap file'], check=True)
        self.unlink.assert_not_called()

    def test_low_memory_does_not_swapoff(self):
        self.mock_flow([[FILE, ZRAM]])
        with patch.object(swap, 'sufficient_memory', return_value=False), self.assertRaises(RuntimeError):
            swap.retire({'disk_swaps': [FILE]})
        self.run.assert_not_called()
        self.unlink.assert_not_called()

    def test_missing_healthy_zram_does_not_swapoff(self):
        self.mock_flow([[FILE]])
        with patch.object(swap, 'healthy_zram', return_value=False), self.assertRaises(RuntimeError):
            swap.retire({'disk_swaps': [FILE]})
        self.run.assert_not_called()

    def test_identity_change_does_not_swapoff(self):
        self.mock_flow([[FILE, ZRAM]])
        with patch.object(swap, 'identity', return_value=dict(META, ino=999)), self.assertRaises(RuntimeError):
            swap.retire({'disk_swaps': [FILE]})
        self.run.assert_not_called()

    def test_second_swapoff_failure_deletes_neither_file(self):
        second = dict(FILE, path='/second')
        self.mock_flow([[FILE, second, ZRAM], [second, ZRAM], [second, ZRAM]])
        self.run.side_effect = [None, subprocess.CalledProcessError(1, ['swapoff'])]
        with self.assertRaises(subprocess.CalledProcessError):
            swap.retire({'disk_swaps': [FILE, second]}, delete=True)
        self.assertEqual(self.run.call_count, 2)
        self.unlink.assert_not_called()

    def test_new_disk_swap_stops_retirement(self):
        self.mock_flow([[FILE, dict(FILE, path='/new'), ZRAM]])
        with self.assertRaises(RuntimeError):
            swap.retire({'disk_swaps': [FILE]})
        self.run.assert_not_called()

    def test_swapoff_failure_preserves_file(self):
        self.mock_flow([[FILE, ZRAM]])
        self.run.side_effect = subprocess.CalledProcessError(1, ['swapoff'])
        with self.assertRaises(subprocess.CalledProcessError):
            swap.retire({'disk_swaps': [FILE]}, delete=True)
        self.unlink.assert_not_called()

    def test_swapoff_false_success_preserves_file(self):
        self.mock_flow([[FILE, ZRAM], [FILE, ZRAM]])
        with self.assertRaises(RuntimeError):
            swap.retire({'disk_swaps': [FILE]}, delete=True)
        self.unlink.assert_not_called()

    def test_delete_rejects_any_active_disk_swap(self):
        with patch.object(swap, 'healthy_zram', return_value=True), patch.object(swap, 'disk_swaps', return_value=[FILE]), self.assertRaises(RuntimeError):
            swap.delete_files({'disk_swaps': [FILE]})
        self.unlink.assert_not_called()

    def test_delete_only_safe_regular_file(self):
        with patch.object(swap, 'healthy_zram', return_value=True), patch.object(swap, 'disk_swaps', return_value=[]), patch.object(swap.os.path, 'realpath', side_effect=lambda p: p), patch.object(swap, 'identity', return_value=dict(META)):
            swap.delete_files({'disk_swaps': [FILE, dict(FILE, path='/dev/sda2', type='partition')]})
        self.unlink.assert_called_once_with(FILE['path'])

    def test_delete_rejects_disappeared_zram(self):
        with patch.object(swap, 'healthy_zram', return_value=False), self.assertRaises(RuntimeError):
            swap.delete_files({'disk_swaps': [FILE]})
        self.unlink.assert_not_called()

    def test_delete_rechecks_zram_before_unlink(self):
        with patch.object(swap, 'healthy_zram', side_effect=[True, False]), patch.object(swap, 'disk_swaps', return_value=[]), self.assertRaises(RuntimeError):
            swap.delete_files({'disk_swaps': [FILE]})
        self.unlink.assert_not_called()

    def test_delete_rejects_changed_inode_hardlink_symlink_special_path(self):
        with patch.object(swap.os.path, 'realpath', side_effect=lambda p: p):
            for metadata in (dict(META, ino=9), dict(META, nlink=2), dict(META, regular=False)):
                with self.subTest(metadata=metadata), patch.object(swap, 'identity', return_value=metadata):
                    self.assertFalse(swap.deletable(FILE))
            for path in ('/dev/file', '/proc/file', '/sys/file', '/run/file'):
                self.assertFalse(swap.deletable(dict(FILE, path=path)))


if __name__ == '__main__':
    unittest.main()
