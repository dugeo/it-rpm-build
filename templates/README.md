# Build templates

Each template is selected by a package manifest and must document its contract.
A template may provide `build.sh`, `build.yml`, and `mock.cfg`. Package-specific
source files belong in the cgit dist-git repository after import, not here.

The initial `el9` directory is reserved for the CentOS Stream/RHEL 9-compatible
mock configuration and will be populated after the package build contract is
confirmed against the existing `rpkg`/`mock` process.
