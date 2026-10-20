"""Exercise the interactive runner with a fake tofu; never contact infrastructure."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'walk-roots.sh'


class WalkRootsTests(unittest.TestCase):
    def run_walk(self, answers, *roots, fail=''):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fake = directory / 'fake tofu'
            log = directory / 'calls'
            fake.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
command = sys.argv[2]
if command == os.environ.get('TEST_FAIL'): sys.exit(1)
if command == 'plan': sys.exit(2)
''')
            fake.chmod(0o755)
            env = dict(os.environ, TOFU_BIN=str(fake), TEST_LOG=str(log), TEST_FAIL=fail)
            result = subprocess.run(['bash', str(SCRIPT), '--no-secrets', *roots],
                                    input=answers, text=True, capture_output=True, env=env, cwd='/tmp')
            import json
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_apply_requires_yes_and_uses_saved_plan(self):
        result, calls = self.run_walk('a\nyes\n', 'services-vms')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[1] for call in calls], ['init', 'validate', 'plan', 'apply'])
        plan = next(arg.removeprefix('-out=') for arg in calls[2] if arg.startswith('-out='))
        self.assertEqual(calls[3][-1], plan)
        self.assertFalse(Path(plan).parent.exists())

    def test_declining_apply_never_applies(self):
        result, calls = self.run_walk('a\nno\n', 'workloads')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('apply', [call[1] for call in calls])

    def test_failure_stops_before_next_root(self):
        result, calls = self.run_walk('a\nyes\na\nyes\n', 'services-vms', 'services-config', fail='plan')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(call[0].endswith('/services-vms') for call in calls))
        self.assertNotIn('apply', [call[1] for call in calls])

    def test_bootstrap_then_full_apply(self):
        result, calls = self.run_walk('b\nyes\na\nyes\n', 'services-config')
        self.assertEqual(result.returncode, 0, result.stderr)
        plans = [call for call in calls if call[1] == 'plan']
        self.assertEqual(len(plans), 2)
        self.assertIn('-target=terraform_data.bind9', plans[0])
        self.assertFalse(any(arg.startswith('-target=') for arg in plans[1]))
        self.assertEqual(sum(call[1] == 'apply' for call in calls), 2)

    def test_selected_roots_follow_dependency_order(self):
        result, calls = self.run_walk('p\np\n', 'services-config', 'services-vms')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(calls[0][0].endswith('/services-vms'))
        self.assertTrue(calls[-1][0].endswith('/services-config'))

    def test_skip_and_unknown_root_do_not_run_tofu(self):
        result, calls = self.run_walk('\n', 'services-vms')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        result, calls = self.run_walk('', 'proxmox-settings')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, [])
