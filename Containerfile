FROM quay.io/centos/centos:stream9

RUN dnf install -y epel-release dnf-plugins-core \
    && dnf config-manager --set-enabled crb \
    && dnf install -y \
        cpio \
        findutils \
        git \
        mock \
        openssh-clients \
        python3-pip \
        python3-rpm \
        rpm-build \
        rpmdevtools \
        rpmlint \
        tar \
        xz \
        yq \
        zstd \
    && dnf clean all \
    && rm -rf /var/cache/dnf \
    && python3 -m pip install --no-cache-dir rpkg==1.70

WORKDIR /workspace
