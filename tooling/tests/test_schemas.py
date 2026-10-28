"""Keep the VM setting schemas in step; OpenTofu cannot share one object type."""
from pathlib import Path
import re
import unittest

SCHEMA = Path(__file__).resolve().parents[2] / 'inventory/schema'
FIELD = re.compile(r'^\s+(\w+)\s+= (.+?)\s*(?:#.*)?$')


def block(text, start):
    """Fields between `start` and its closing `})` at the same indentation."""
    lines = text.splitlines()
    index = next(i for i, line in enumerate(lines) if start in line)
    indent = len(lines[index]) - len(lines[index].lstrip())
    fields = {}
    for line in lines[index + 1:]:
        if line.strip().startswith('})') and len(line) - len(line.lstrip()) == indent:
            return fields
        match = FIELD.match(line)
        if match and len(line) - len(line.lstrip()) == indent + 2:
            fields[match[1]] = match[2]
    raise ValueError(f'Unclosed block: {start}')


class VmSchemaTests(unittest.TestCase):
    def setUp(self):
        self.vm = (SCHEMA / 'vm.tf').read_text()
        self.vms = (SCHEMA / 'vms.tf').read_text()
        self.vm_config = (SCHEMA / 'vm-config.tf').read_text()

    def test_per_vm_config_matches(self):
        start = 'config = optional(object({'
        self.assertEqual(block(self.vm, start), block(self.vms, start))

    def test_shared_defaults_cover_every_config_setting(self):
        config = set(block(self.vm, 'config = optional(object({'))
        defaults = set(block(self.vm_config, 'type = object({'))
        # SSH keys and user are chosen per VM, not shared.
        self.assertEqual(config - {'ssh_pubkeys', 'ssh_username'}, defaults)

    def test_vm_fields_match_inventory_fields(self):
        vm = set(block(self.vm, 'type = object({'))
        vms = set(block(self.vms, 'type = map(object({'))
        # owner and role only select the root; the module never sees them.
        self.assertEqual(vms - {'owner', 'role'}, vm)


if __name__ == '__main__':
    unittest.main()
