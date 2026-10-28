"""Run with python3 -m unittest discover -s tooling/tests; set TOFU_TEST_BINARY if needed."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

WRAPPER = Path(__file__).resolve().parents[1] / "with-secrets"
TOFU = os.environ.get("TOFU_TEST_BINARY") or shutil.which("tofu") or shutil.which("terraform")


@unittest.skipUnless(TOFU, "OpenTofu/Terraform is required")
class SharedSecretsTests(unittest.TestCase):
    def test_preserve_types_and_escaping_without_printing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "passwords.secret.auto.tfvars"
            path.write_text('token = "fake\\nvalue"\nssh_keys = { laptop = "ssh-ed25519 fake" }\nflag = true\nattempts = 42\noptional = null\n')
            child = "import os,json; print(json.dumps({k:os.getenv('TF_VAR_'+k) for k in ['token','ssh_keys','flag','attempts','optional']}))"
            result = subprocess.run([sys.executable, str(WRAPPER), "--file", str(path), "--tofu", TOFU, "--", sys.executable, "-c", child], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            values = json.loads(result.stdout)
            self.assertEqual(values['token'], 'fake\nvalue')
            self.assertEqual(json.loads(values['ssh_keys']), {'laptop': 'ssh-ed25519 fake'})
            self.assertEqual(values['flag'], 'true')
            self.assertEqual(values['attempts'], '42')
            self.assertIsNone(values['optional'])
            self.assertNotIn('fake', result.stderr)

    def test_parse_errors_do_not_leak_secret_content(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secret.tfvars"
            path.write_text('token = "DO_NOT_PRINT_THIS\n')
            result = subprocess.run([sys.executable, str(WRAPPER), "--file", str(path), "--tofu", TOFU, "--", sys.executable, "-c", "pass"], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('DO_NOT_PRINT_THIS', result.stdout + result.stderr)

    def test_root_secret_symlink_is_reported_without_removing_target(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            secret = base / 'secret.tfvars'
            secret.write_text('token = "fake"\n')
            root = base / 'root'
            root.mkdir()
            link = root / 'passwords.secret.auto.tfvars'
            link.symlink_to(secret)
            result = subprocess.run([sys.executable, str(WRAPPER), '--file', str(secret), '--tofu', TOFU, '--', TOFU, '-chdir=' + str(root), 'plan'], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('already auto-loads', result.stderr)
            self.assertTrue(secret.exists())
            self.assertTrue(link.is_symlink())

    def test_unused_global_settings_do_not_warn(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / 'root'
            root.mkdir()
            (root / 'main.tf').write_text('variable "token" {\n type = string\n sensitive = true\n}\n')
            secret = base / 'secret.tfvars'
            secret.write_text('token = "fake"\ngreatfox_api_token = "also-fake"\nssh_keys = { desktop = "fake-key" }\n')
            result = subprocess.run([sys.executable, str(WRAPPER), '--file', str(secret), '--tofu', TOFU, '--', TOFU, '-chdir=' + str(root), 'plan', '-input=false', '-no-color'], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('undeclared variable', result.stdout + result.stderr)
