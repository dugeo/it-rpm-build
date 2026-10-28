FROM quay.io/centos/centos:stream9

RUN dnf install -y epel-release dnf-plugins-core \
    && dnf config-manager --set-enabled crb \
    && dnf install -y \
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
        zstd \
    && dnf clean all \
    && rm -rf /var/cache/dnf \
    && python3 -m pip install --no-cache-dir --timeout 60 --retries 10 --only-binary=:all: --no-deps requests-gssapi==1.4.0 \
    && python3 -m pip install --no-cache-dir --timeout 60 --retries 10 rpkg==1.70

WORKDIR /workspace
