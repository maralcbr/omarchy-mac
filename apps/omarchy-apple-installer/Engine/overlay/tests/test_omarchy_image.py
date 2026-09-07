# SPDX-License-Identifier: MIT
from contextlib import contextmanager
import hashlib
import io
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from omarchy_image import write_image, flush_device, WRITE_VERIFICATION


class ImageTests(unittest.TestCase):
    def setUp(self):
        self.data = b'x' * 8192
        self.info = SimpleNamespace(name='disk0s6', uuid='ABC', size=16384)
        self.target = io.BytesIO()
        self.flushed = []

    @contextmanager
    def opener(self, name):
        self.assertEqual(name, self.info.name)
        yield self.target

    def package(self, content=None, declared=None):
        content = self.data if content is None else content
        return SimpleNamespace(
            getinfo=lambda name: SimpleNamespace(file_size=len(content) if declared is None else declared),
            open=lambda member: io.BytesIO(content),
        )

    def run_write(self, package=None, flush=None):
        return write_image(package or self.package(), 'root.img', self.info,
                           opener=self.opener,
                           flush=flush or (lambda target: self.flushed.append(True)))

    def test_exact_write_hash_and_flush_receipt(self):
        receipt = self.run_write()
        self.assertEqual(self.target.getvalue(), self.data)
        self.assertEqual(receipt['content_sha256'], hashlib.sha256(self.data).hexdigest())
        self.assertEqual(receipt['verification'], WRITE_VERIFICATION)
        self.assertEqual(receipt['installed_bytes'], len(self.data))
        self.assertEqual(self.flushed, [True])

    def test_partial_writes_complete(self):
        class Partial(io.BytesIO):
            def write(self, data):
                return super().write(data[:137])
        self.target = Partial()
        self.run_write()
        self.assertEqual(self.target.getvalue(), self.data)

    def test_invalid_write_progress_never_flushes_or_returns_receipt(self):
        for result in [0, -1, None, 999999]:
            with self.subTest(result=result):
                self.target = SimpleNamespace(write=lambda data: result)
                with self.assertRaises(OSError):
                    self.run_write()
        self.assertEqual(self.flushed, [])

    def test_wrong_size_or_target_is_rejected_before_open(self):
        for name, size, declared in [('disk0', 16384, 8192), ('disk0s6', 4096, 8192),
                                      ('disk0s6', 16384, 0), ('disk0s6', 16384, 8191)]:
            self.info.name, self.info.size = name, size
            with self.subTest(name=name, size=size, declared=declared):
                with self.assertRaises(ValueError):
                    self.run_write(self.package(declared=declared))
        self.assertEqual(self.target.getvalue(), b'')

    def test_truncated_and_excess_stream_fail_without_flush(self):
        for content in [b'x' * 4096, b'x' * 9000]:
            with self.subTest(size=len(content)), self.assertRaises(ValueError):
                self.run_write(self.package(content, declared=8192))
        self.assertEqual(self.flushed, [])

    def test_bad_zip_crc_fails_without_flush(self):
        blob = io.BytesIO()
        with zipfile.ZipFile(blob, 'w', compression=zipfile.ZIP_STORED) as archive:
            archive.writestr('root.img', self.data)
        bad = bytearray(blob.getvalue())
        bad[bad.index(self.data)] ^= 1
        with zipfile.ZipFile(io.BytesIO(bad)) as archive:
            with self.assertRaises(zipfile.BadZipFile):
                self.run_write(archive)
        self.assertEqual(self.flushed, [])

    def test_write_exception_and_flush_failure_propagate(self):
        class Broken(io.BytesIO):
            def write(self, data):
                raise OSError('write failure')
        self.target = Broken()
        with self.assertRaisesRegex(OSError, 'write failure'):
            self.run_write()
        self.assertEqual(self.flushed, [])
        self.target = io.BytesIO()
        def fail(target):
            raise OSError('flush failure')
        with self.assertRaisesRegex(OSError, 'flush failure'):
            self.run_write(flush=fail)

    def test_darwin_device_flush_uses_media_sync_not_barrier(self):
        target = SimpleNamespace(flush=lambda: None, fileno=lambda: 55)
        with patch('omarchy_image.sys.platform', 'darwin'), \
             patch('omarchy_image.os.fstat', return_value=SimpleNamespace(st_mode=0o020600)), \
             patch('omarchy_image.fcntl.ioctl') as ioctl:
            flush_device(target)
        ioctl.assert_called_once_with(55, 0x80186416, bytes(24))


if __name__ == '__main__':
    unittest.main()
