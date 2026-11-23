"""Exercise production installer helpers with synthetic inputs and a fake kubectl."""

import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
SOURCE = (ROOT / "k0s_cluster_with_stack.sh").read_text()
CANARY = "installer-checkpoint-canary-2026"
URL = "postgresql://user:" + CANARY + "@postgres:5432/checkpoints"


def function(name):
    start = re.search(r"^" + name + r"\(\) \{", SOURCE, re.M).start()
    end = re.search(r"^\}$", SOURCE[start:], re.M).end() + start
    return SOURCE[start:end]


class CheckpointSecrets(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.config = {"aiPlatform": {
            "features": [{"name": "agentruntime", "checkpointDbSecretRef": "checkpoint"}],
            "agentRuntime": {"checkpointSecrets": [{"name": "checkpoint", "create": True, "databaseUrlEnv": "TEST_CHECKPOINT_URL"}]},
        }}

    def run_installer(self, *, url=URL, existing=None, failure="", method="create_agentruntime_checkpoint_secrets"):
        # JSON syntax is valid YAML. Keep the deployment .yaml extension so yq
        # returns YAML scalars, like the real installer configuration files.
        config = self.path / "config.yaml"
        config.write_text(json.dumps(self.config))
        existing_file = self.path / "existing.json"
        existing_file.write_text(json.dumps(existing) if existing is not None else "")
        events = self.path / "events"
        created = self.path / "created"
        events.write_text("")
        created.write_text("")
        helpers = "\n".join(function(n) for n in (
            "validate_agentruntime_checkpoint_config", "render_agentruntime_checkpoint_secret_manifest",
            "create_agentruntime_checkpoint_secrets", "install_ai_platform_cr",
        ))
        script = '''set -euo pipefail
log() { echo "$*"; }
warn() { echo "$*" >&2; }
err() { echo "$*" >&2; exit 1; }
need() { :; }
k0s_agentruntime_feature_enabled() { return 0; }
kubectl() {
  if [[ " $* " == *" get secret "* ]]; then
    echo get >> "$EVENTS"
    if [[ "$FAILURE" == get ]]; then echo "$CANARY" >&2; return 1; fi
    cat "$EXISTING"
  elif [[ " $* " == *" create -f - "* ]]; then
    echo create >> "$EVENTS"
    if [[ "$FAILURE" == create ]]; then echo "$CANARY" >&2; return 1; fi
    cat > "$CREATED"
  else
    echo later-operation >> "$EVENTS"
    return 99
  fi
}
'''
        env = dict(os.environ, CONFIG_FILE=str(config), AI_NS="fixture-namespace", EVENTS=str(events),
                   CREATED=str(created), EXISTING=str(existing_file), FAILURE=failure, CANARY=CANARY)
        env.pop("TEST_CHECKPOINT_URL", None)
        if url is not None:
            env["TEST_CHECKPOINT_URL"] = url
        result = subprocess.run(["bash"], input=script + helpers + "\n" + method + "\n", env=env,
                                text=True, capture_output=True, timeout=20)
        output = result.stdout + result.stderr
        self.assertNotIn("syntax error", output)
        # Scan both the original and reversible representations in diagnostics.
        for value in (CANARY, URL, base64.b64encode(CANARY.encode()).decode(), base64.b64encode(URL.encode()).decode()):
            self.assertNotIn(value, output)
        return result, events.read_text().splitlines(), created.read_text()

    def test_creation_and_idempotent_rerun(self):
        result, events, raw = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["get", "create"])
        secret = json.loads(raw)
        self.assertEqual(secret["metadata"], {"name": "checkpoint", "namespace": "fixture-namespace"})
        self.assertEqual(secret["type"], "Opaque")
        self.assertEqual(set(secret["data"]), {"DATABASE_URL", "PG_HOST", "PG_PORT", "PG_USER", "PG_PASSWORD", "PG_DBNAME"})
        self.assertEqual(base64.b64decode(secret["data"]["PG_PASSWORD"]).decode(), CANARY)
        secret["metadata"]["resourceVersion"] = "do-not-change"
        result, events, raw = self.run_installer(existing=secret)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["get"])
        self.assertEqual(raw, "")

    def test_reference_only_never_reads_or_changes_existing_secret(self):
        self.config["aiPlatform"]["agentRuntime"]["checkpointSecrets"][0]["create"] = False
        result, events, raw = self.run_installer(url=None, failure="get")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((events, raw), ([], ""))

    def test_conflicting_existing_secret_is_not_overwritten(self):
        result, events, raw = self.run_installer(existing={"type": "Opaque", "data": {"PG_PASSWORD": "other"}})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((events, raw), (["get"], ""))

    def test_existing_secret_cannot_add_connection_overrides_or_invalid_ssl_modes(self):
        _, _, raw = self.run_installer()
        valid = json.loads(raw)
        for key, value in (("PGHOSTADDR", "203.0.113.1"), ("PGSERVICE", "other"), ("PG_SSLMODE", "invalid")):
            secret = json.loads(json.dumps(valid))
            secret["data"][key] = base64.b64encode(value.encode()).decode()
            result, events, raw = self.run_installer(existing=secret)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((events, raw), (["get"], ""))

    def test_missing_input_stops_before_platform_cleanup_or_apply(self):
        result, events, raw = self.run_installer(url=None, method="install_ai_platform_cr")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((events, raw), ([], ""))

    def test_invalid_url_never_reaches_kubectl(self):
        for url in ("postgresql://user:"+CANARY+"%bad@db/checkpoints", "postgresql://user:"+CANARY+"@db:0/checkpoints",
                    "postgresql://user:"+CANARY+"@db/checkpoints?password=other", "postgresql://user:"+CANARY+"@db/checkpoints?sslmode=disable&sslmode=require"):
            with self.subTest(url_kind=url.rsplit("@", 1)[-1]):
                result, events, raw = self.run_installer(url=url)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((events, raw), ([], ""))

    def test_api_failures_do_not_forward_secret_payloads(self):
        for failure in ("get", "create"):
            result, events, _ = self.run_installer(failure=failure)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(events, ["get"] if failure == "get" else ["get", "create"])

    def test_invalid_creation_declarations_and_plaintext_overrides(self):
        entry = self.config["aiPlatform"]["agentRuntime"]["checkpointSecrets"][0]
        for key, value in (("name", "unreferenced"), ("create", "false"), ("databaseUrlEnv", "bad-env-name")):
            old = entry[key]
            entry[key] = value
            result, events, raw = self.run_installer()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((events, raw), ([], ""))
            entry[key] = old
        self.config["aiPlatform"]["features"][0]["env"] = {"PG_PASSWORD": CANARY}
        result, events, _ = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, [])

    def test_deployment_profiles_enable_creation_without_credentials(self):
        for profile in ("cpuonly", "fullfeature"):
            result = subprocess.run(["yq", "-o=json", ".aiPlatform", str(ROOT / "examples" / ("profile-"+profile+".yaml"))],
                                    text=True, capture_output=True, check=True)
            self.config = {"aiPlatform": json.loads(result.stdout)}
            self.config["aiPlatform"]["agentRuntime"]["checkpointSecrets"][0]["databaseUrlEnv"] = "TEST_CHECKPOINT_URL"
            result, events, _ = self.run_installer()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events, ["get", "create"])


if __name__ == "__main__":
    unittest.main()
