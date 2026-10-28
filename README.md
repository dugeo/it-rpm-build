# RPM Build Control Repository

This repository is the source of truth for repeatable SRPM imports, mock builds,
and Nexus publication. It is intentionally separate from `dugeo/it-k8s`:

- this repository contains package manifests and build templates;
- `dugeo/it-k8s` contains cluster/GitOps configuration;
- cgit contains generated dist-git package repositories;
- Nexus contains SRPM/RPM artifacts.

## Add a package

Copy a manifest under `packages/`, set the immutable SRPM URL and SHA-256,
choose a build template, and open a pull request. A merged manifest change
becomes the input to the RPM build workflow.

## Repository layout

```text
packages/                 Package manifests
schemas/                  Manifest validation schemas
templates/                Shared build and mock templates
Containerfile             Runner-side RPM tool image
.github/workflows/        Build workflow on `rpm-build-runners`
```

## Required CI secrets

Configure these in the `rpm-build` GitHub repository:

```text
CGIT_SSH_PRIVATE_KEY          key allowed to clone/push package repositories
CGIT_REPO_ADMIN_PRIVATE_KEY   restricted key allowed only to run newrepo
CGIT_KNOWN_HOSTS              pinned known_hosts entry for cgit.kube.dug.com
NEXUS_USERNAME
NEXUS_PASSWORD
```

The workflow uses the `rpm-build-runners` ARC label and performs the full
sequence without Kubernetes administrator credentials:

## Build contract

For every manifest the runner must:

1. validate the manifest and SHA-256 format;
2. create the cgit repository if it does not exist, or fail clearly if the
   restricted repository-admin key is not configured;
3. render the selected template into the cgit checkout;
4. download and verify the SRPM;
5. run `rpkg import`, commit, and push;
6. run `rpkg srpm` and `mock`;
7. verify RPM signatures/checksums;
8. upload RPMs and the SRPM to Nexus;
9. publish build logs and metadata as workflow artifacts.

The workflow stores the original verified SRPM under `SOURCES/` in the cgit
repository before committing the imported dist-git state. Nexus remains the
artifact publication destination for build outputs.
