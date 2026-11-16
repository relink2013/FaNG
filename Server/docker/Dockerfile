# The fang container: Samba 4.22.11 built with vfs_fang, and fang-api.
# Build from the repo root: docker build -f docker/Dockerfile .

FROM debian:trixie AS samba
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config python3 python3-dev perl flex bison libparse-yapp-perl \
        libgnutls28-dev libacl1-dev libattr1-dev zlib1g-dev libpopt-dev libbsd-dev libcap-dev \
        libtasn1-bin libtasn1-6-dev libicu-dev libtirpc-dev curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG SAMBA=samba-4.22.11
WORKDIR /build
RUN curl -fsSLO https://download.samba.org/pub/samba/stable/$SAMBA.tar.gz && tar -xzf $SAMBA.tar.gz
COPY samba/vfs_fang/vfs_fang.c /build/$SAMBA/source3/modules/
RUN cd $SAMBA && cat >> source3/modules/wscript_build <<'W'

bld.SAMBA3_MODULE('vfs_fang',
                 subsystem='vfs',
                 source='vfs_fang.c',
                 deps='samba-util',
                 init_function='',
                 internal_module=bld.SAMBA3_IS_STATIC_MODULE('vfs_fang'),
                 enabled=bld.SAMBA3_IS_ENABLED_MODULE('vfs_fang'))
W
RUN cd $SAMBA && ./configure --prefix=/opt/samba --without-ad-dc --without-ads --without-ldap \
        --without-pam --without-systemd --without-libarchive --disable-cups --disable-iprint \
        --without-json --without-winbind --without-quotas --without-gpgme --without-ldb-lmdb \
        --with-shared-modules='!vfs_snapper,vfs_fang' > /build/configure.log 2>&1 \
    || (tail -40 /build/configure.log; exit 1)
RUN cd $SAMBA && make -j"$(nproc)" > /build/make.log 2>&1 || (grep -B2 -A8 -i 'error' /build/make.log | tail -60; exit 1)
RUN cd $SAMBA && make install > /build/install.log 2>&1 && test -f /opt/samba/lib/vfs/fang.so

FROM swift:6.2-bookworm AS swift
WORKDIR /src
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --static-swift-stdlib \
    && cp .build/release/fang-api .build/release/fang-storaged /

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        tini libgnutls30t64 libacl1 libattr1 zlib1g libpopt0 libbsd0 libcap2 libtasn1-6 libicu76 \
        libtirpc3t64 libstdc++6 ca-certificates openssl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=samba /opt/samba /opt/samba
COPY --from=swift /fang-api /fang-storaged /usr/local/bin/
COPY docker/start.sh docker/fang-user /usr/local/bin/
# Fail the build, not the container, if a library is missing.
RUN ! (ldd /opt/samba/sbin/smbd /opt/samba/bin/smbpasswd /usr/local/bin/fang-api /usr/local/bin/fang-storaged | grep "not found")
ENV PATH=/opt/samba/bin:/opt/samba/sbin:$PATH
EXPOSE 445 443
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start.sh"]
