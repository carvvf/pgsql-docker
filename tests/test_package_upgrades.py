"""Exercise the pending Ubuntu package upgrade check without Docker or a network."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
LIBRARY = REPO_ROOT / "tools" / "lib" / "package_upgrades.sh"

UPGRADE = (
    "Inst tzdata [2026e-0ubuntu0.24.04.1] (2026f-0ubuntu0.24.04.1 "
    "Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [all])"
)
SIMULATION = f"""Reading package lists...
Building dependency tree...
Calculating upgrade...
The following packages will be upgraded:
  tzdata
1 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
{UPGRADE}
Conf tzdata (2026f-0ubuntu0.24.04.1 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [all])
"""
NOTHING = """Reading package lists...
Building dependency tree...
Calculating upgrade...
0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
"""

# Stands in for `docker run`: records its arguments, prints DOCKER_OUTPUT and exits with
# DOCKER_STATUS.
DOCKER_STUB = """#!/usr/bin/env bash
printf '%s\\n' "$@" > "${DOCKER_ARGS}"
printf '%s' "${DOCKER_OUTPUT}"
exit "${DOCKER_STATUS:-0}"
"""


def run_library(function, stdin="", docker_output="", docker_status=0):
    with tempfile.TemporaryDirectory() as directory:
        stub = Path(directory) / "docker"
        stub.write_text(DOCKER_STUB)
        stub.chmod(0o755)
        args_file = Path(directory) / "docker-args"
        env = dict(os.environ, DOCKER_OUTPUT=docker_output, DOCKER_STATUS=str(docker_status), DOCKER_ARGS=str(args_file))
        env["PATH"] = directory + os.pathsep + env["PATH"]
        result = subprocess.run(
            ["bash", "-c", f'set -euo pipefail; source "{LIBRARY}"; {function}'],
            input=stdin,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        result.docker_args = args_file.read_text().splitlines() if args_file.exists() else []
        return result


class PendingPackageUpgradesTest(unittest.TestCase):
    def test_upgrade_is_listed_with_both_versions(self):
        result = run_library("pending_package_upgrades image", docker_output=SIMULATION)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "tzdata 2026e-0ubuntu0.24.04.1 -> 2026f-0ubuntu0.24.04.1\n")

    def test_index_update_goes_through_the_retry_helper(self):
        result = run_library("pending_package_upgrades image", docker_output=NOTHING)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"{REPO_ROOT / 'build' / 'retry.sh'}:/mnt/retry.sh:ro", result.docker_args)
        self.assertIn("sh /mnt/retry.sh apt-get update -qq --error-on=any >/dev/null && apt-get -s upgrade", result.docker_args)

    def test_no_upgrade_prints_nothing(self):
        result = run_library("pending_package_upgrades image", docker_output=NOTHING)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_apt_failure_is_an_error(self):
        result = run_library(
            "pending_package_upgrades image",
            docker_output="E: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/noble/InRelease",
            docker_status=100,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot simulate the apt upgrade of image", result.stderr)

    def test_unexpected_inst_line_is_an_error(self):
        result = run_library("pending_package_upgrades image", docker_output="Inst something new\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected apt simulation line", result.stderr)


class DescribePackageUpgradesTest(unittest.TestCase):
    def test_no_upgrade_prints_nothing(self):
        self.assertEqual(run_library("describe_package_upgrades", stdin="").stdout, "")

    def test_lists_the_first_five_and_counts_the_rest(self):
        lines = "".join(f"p{n} 1.{n} -> 1.{n}.1\n" for n in range(7))
        result = run_library("describe_package_upgrades", stdin=lines)
        self.assertEqual(
            result.stdout,
            "7 Ubuntu package upgrades: p0 1.0 -> 1.0.1, p1 1.1 -> 1.1.1, p2 1.2 -> 1.2.1, "
            "p3 1.3 -> 1.3.1, p4 1.4 -> 1.4.1, and 2 more\n",
        )


if __name__ == "__main__":
    unittest.main()
