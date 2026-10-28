FROM quay.io/centos/centos:stream9

RUN dnf install -y epel-release dnf-plugins-core \
    && dnf config-manager --set-enabled crb \
    && dnf install -y \
        cpio \
        coreutils \
        curl \
        findutils \
        git \
        mock \
        openssh-clients \
        rpm-build \
        rpmdevtools \
        rpmlint \
        rpkg \
        tar \
        xz \
        yq \
        zstd \
    && dnf clean all \
    && rm -rf /var/cache/dnf

WORKDIR /workspace
