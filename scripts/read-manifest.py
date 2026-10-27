#!/usr/bin/env python3
import hashlib
import json
import pathlib
import re
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"PyYAML is required: {exc}")

if len(sys.argv) != 2:
    raise SystemExit("usage: read-manifest.py packages/file.yaml")

path = pathlib.Path(sys.argv[1])
data = yaml.safe_load(path.read_text())
if not isinstance(data, dict):
    raise SystemExit("manifest must be a YAML mapping")

required = ("package", "source", "build", "publish")
missing = [key for key in required if key not in data]
if missing:
    raise SystemExit(f"missing required keys: {', '.join(missing)}")

package = data["package"]
repository = data.get("repository", package)
source = data["source"]
if not isinstance(package, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", package):
    raise SystemExit("package must contain only letters, numbers, '.', '_' or '-'")
if not isinstance(repository, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", repository):
    raise SystemExit("repository must contain only letters, numbers, '.', '_' or '-'")
if not isinstance(source, dict) or not isinstance(source.get("url"), str):
    raise SystemExit("source.url is required")
digest = source.get("sha256", "")
if not isinstance(digest, str) or not re.fullmatch(r"[A-Fa-f0-9]{64}", digest):
    raise SystemExit("source.sha256 must be a 64-character hexadecimal SHA-256 digest")

build = data["build"]
publish = data["publish"]
if not isinstance(build, dict) or not isinstance(build.get("template"), str):
    raise SystemExit("build.template is required")
if not isinstance(publish, dict) or not isinstance(publish.get("nexus_repository"), str):
    raise SystemExit("publish.nexus_repository is required")

values = {
    "PACKAGE": package,
    "REPOSITORY": repository,
    "SRPM_URL": source["url"],
    "SRPM_SHA256": digest.lower(),
    "BUILD_TEMPLATE": build["template"],
    "MOCK_CONFIG": build.get("mock_config", "mock.cfg"),
    "BUILD_SCRIPT": build.get("script", "build.sh"),
    "NEXUS_REPOSITORY": publish["nexus_repository"],
}
for key, value in values.items():
    print(f"{key}={value}")
