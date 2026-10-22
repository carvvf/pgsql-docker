"""Exercise build provenance and major-version guards without Docker or a network."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
POSTGRES_DIGEST = "sha256:" + "a" * 64
UBUNTU_DIGEST = "sha256:" + "b" * 64
SOURCE_COMMIT = "c" * 40
GOSU_COMMIT = "d" * 40
ENTRYPOINT_COMMIT = "e" * 40
GO_SHA256 = "1" * 64
GO_PREVIOUS_SHA256 = "2" * 64


def go_release(version, sha256, stable=True):
    return {
        "version": "go" + version,
        "stable": stable,
        "files": [
            {"os": "", "arch": "", "kind": "source", "sha256": "9" * 64},
            {"os": "linux", "arch": "arm64", "kind": "archive", "sha256": "8" * 64},
            {"os": "linux", "arch": "amd64", "kind": "installer", "sha256": "7" * 64},
            {"os": "linux", "arch": "amd64", "kind": "archive", "sha256": sha256},
        ],
    }


# Unordered on purpose: 1.27.10 must win over 1.27.9 numerically, while newer
# minors and unstable releases are never selected.
GO_RELEASES = [
    go_release("1.28.0", "3" * 64),
    go_release("1.27.9", GO_PREVIOUS_SHA256),
    go_release("1.27.11", "4" * 64, stable=False),
    go_release("1.27.10", GO_SHA256),
    go_release("1.27rc1", "5" * 64, stable=False),
]
INPUT_NAMES = (
    "POSTGRES_UPSTREAM_REF",
    "POSTGRES_UPSTREAM_VERSION",
    "POSTGRES_UPSTREAM_DIGEST",
    "POSTGRES_SOURCE_REF",
    "POSTGRES_SOURCE_REVISION",
    "GOSU_SOURCE_REF",
    "GOSU_SOURCE_REVISION",
    "GO_TOOLCHAIN_VERSION",
    "GO_TOOLCHAIN_SHA256",
    "ENTRYPOINT_SOURCE_COMMIT",
    "UBUNTU_BASE_IMAGE",
    "UBUNTU_BASE_DIGEST",
    "PG_MAJOR",
    "IMAGE_REF",
)

TOOL_STUB = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

state = json.loads(os.environ["BUILD_INPUT_TEST_STATE"])
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["BUILD_INPUT_TEST_CALLS"], "a", encoding="utf-8") as log:
    log.write(json.dumps([tool, *args]) + "\n")
if tool == "curl":
    if state.get("curl_status"):
        sys.exit(state["curl_status"])
    print(json.dumps(state["go_releases"]))
elif tool == "git":
    repository = next(arg for arg in args if arg.startswith("https://"))
    if repository == "https://github.com/docker-library/postgres.git":
        print(state["entrypoint_commit"] + "\trefs/heads/master")
    else:
        key = "postgres" if repository == "https://github.com/postgres/postgres.git" else "gosu"
        if state.get("missing_tag") == key:
            sys.exit(2)
        tag = "REL_18_6" if key == "postgres" else "1.19"
        commit = state[key + "_commit"]
        if state["annotated"]:
            print("f" * 40 + "\trefs/tags/" + tag)
            print(commit + "\trefs/tags/" + tag + "^{}")
        else:
            print(commit + "\trefs/tags/" + tag)
elif args[0] == "pull":
    sys.exit(state.get("pull_status", 0))
elif args[:2] == ["image", "inspect"]:
    is_postgres = args[2].startswith("postgres")
    if "RepoDigests" in args[-1]:
        repo = "postgres" if is_postgres else "ubuntu"
        digest = state["postgres_digest"] if is_postgres else state["ubuntu_digest"]
        print(repo + "@" + digest)
    elif is_postgres:
        print("PG_VERSION=" + state["version"] + "-1.pgdg12+2")
        print("PG_MAJOR=" + state["major"])
        print("GOSU_VERSION=" + state["gosu_version"])
    else:
        print(state["ubuntu_version"])
elif args[0] != "build":
    sys.exit("Unexpected tool invocation: " + repr(args))
'''


class BuildInputTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir(mode=0o775)
        for name in ("docker", "git", "curl"):
            tool = self.bin_dir / name
            tool.write_text(TOOL_STUB, encoding="utf-8")
            tool.chmod(0o775)
        self.calls_path = self.root / "calls.jsonl"
        self.state = {
            "version": "18.6",
            "major": "18",
            "gosu_version": "1.19",
            "ubuntu_version": "24.04",
            "postgres_digest": POSTGRES_DIGEST,
            "ubuntu_digest": UBUNTU_DIGEST,
            "postgres_commit": SOURCE_COMMIT,
            "gosu_commit": GOSU_COMMIT,
            "entrypoint_commit": ENTRYPOINT_COMMIT,
            "annotated": True,
            "go_releases": GO_RELEASES,
        }

    def invoke(self, entrypoint="resolve_build_inputs.sh", **inputs):
        env = {key: value for key, value in os.environ.items() if key not in INPUT_NAMES}
        env.update(inputs)
        env["PATH"] = str(self.bin_dir) + os.pathsep + env["PATH"]
        env["BUILD_INPUT_TEST_STATE"] = json.dumps(self.state)
        env["BUILD_INPUT_TEST_CALLS"] = str(self.calls_path)
        return subprocess.run(
            ["/bin/bash", str(REPO_ROOT / "tools" / entrypoint)],
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def calls(self):
        if not self.calls_path.exists():
            return []
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()]

    def assert_no_build(self):
        self.assertFalse(any(call[:2] == ["docker", "build"] for call in self.calls()))

    def test_major_pinned_signal_resolves_all_immutable_inputs(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            dict(line.split("=", 1) for line in result.stdout.splitlines()),
            {
                "upstream_ref": "postgres@" + POSTGRES_DIGEST,
                "upstream_version": "18.6",
                "upstream_digest": POSTGRES_DIGEST,
                "source_ref": "REL_18_6",
                "source_revision": SOURCE_COMMIT,
                "gosu_source_ref": "1.19",
                "gosu_source_revision": GOSU_COMMIT,
                "go_toolchain_version": "1.27.10",
                "go_toolchain_sha256": GO_SHA256,
                "entrypoint_source_commit": ENTRYPOINT_COMMIT,
                "ubuntu_base_ref": "ubuntu@" + UBUNTU_DIGEST,
                "ubuntu_base_digest": UBUNTU_DIGEST,
            },
        )
        self.assertIn(["docker", "pull", "--platform", "linux/amd64", "postgres:18"], self.calls())

    def test_lightweight_tags_resolve_commits(self):
        self.state["annotated"] = False
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("source_revision=" + SOURCE_COMMIT, result.stdout)
        self.assertIn("gosu_source_revision=" + GOSU_COMMIT, result.stdout)

    def test_pinned_ci_inputs_preserve_entrypoint_and_release_signal(self):
        self.state["entrypoint_commit"] = "f" * 40
        result = self.invoke(
            POSTGRES_UPSTREAM_REF="postgres@" + POSTGRES_DIGEST,
            POSTGRES_UPSTREAM_VERSION="18.6",
            POSTGRES_UPSTREAM_DIGEST=POSTGRES_DIGEST,
            POSTGRES_SOURCE_REF="REL_18_6",
            POSTGRES_SOURCE_REVISION=SOURCE_COMMIT,
            GOSU_SOURCE_REF="1.19",
            GOSU_SOURCE_REVISION=GOSU_COMMIT,
            GO_TOOLCHAIN_VERSION="1.27.9",
            GO_TOOLCHAIN_SHA256=GO_PREVIOUS_SHA256,
            ENTRYPOINT_SOURCE_COMMIT=ENTRYPOINT_COMMIT,
            UBUNTU_BASE_IMAGE="ubuntu@" + UBUNTU_DIGEST,
            UBUNTU_BASE_DIGEST=UBUNTU_DIGEST,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("entrypoint_source_commit=" + ENTRYPOINT_COMMIT, result.stdout)
        self.assertIn("go_toolchain_version=1.27.9", result.stdout)
        self.assertIn("go_toolchain_sha256=" + GO_PREVIOUS_SHA256, result.stdout)
        self.assertFalse(any("refs/heads/master" in call for call in self.calls()))
        self.assertFalse(any("postgres:18" in call for call in self.calls()))

    def test_local_build_passes_provenance_and_explicit_major(self):
        result = self.invoke("build_local_image.sh", POSTGRES_SOURCE_REF="REL_18_6")
        self.assertEqual(result.returncode, 0, result.stderr)
        build = next(call for call in self.calls() if call[:2] == ["docker", "build"])
        for value in (
            "PG_MAJOR=18",
            "POSTGRES_SOURCE_REF=REL_18_6",
            "POSTGRES_SOURCE_REVISION=" + SOURCE_COMMIT,
            "POSTGRES_UPSTREAM_VERSION=18.6",
            "POSTGRES_UPSTREAM_DIGEST=" + POSTGRES_DIGEST,
            "POSTGRES_IMAGE_VERSION=18.6-local",
            "GOSU_SOURCE_REF=1.19",
            "GOSU_SOURCE_REVISION=" + GOSU_COMMIT,
            "GO_TOOLCHAIN_VERSION=1.27.10",
            "GO_TOOLCHAIN_SHA256=" + GO_SHA256,
            "ENTRYPOINT_SOURCE_COMMIT=" + ENTRYPOINT_COMMIT,
            "UBUNTU_BASE_IMAGE=ubuntu@" + UBUNTU_DIGEST,
            "UBUNTU_BASE_DIGEST=" + UBUNTU_DIGEST,
        ):
            self.assertIn(value, build)
        self.assertIn("--no-cache", build)
        self.assertIn("linux/amd64", build)
        self.assertEqual(build[-3:], ["-t", "pgsql-custom:local", str(REPO_ROOT)])
        self.assertIn(["docker", "pull", "--platform", "linux/amd64", "postgres:18.6"], self.calls())

    def test_major_upgrade_and_unpinned_latest_are_rejected(self):
        for inputs in (
            {"PG_MAJOR": "19"},
            {"POSTGRES_SOURCE_REF": "REL_19_0"},
            {"POSTGRES_UPSTREAM_VERSION": "19.0"},
            {"POSTGRES_UPSTREAM_REF": "postgres:latest"},
            {"POSTGRES_UPSTREAM_REF": "postgres:19"},
        ):
            with self.subTest(inputs=inputs):
                result = self.invoke("build_local_image.sh", **inputs)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Build input error:", result.stderr)
        self.assert_no_build()

    def test_digest_pinned_image_from_wrong_major_is_rejected(self):
        self.state["major"] = "19"
        self.state["version"] = "19.0"
        result = self.invoke("build_local_image.sh", POSTGRES_UPSTREAM_REF="postgres@" + POSTGRES_DIGEST)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must contain PostgreSQL major 18", result.stderr)
        self.assert_no_build()

    def test_mismatched_inputs_abort_before_build(self):
        for inputs in (
            {"POSTGRES_UPSTREAM_VERSION": "18.5"},
            {"POSTGRES_SOURCE_REVISION": "f" * 40},
            {"GOSU_SOURCE_REVISION": "f" * 40},
            {"POSTGRES_UPSTREAM_DIGEST": UBUNTU_DIGEST},
            {"UBUNTU_BASE_DIGEST": POSTGRES_DIGEST},
            {"POSTGRES_UPSTREAM_VERSION": "18.6", "POSTGRES_SOURCE_REF": "REL_18_5"},
            {"ENTRYPOINT_SOURCE_COMMIT": "invalid"},
            {"GO_TOOLCHAIN_VERSION": "1.28.0"},
            {"GO_TOOLCHAIN_VERSION": "1.27"},
            {"GO_TOOLCHAIN_VERSION": "1.27.11"},
            {"GO_TOOLCHAIN_VERSION": "1.27.12"},
            {"GO_TOOLCHAIN_SHA256": "invalid"},
            {"GO_TOOLCHAIN_SHA256": GO_PREVIOUS_SHA256},
        ):
            with self.subTest(inputs=inputs):
                inputs = {"POSTGRES_UPSTREAM_REF": "postgres:18", "UBUNTU_BASE_IMAGE": "ubuntu:24.04", **inputs}
                result = self.invoke("build_local_image.sh", **inputs)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Build input error:", result.stderr)
        self.assert_no_build()

    def test_wrong_ubuntu_release_aborts_before_build(self):
        self.state["ubuntu_version"] = "22.04"
        result = self.invoke("build_local_image.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ubuntu 24.04 is required", result.stderr)
        self.assert_no_build()

    def test_missing_source_tags_abort_before_build(self):
        for source in ("postgres", "gosu"):
            with self.subTest(source=source):
                self.state["missing_tag"] = source
                result = self.invoke("build_local_image.sh")
                self.assertNotEqual(result.returncode, 0)
        self.assert_no_build()

    def test_missing_go_series_aborts_before_build(self):
        self.state["go_releases"] = [go_release("1.28.0", "3" * 64), go_release("1.27.11", "4" * 64, stable=False)]
        result = self.invoke("build_local_image.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No stable Go 1.27.x release", result.stderr)
        self.assert_no_build()

    def test_go_release_index_failure_aborts_before_build(self):
        self.state["curl_status"] = 22
        result = self.invoke("build_local_image.sh")
        self.assertEqual(result.returncode, 22)
        self.assert_no_build()

    def test_pull_failure_aborts_before_build(self):
        self.state["pull_status"] = 42
        result = self.invoke("build_local_image.sh")
        self.assertEqual(result.returncode, 42)
        self.assert_no_build()


if __name__ == "__main__":
    unittest.main()
