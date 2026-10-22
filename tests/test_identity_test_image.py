"""Self-contained tests for the Module 2 identity-test image helpers.

Run from repo/ with the standard library only:
  python3 -m unittest discover -s tests -p 'test_identity_test_image*.py'

Everything is mocked (curl, docker); no network, registry or cloud is touched.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent

FAKE_CURL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] == "--disable"
assert "--user" not in args and "--netrc" not in args
with Path(os.environ["COMMAND_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\n")
output = Path(args[args.index("--output") + 1])
is_token = args[-1] == "https://ghcr.io/token"
if (is_token and os.environ.get("DENY_IMAGE") == "1") or (not is_token and os.environ.get("DENY_MANIFEST") == "1"):
    print("401 Unauthorized" if is_token else "404 Not Found", file=sys.stderr)
    sys.exit(1)
if is_token:
    output.write_text('{"token": "anonymous-test-token"}')
else:
    headers = Path(args[args.index("--header") + 1][1:]).read_text()
    assert headers == "Authorization: Bearer anonymous-test-token\n", headers
    output.write_text('{"schemaVersion": 2}')
'''

FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["DOCKER_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\n")
if args[:2] == ["buildx", "version"]:
    sys.exit(1 if os.environ.get("NO_BUILDX") == "1" else 0)
if args[:2] == ["buildx", "build"] and os.environ.get("FAIL_BUILD") == "1":
    print("denied: permission_denied", file=sys.stderr)
    sys.exit(1)
'''


def make_layout(root: Path):
    """Copy the real student scripts into an isolated repo-shaped tree."""
    for rel in (
        "scripts/env.sh",
        "scripts/check-identity-test-image.sh",
        "apps/identity-test/build-and-push.sh",
    ):
        dest = root / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO / rel, dest)
    m2 = root / "module-02-workload-identity"
    m2.mkdir(parents=True, exist_ok=True)
    (m2 / "orders-api-sa-test.yaml").write_text(
        "      image: ghcr.io/example/identity-test:1.0.1\n"
    )
    bindir = root / "bin"
    bindir.mkdir(exist_ok=True)
    for name, body in (("curl", FAKE_CURL), ("docker", FAKE_DOCKER)):
        path = bindir / name
        path.write_text(body)
        path.chmod(0o755)
    return bindir


class Base(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name) / "repo"
        self.root.mkdir()
        bindir = make_layout(self.root)
        self.log = self.root / "command.json"
        self.docker_log = self.root / "docker.json"
        self.saved_config = self.root / "saved-config"
        self.saved_config.mkdir()
        (self.saved_config / "config.json").write_text('{"auths": {}}\n')
        self.env = {
            **os.environ,
            "PATH": f"{bindir}{os.pathsep}{os.environ['PATH']}",
            "DOCKER_CONFIG": str(self.saved_config),
            "COMMAND_LOG": str(self.log),
            "DOCKER_LOG": str(self.docker_log),
            "IDENTITY_TEST_IMAGE": "",
            "DENY_IMAGE": "",
            "DENY_MANIFEST": "",
            "NO_BUILDX": "",
            "FAIL_BUILD": "",
        }

    def run_script(self, rel, *arguments, cwd=None):
        return subprocess.run(
            ["bash", str(self.root / rel), *arguments],
            env=self.env,
            cwd=cwd or self.root,
            capture_output=True,
            text=True,
            timeout=10,
        )


class CheckerTests(Base):
    def check(self, *arguments, cwd=None):
        return self.run_script("scripts/check-identity-test-image.sh", *arguments, cwd=cwd)

    def test_default_comes_from_manifest_and_isolates_saved_credentials(self):
        # Run from an unrelated directory: no instructor/.env or cwd dependence.
        result = self.check(cwd=self.workspace.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        token_args, manifest_args = [
            json.loads(line) for line in self.log.read_text().splitlines()
        ]
        self.assertIn("scope=repository:example/identity-test:pull", token_args)
        self.assertEqual(
            manifest_args[-1], "https://ghcr.io/v2/example/identity-test/manifests/1.0.1"
        )
        check_dir = Path(token_args[token_args.index("--output") + 1]).parent
        self.assertNotEqual(check_dir, self.saved_config)
        self.assertFalse(check_dir.exists())
        self.assertEqual((self.saved_config / "config.json").read_text(), '{"auths": {}}\n')
        self.assertFalse(self.docker_log.exists(), "checker must not invoke docker")

    def test_denied_image_fails_with_recovery_and_cleans_up(self):
        self.env["DENY_IMAGE"] = "1"
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("401 Unauthorized", result.stderr)
        self.assertIn("build-and-push.sh <your-ghcr-owner>", result.stderr)
        self.assertIn("Public", result.stderr)
        self.assertIn("not a Workload Identity failure", result.stderr)
        self.assertNotIn("instructor", result.stderr)
        self.assertNotIn("access passed", result.stdout)
        args = json.loads(self.log.read_text())
        self.assertFalse(Path(args[args.index("--output") + 1]).parent.exists())

    def test_missing_manifest_fails_after_token_succeeds(self):
        self.env["DENY_MANIFEST"] = "1"
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("404 Not Found", result.stderr)
        self.assertNotIn("access passed", result.stdout)
        args = json.loads(self.log.read_text().splitlines()[-1])
        self.assertFalse(Path(args[args.index("--output") + 1]).parent.exists())

    def test_explicit_image_beats_environment_beats_default(self):
        self.env["IDENTITY_TEST_IMAGE"] = "ghcr.io/example/from-env:1"
        result = self.check("ghcr.io/example/explicit:2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.log.read_text().splitlines()[-1])[-1],
            "https://ghcr.io/v2/example/explicit/manifests/2",
        )
        self.log.unlink()
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.log.read_text().splitlines()[-1])[-1],
            "https://ghcr.io/v2/example/from-env/manifests/1",
        )

    def test_rejects_non_ghcr_image_without_network(self):
        result = self.check("docker.io/library/python:3")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected a GHCR image", result.stderr)
        self.assertFalse(self.log.exists())


class PublisherTests(Base):
    def publish(self, *arguments):
        return self.run_script("apps/identity-test/build-and-push.sh", *arguments)

    def test_requires_explicit_owner_and_never_defaults(self):
        self.env["GHCR_OWNER"] = "mhadaily"  # must not be honoured by the student script
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("<ghcr-owner>", result.stderr)
        self.assertFalse(self.docker_log.exists())

    def test_rejects_invalid_owner(self):
        result = self.publish("bad/owner")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.docker_log.exists())

    def test_builds_amd64_pushes_tag_and_does_not_login(self):
        result = self.publish("Student-Org")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.docker_log.read_text().splitlines()]
        self.assertNotIn("login", [c[0] for c in calls])
        build = next(c for c in calls if c[:2] == ["buildx", "build"])
        self.assertIn("--push", build)
        self.assertEqual(build[build.index("--platform") + 1], "linux/amd64")
        self.assertEqual(
            build[build.index("-t") + 1], "ghcr.io/student-org/orders-identity-test:1.0.1"
        )
        self.assertEqual(Path(build[-1]).resolve(), (self.root / "apps/identity-test").resolve())
        self.assertIn("scripts/check-identity-test-image.sh ghcr.io/student-org/", result.stdout)
        self.assertIn("Public", result.stdout)

    def test_reports_missing_buildx(self):
        self.env["NO_BUILDX"] = "1"
        result = self.publish("student")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Buildx", result.stderr)

    def test_reports_push_failure_clearly(self):
        self.env["FAIL_BUILD"] = "1"
        result = self.publish("student")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("permission_denied", result.stderr)
        self.assertIn("write:packages", result.stderr)
        self.assertNotIn("Pushed", result.stdout)


if __name__ == "__main__":
    unittest.main()
