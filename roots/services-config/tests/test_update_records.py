"""Run with python3 -m unittest discover -s roots/services-config/tests -p 'test_*.py'."""
import base64
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess

TEMPLATE = Path(__file__).parents[1] / "templates/update-records.py.tftpl"


class UpdateRecordsTests(unittest.TestCase):
    def run_script(self, directory, payload, callback):
        text = TEMPLATE.read_text().replace(
            "${payload_b64}", base64.b64encode(json.dumps(payload).encode()).decode()
        )
        text = text.replace("/var/lib/bind9-tofu-records.json", str(directory / "manifest.json"))
        text = text.replace("/run/lock/bind9-tofu-records.lock", str(directory / "lock"))
        with patch("subprocess.run", side_effect=callback), patch("time.sleep"), patch("builtins.print"):
            exec(compile(text, str(TEMPLATE), "exec"), {})

    def test_replace_delete_and_preserve_unmanaged(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = directory / "manifest.json"
            manifest.write_text(json.dumps([["old.lylat.space.", "A"]]))
            calls = []

            def run(command, **kwargs):
                calls.append((command, kwargs["input"]))
                return subprocess.CompletedProcess(command, 0, "", "")

            self.run_script(directory, {"server": "10.8.53.1", "rrsets": [
                {"name": "app.lylat.space.", "type": "A", "ttl": 60, "data": ["10.8.10.1", "10.8.10.2"]}
            ]}, run)
            command, transaction = calls[0]
            self.assertIn("/etc/bind/tsig.key", command)
            self.assertIn("update delete old.lylat.space. A", transaction)
            self.assertIn("update delete app.lylat.space. A", transaction)
            self.assertIn("update add app.lylat.space. 60 A 10.8.10.1", transaction)
            self.assertIn("update add app.lylat.space. 60 A 10.8.10.2", transaction)
            self.assertNotIn("update delete lylat.space.", transaction)
            self.assertEqual(transaction.count("\nsend\n"), 1)
            self.assertEqual(json.loads(manifest.read_text()), [["app.lylat.space.", "A"]])

    def test_rejection_does_not_advance_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = directory / "manifest.json"
            original = json.dumps([["old.lylat.space.", "A"]])
            manifest.write_text(original)

            def rejected(command, **kwargs):
                return subprocess.CompletedProcess(command, 1, "", "REFUSED")

            with self.assertRaisesRegex(RuntimeError, "REFUSED"):
                self.run_script(directory, {"server": "10.8.53.1", "rrsets": []}, rejected)
            self.assertEqual(manifest.read_text(), original)


if __name__ == "__main__":
    unittest.main()
