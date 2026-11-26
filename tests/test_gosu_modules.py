"""Check that build/gosu-modules records every module upgrade with its checksums.

The gosu build upgrades the direct requirements of build/gosu-modules/go.mod and trusts
the checksums of its go.sum. Without both checksums of a required version, the build
would fetch them from the checksum database at build time instead, and the repository
would no longer record them; this test turns that into a failure. No network is needed.
"""

import re
import unittest
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / "build" / "gosu-modules"


def direct_requirements():
    requirements, block = {}, False
    for line in (MODULE / "go.mod").read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("require ("):
            block = True
        elif block and stripped == ")":
            block = False
        elif "// indirect" not in stripped:
            match = re.fullmatch(r"(?:require\s+)?(\S+)\s+(v\S+)", stripped) if (block or stripped.startswith("require ")) else None
            if match:
                requirements[match.group(1)] = match.group(2)
    return requirements


class GosuModulesTest(unittest.TestCase):
    def test_upgrades_are_declared(self):
        self.assertTrue(direct_requirements(), "build/gosu-modules/go.mod requires no module")

    def test_go_sum_records_both_checksums_of_every_requirement(self):
        sums = (MODULE / "go.sum").read_text(encoding="utf-8").splitlines()
        for module, version in direct_requirements().items():
            for suffix in ("", "/go.mod"):
                with self.subTest(module=module, version=version + suffix):
                    self.assertTrue(
                        any(re.fullmatch(rf"{re.escape(module)} {re.escape(version + suffix)} h1:\S+=", line) for line in sums),
                        f"go.sum lacks the {version + suffix} checksum of {module}",
                    )

    def test_every_requirement_is_imported(self):
        # go mod tidy, which Renovate runs, drops a requirement nothing imports.
        imports = re.findall(r'^\s*_ "([^"]+)"$', (MODULE / "modules.go").read_text(encoding="utf-8"), re.MULTILINE)
        for module in direct_requirements():
            with self.subTest(module=module):
                self.assertTrue(any(path == module or path.startswith(module + "/") for path in imports))

    def test_dockerfile_takes_the_versions_from_go_mod(self):
        dockerfile = (MODULE.parents[1] / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("build/gosu-modules/go.mod", dockerfile)
        for module in direct_requirements():
            with self.subTest(module=module):
                self.assertNotIn(module + "@", dockerfile)


if __name__ == "__main__":
    unittest.main()
