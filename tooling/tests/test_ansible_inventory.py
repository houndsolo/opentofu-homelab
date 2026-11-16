"""Run with python3 -m unittest discover -s tooling/tests (needs python-hcl2: the repo shell)."""
import ipaddress
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "ansible/inventory/tfvars.py"
NODES = REPO / "inventory/auto.tfvars/nodes.auto.tfvars"


def run(*args):
    result = subprocess.run([sys.executable, str(SCRIPT), *args], text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout


class AnsibleInventoryTests(unittest.TestCase):
    def test_fixture_groups_addresses_and_order(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nodes.auto.tfvars"
            path.write_text('''nodes = {
  management_prefix = "10.9.0.0/24"
  cluster_api_node  = "b"
  proxmox = {
    c = { id = 30 }
    b = { id = 3 }
    s = { id = 7, standalone = true }
  }
}
''')
            inventory = json.loads(run("--list", "--file", str(path)))
        self.assertEqual(inventory["cluster"]["hosts"], ["b", "c"])  # id order, standalone left out
        self.assertEqual(inventory["ceph"]["hosts"], ["b", "c"])
        self.assertEqual(inventory["standalone"]["hosts"], ["s"])
        self.assertEqual(inventory["pve"]["hosts"], ["b", "s", "c"])
        self.assertEqual(inventory["_meta"]["hostvars"]["c"], {"ansible_host": "10.9.0.30", "pve_node_id": 30})
        self.assertEqual(inventory["all"]["vars"], {"ansible_user": "root"})

    def test_real_tfvars_match_cidrhost(self):
        import hcl2
        with NODES.open() as source:
            nodes = hcl2.load(source)["nodes"]
        prefix = ipaddress.ip_network(nodes["management_prefix"])
        inventory = json.loads(run("--list"))
        hostvars = inventory["_meta"]["hostvars"]
        self.assertEqual(set(hostvars), set(nodes["proxmox"]))
        for name, node in nodes["proxmox"].items():
            self.assertEqual(hostvars[name]["ansible_host"], str(prefix[node["id"]]))
            group = "standalone" if node.get("standalone") else "cluster"
            self.assertIn(name, inventory[group]["hosts"])

    def test_host_mode_and_yaml(self):
        self.assertEqual(json.loads(run("--host", "anything")), {})
        self.assertIn("ansible_host:", run("--yaml"))


if __name__ == "__main__":
    unittest.main()
