# CI Vulnerability Publication Policy

> Written with AI assistance. Verify operational details against the workflow source.

All image variants apply the same policy to HIGH/CRITICAL OS and library
vulnerabilities. Scan execution, report validation, tests, runtime checks, and
publication failures remain errors.

| Final scan evidence | Publication | Workflow result |
| --- | --- | --- |
| No HIGH/CRITICAL findings | Allowed | Success without a vulnerability warning |
| Findings with no fixed version listed by Trivy | Allowed | Success with explanatory GitHub warning annotations |
| Any finding with a fixed version listed by Trivy | Blocked | Failure |
| Missing, malformed, or empty scan evidence | Blocked | Failure |

A nonempty `FixedVersion` is blocking even when a dependency pin, compatibility
constraint, or release-line policy prevents adopting it automatically. A missing
fixed version means the scanner does not list a fix; it does not mean the finding
is harmless or that no upstream fix can ever exist.

`scripts/trivy/report_policy.py` owns report validation, classification, summary
rendering, annotations, and the exit status. It uses system Python 3's standard
library and needs no application virtual environment or additional dependencies.
The scanner writes complete JSON reports; the evaluator decides the gate from
those reports. Scanner execution failures still stop the workflow before the
evaluator can authorize publication. An initial scan uses `--observe` to validate
evidence without warning before remediation. Candidate and final scans apply the
gate. All supplied architectures and active tags must pass.

The workflows retain the candidate and final reports as artifacts, including on
failure, under their configured retention. Warning details identify the target,
CVE, package and installed version. They also appear in the job summary. A clean
rebuild does not intentionally fail to notify operators. Normal branch and
publication restrictions still apply.

The image that passed the gate is the image published; the policy does not add
a rebuild between scanning and publication. Manual publication entrypoints use
the same gate. Local developer vulnerability scanners keep their existing scope
and exit policy; this document defines GitHub CI publication behavior.

Run the offline decision tests from the repository root with system Python:

```bash
python3 -m unittest scripts.trivy.test_report_policy
```

The cases cover clean scans, residual findings without a fix, fixable and mixed
findings, multiple architectures, initial scans, invalid or missing evidence,
and safe warning annotations. No image build or vulnerability database is needed.
