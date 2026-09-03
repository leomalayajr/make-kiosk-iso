FROM archlinux:latest

LABEL description="archiso build environment for the Offline Kiosk offline installer"

# arch-install-scripts supplies pacstrap, genfstab, and arch-chroot for both
# assembling the target archive and validating the finished ISO.
RUN pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
      archiso arch-install-scripts squashfs-tools dosfstools libisoburn \
      mtools gptfdisk e2fsprogs zstd file libarchive && \
    # Keep synchronized repository databases: pacstrap and mkarchiso resolve
    # the target/live package lists from this builder image. -Sc clears only
    # unneeded package archives without discarding those databases.
    pacman -Sc --noconfirm

COPY build-inside.sh /build-inside.sh
RUN chmod 0755 /build-inside.sh

ENTRYPOINT ["/build-inside.sh"]
