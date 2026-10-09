import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("receiver", Path(__file__).with_name("receive-from-iphone.py"))
receiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receiver)

class OutboxTests(unittest.TestCase):
    def test_reject_traversal_and_windows_devices(self):
        for name in ["../secret", "a/b", r"a\b", "CON", "NUL.txt", "..", "file:stream", "a."]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                receiver.safe_name(name)

    def test_verified_transfer_and_no_overwrite(self):
        import hashlib
        data = b"project payload"
        with tempfile.TemporaryDirectory() as folder:
            first = receiver.save_payload(Path(folder), "project.zip", data, hashlib.sha256(data).hexdigest())
            second = receiver.save_payload(Path(folder), "project.zip", b"second", hashlib.sha256(b"second").hexdigest())
            self.assertNotEqual(first, second)
            self.assertEqual(first.read_bytes(), data)
            with self.assertRaises(ValueError):
                receiver.save_payload(Path(folder), "bad.zip", data, "0" * 64)

if __name__ == "__main__": unittest.main()
