import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class Module02PreparationTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        source = Path(__file__).resolve().parents[1]
        self.module = self.root / "module-02-workload-identity"
        self.module.mkdir()
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copyfile(source / "module-02-workload-identity/00-prepare-demo.sh",
                        self.module / "00-prepare-demo.sh")
        for name in ("env.sh", "connect.sh"):
            shutil.copyfile(source / "scripts" / name, scripts / name)
        self.log = self.root / "commands.jsonl"
        mock = self.root / "az"
        mock.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "args = sys.argv[1:]\n"
            'with Path(os.environ["COMMAND_LOG"]).open("a") as log:\n'
            '    log.write(json.dumps([Path(sys.argv[0]).name] + args) + "\\n")\n'
            'query = args[args.index("--query") + 1] if "--query" in args else ""\n'
            'if args[:3] == ["keyvault", "secret", "list"] and os.environ.get("DENY_SECRET_LIST") == "1":\n'
            '    print("Forbidden: setup user cannot list secrets", file=sys.stderr)\n'
            "    sys.exit(1)\n"
            'if args[:2] == ["account", "show"]: print("setup-user")\n'
            'elif args[:3] == ["ad", "signed-in-user", "show"]: print("setup-object-id")\n'
            'elif args[:2] == ["aks", "show"]:\n'
            '    if os.environ.get("MISSING_PREP") != "1":\n'
            '        print("true" if query.endswith(".enabled") else "https://issuer.example/")\n'
            'elif args[:2] == ["keyvault", "list"]:\n'
            '    if os.environ.get("MISSING_PREP") != "1": print("/vault-id")\n'
            'elif args[:2] == ["keyvault", "show"]:\n'
            '    if query == "id": print("/vault-id")\n'
            '    else: print("false" if os.environ.get("NON_RBAC") == "1" else "true")\n'
            'elif args[:3] == ["role", "assignment", "list"]:\n'
            '    if os.environ.get("MISSING_PREP") != "1": print("/role-id")\n'
            'elif args[:3] == ["keyvault", "secret", "list"]:\n'
            '    if os.environ.get("MISSING_PREP") != "1": print("/secret-id")\n'
        )
        mock.chmod(0o755)
        for name in ("kubectl", "kubelogin"):
            shutil.copyfile(mock, self.root / name)
            (self.root / name).chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.root}{os.pathsep}{os.environ['PATH']}",
            "COMMAND_LOG": str(self.log),
            "RESOURCE_GROUP": "lab-rg",
            "CLUSTER_NAME": "lab-aks",
            "KEY_VAULT_NAME": "lab-vault",
            "NAMESPACE": "orders",
            "MISSING_PREP": "",
            "NON_RBAC": "",
            "DENY_SECRET_LIST": "",
        }

    def run_prepare(self):
        return subprocess.run(
            ["bash", str(self.module / "00-prepare-demo.sh")],
            env=self.env, capture_output=True, text=True, timeout=10,
        )

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_prepared_lab_does_not_overwrite_secret_or_reconfigure_cluster(self):
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertFalse(any(c[1:3] == ["aks", "update"] for c in commands))
        self.assertFalse(any(c[1:3] == ["keyvault", "create"] for c in commands))
        self.assertFalse(any(c[1:4] == ["keyvault", "secret", "set"] for c in commands))
        self.assertTrue(any(c[:3] == ["kubectl", "create", "serviceaccount"]
                            for c in commands))
        self.assertIn("leaving its value unchanged", result.stdout)

    def test_missing_preparation_enables_cluster_and_seeds_only_fake_value(self):
        self.env["MISSING_PREP"] = "1"
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        update = next(c for c in commands if c[1:3] == ["aks", "update"])
        self.assertIn("--enable-workload-identity", update)
        self.assertIn("--enable-oidc-issuer", update)
        create = next(c for c in commands if c[1:3] == ["keyvault", "create"])
        self.assertIn("--enable-rbac-authorization", create)
        seed = next(c for c in commands if c[1:4] == ["keyvault", "secret", "set"])
        self.assertEqual(seed[seed.index("--value") + 1],
                         "demo-only-not-a-real-connection-string")
        self.assertEqual(seed[-2:], ["-o", "none"])

    def test_existing_non_rbac_vault_is_not_converted_or_seeded(self):
        self.env["NON_RBAC"] = "1"
        result = self.run_prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("will not convert", result.stderr)
        self.assertFalse(any(c[1:3] == ["keyvault", "create"]
                             for c in self.commands()))
        self.assertFalse(any(c[1:4] == ["keyvault", "secret", "set"]
                             for c in self.commands()))

    def test_secret_list_failure_is_explicit_and_does_not_seed(self):
        self.env["DENY_SECRET_LIST"] = "1"
        result = self.run_prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Forbidden", result.stderr)
        self.assertIn("No secret was written", result.stderr)
        self.assertFalse(any(c[1:4] == ["keyvault", "secret", "set"]
                             for c in self.commands()))


if __name__ == "__main__":
    unittest.main()
