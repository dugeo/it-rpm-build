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
.github/workflows/        Build workflow (to be connected to k8s-runners)
```

## Required CI secrets

Configure these in the `rpm-build` GitHub repository:

```text
CGIT_SSH_PRIVATE_KEY
CGIT_KNOWN_HOSTS
NEXUS_USERNAME
NEXUS_PASSWORD
```

The workflow must use the existing `k8s-runners` ARC label. It must not require
Kubernetes administrator credentials.

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

Generated build files should not be committed back to this repository by CI.
