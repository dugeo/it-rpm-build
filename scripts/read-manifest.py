#!/usr/bin/env python3
"""Validate the intentionally small package-manifest YAML subset.

The runner uses this before any container image is available, so keep the
parser dependency-free. Manifests contain scalar top-level keys and one level
of scalar mappings under source, build, and publish.
"""
import pathlib
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: read-manifest.py packages/file.yaml")

path = pathlib.Path(sys.argv[1])
values = {}
section = None
for raw in path.read_text().splitlines():
    line = raw.rstrip()
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    match = re.match(r"^( *)([A-Za-z][A-Za-z0-9_-]*):(?:\s*(.*))?$", line)
    if not match:
        raise SystemExit(f"unsupported manifest syntax: {path}:{line}")
    indent, key, value = len(match.group(1)), match.group(2), match.group(3)
    if indent == 0:
        section = key if value in (None, "") else None
        if value not in (None, ""):
            values[key] = value.strip("'\"")
    elif indent >= 2 and section in {"source", "build", "publish"}:
        values[f"{section}.{key}"] = (value or "").strip("'\"")
    else:
        raise SystemExit(f"unexpected indentation: {path}:{line}")

required = {"package", "source.url", "source.sha256", "build.template", "publish.nexus_repository"}
missing = sorted(required - values.keys())
if missing:
    raise SystemExit(f"missing required keys: {', '.join(missing)}")

package = values["package"]
repository = values.get("repository", package)
digest = values["source.sha256"]
for name, value in (("package", package), ("repository", repository)):
    if not re.fullmatch(r"[A-Za-z0-9._-]+", value):
        raise SystemExit(f"{name} must contain only letters, numbers, '.', '_' or '-'")
if not re.fullmatch(r"[A-Fa-f0-9]{64}", digest):
    raise SystemExit("source.sha256 must be a 64-character hexadecimal SHA-256 digest")

output = {
    "PACKAGE": package,
    "REPOSITORY": repository,
    "SRPM_URL": values["source.url"],
    "SRPM_SHA256": digest.lower(),
    "BUILD_TEMPLATE": values["build.template"],
    "MOCK_CONFIG": values.get("build.mock_config", "mock.cfg"),
    "BUILD_SCRIPT": values.get("build.script", "build.sh"),
    "KERNEL_VERSION": values.get("build.kernel", ""),
    "RPM_REPOSITORY_URL": values.get("build.rpm_repository_url", "https://nexus.dug.com/repository/dug-el/9/dug/x86_64/"),
    "NEXUS_REPOSITORY": values["publish.nexus_repository"],
}
for key, value in output.items():
    print(f"{key}={value}")
