FROM quay.io/centos/centos:stream9

RUN set -eux; \
    install_retry() { \
      for attempt in 1 2 3 4 5; do \
        dnf clean all; \
        if dnf install -y --refresh --setopt=retries=10 --setopt=timeout=60 --setopt=ip_resolve=4 "$@"; then \
          return 0; \
        fi; \
        sleep $((attempt * 5)); \
      done; \
      return 1; \
    }; \
    install_retry epel-release dnf-plugins-core; \
    dnf config-manager --set-enabled crb; \
    sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/centos.repo; \
    printf '%s\n' \
      '[fixed-baseos]' \
      'name=CentOS Stream 9 BaseOS' \
      'baseurl=https://mirror.stream.centos.org/9-stream/BaseOS/$basearch/os/' \
      'enabled=1' 'gpgcheck=1' \
      'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial' \
      '[fixed-appstream]' \
      'name=CentOS Stream 9 AppStream' \
      'baseurl=https://mirror.stream.centos.org/9-stream/AppStream/$basearch/os/' \
      'enabled=1' 'gpgcheck=1' \
      'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial' \
      '[fixed-crb]' \
      'name=CentOS Stream 9 CRB' \
      'baseurl=https://mirror.stream.centos.org/9-stream/CRB/$basearch/os/' \
      'enabled=1' 'gpgcheck=1' \
      'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial' \
      > /etc/yum.repos.d/centos-fixed.repo; \
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
        yq \
        zstd; \
    dnf clean all; \
    rm -rf /var/cache/dnf; \
    python3 -m pip install --no-cache-dir --timeout 60 --retries 10 --only-binary=:all: --no-deps requests-gssapi==1.4.0; \
    python3 -m pip install --no-cache-dir --timeout 60 --retries 10 rpkg==1.70

WORKDIR /workspace
