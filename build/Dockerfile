# =========================================================================
# NAS_CRUCIBLE live image 建置環境
#   宿主只需要 docker 與 git。debootstrap / xorriso / mksquashfs 這些工具
#   只存在於這個容器裡，不污染開發機。
# =========================================================================
FROM debian:stable

RUN apt-get update && apt-get install -y --no-install-recommends \
        debootstrap \
        squashfs-tools \
        xorriso \
        mtools \
        dosfstools \
        jq \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY in_container/ /build/
COPY rootfs/ /build/rootfs/
COPY boot/ /build/boot/
RUN chmod +x /build/build.sh

ENTRYPOINT ["/build/build.sh"]
