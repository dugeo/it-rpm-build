FROM quay.io/centos/centos:stream9

ARG RPM_REPOSITORY_URL

RUN --mount=type=secret,id=legacy_nexus_username --mount=type=secret,id=legacy_nexus_password \
    set -eux; \
    test -n "$RPM_REPOSITORY_URL"; \
    printf '[legacy]\nname=legacy\nbaseurl=%s\nenabled=1\ngpgcheck=0\n' "$RPM_REPOSITORY_URL" > /etc/yum.repos.d/legacy.repo; \
    printf 'username=%s\npassword=%s\n' "$(cat /run/secrets/legacy_nexus_username)" "$(cat /run/secrets/legacy_nexus_password)" >> /etc/yum.repos.d/legacy.repo; \
    install_retry() { \
      for attempt in 1 2 3 4 5; do \
        dnf clean all; \
        if dnf --disablerepo='*' --enablerepo=legacy install -y --refresh --setopt=retries=10 --setopt=timeout=60 "$@"; then \
          return 0; \
        fi; \
        sleep $((attempt * 5)); \
      done; \
      return 1; \
    }; \
    install_retry \
        cpio \
        findutils \
        gcc \
        git \
        krb5-devel \
        mock \
        openssh-clients \
        python3-pip \
        python3-rpm \
        python3-gssapi \
        python3-devel \
        rpm-build \
        rpmdevtools \
        rpmlint \
        tar \
        xz \
        zstd; \
    rm -f /etc/yum.repos.d/legacy.repo; \
    dnf clean all; \
    rm -rf /var/cache/dnf; \
    python3 -m pip install --no-cache-dir --timeout 60 --retries 10 --only-binary=:all: --no-deps requests-gssapi==1.4.0; \
    python3 -m pip install --no-cache-dir --timeout 60 --retries 10 rpkg==1.70

WORKDIR /workspace
