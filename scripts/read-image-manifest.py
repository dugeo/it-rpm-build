#!/usr/bin/env python3
"""Validate the intentionally small image-manifest YAML subset.

The runner uses this before any container image is available, so keep the
parser dependency-free. Manifests contain scalar top-level keys and one level
of scalar mappings under image, ansible, target, and publish.
"""
import pathlib
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: read-image-manifest.py images/file.yaml")

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
    elif indent >= 2 and section in {"image", "ansible", "target", "publish"}:
        values[f"{section}.{key}"] = (value or "").strip("'\"")
    else:
        raise SystemExit(f"unexpected indentation: {path}:{line}")

required = {
    "image.name",
    "image.kernel_version",
    "ansible.repo",
    "ansible.ref",
    "ansible.playbook",
    "target.host",
}
missing = sorted(required - values.keys())
if missing:
    raise SystemExit(f"missing required keys: {', '.join(missing)}")

image_name = values["image.name"]
if not re.fullmatch(r"[A-Za-z0-9._-]+", image_name):
    raise SystemExit("image.name must contain only letters, numbers, '.', '_' or '-'")

ansible_repo = values["ansible.repo"]
if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", ansible_repo):
    raise SystemExit("ansible.repo must be in owner/repo form, e.g. dugeo/ansible")

ansible_ref = values["ansible.ref"]
if not re.fullmatch(r"[A-Za-z0-9._/-]+", ansible_ref):
    raise SystemExit("ansible.ref must be a valid branch, tag, or commit SHA")

output = {
    "IMAGE_NAME": image_name,
    "KERNEL_VERSION": values["image.kernel_version"],
    "ANSIBLE_REPO": ansible_repo,
    "ANSIBLE_REF": ansible_ref,
    "ANSIBLE_PLAYBOOK": values["ansible.playbook"],
    "TARGET_HOST": values["target.host"],
    "TARGET_REMOTE_USER": values.get("target.remote_user", ""),
    "NEXUS_REPOSITORY": values.get("publish.nexus_repository", ""),
}
for key, value in output.items():
    print(f"{key}={value}")
