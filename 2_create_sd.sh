#!/usr/bin/env sh

set -e
set -x

. ./consts.sh

check_root_fs() {
    if [ ! -f "${ROOT_FS}" ]; then
        wget "${ROOT_FS_DL}"
    fi
}

check_sd_card_is_block_device() {
    _DEVICE=${1}

    if [ -z "${_DEVICE}" ] || [ ! -b "${_DEVICE}" ]; then
        echo "Error: '${_DEVICE}' is empty or not a block device"
        exit 1
    fi
}

check_required_file() {
    if [ ! -f "${1}" ]; then
        echo "Missing file: ${1}, did you compile everything first?"
        exit 1
    fi
}

check_required_folder() {
    if [ ! -d "${1}" ]; then
        echo "Missing directory: ${1}, did you compile everything first?"
        exit 1
    fi
}

probe_partition_separator() {
    _DEVICE=${1}

    [ -b "${_DEVICE}p1" ] && echo 'p' || echo ''
}

DEVICE=${1}

if [ "${USE_CHROOT}" != 0 ]; then
    # check_deps for arch-chroot on non RISC-V host
    for DEP in arch-install-scripts qemu-user-static qemu-user-static-binfmt btrfs-progs; do
        check_deps ${DEP}
    done
fi
check_sd_card_is_block_device "${DEVICE}"
check_root_fs
for FILE in 8723ds.ko u-boot-sunxi-with-spl.bin Image.gz Image; do
    check_required_file "${OUT_DIR}/${FILE}"
done
for DIR in modules; do
    check_required_folder "${OUT_DIR}/${DIR}"
done

# format disk
if [ -z "${CI_BUILD}" ]; then
    echo "Formatting ${DEVICE}, this will REMOVE EVERYTHING on it!"
    printf "Continue? (y/N): "
    read -r confirm && [ "${confirm}" = "y" ] || [ "${confirm}" = "Y" ] || exit 1
fi

# ${SUDO} mkinitcpio -H btrfs

${SUDO} dd if=/dev/zero of="${DEVICE}" bs=1M count=40
${SUDO} parted -s -a optimal -- "${DEVICE}" mklabel gpt
${SUDO} parted -s -a optimal -- "${DEVICE}" mkpart primary fat32 40MiB 1024MiB
${SUDO} parted -s -a optimal -- "${DEVICE}" mkpart primary btrfs 1064MiB 100%
${SUDO} partprobe "${DEVICE}"
PART_IDENTITYFIER=$(probe_partition_separator "${DEVICE}")
${SUDO} mkfs.ext2 -F -L boot "${DEVICE}${PART_IDENTITYFIER}1"
${SUDO} mkfs.btrfs -L root "${DEVICE}${PART_IDENTITYFIER}2"

# flash boot things
${SUDO} dd if="${OUT_DIR}/u-boot-sunxi-with-spl.bin" of="${DEVICE}" bs=1024 seek=128

# mount it
mkdir -p "${MNT}"

if [ "${USE_BTRFS_SUBVOLS}" = "1" ]; then
    # create subvolumes
    TMP_BTRFS_MNT=$(mktemp -d)
    ${SUDO} mount "${DEVICE}${PART_IDENTITYFIER}2" "${TMP_BTRFS_MNT}"
    for SUBVOL in ${BTRFS_SUBVOLS}; do
        ${SUDO} btrfs subvolume create "${TMP_BTRFS_MNT}/${SUBVOL}"
    done
    ${SUDO} umount "${TMP_BTRFS_MNT}"
    rmdir "${TMP_BTRFS_MNT}"

    # mount subvolumes
    ${SUDO} mount -o subvol=@ "${DEVICE}${PART_IDENTITYFIER}2" "${MNT}"
    for SUBVOL in ${BTRFS_SUBVOLS}; do
        [ "${SUBVOL}" = "@" ] && continue
        # convert @home -> home, @var -> var, @snapshots -> .snapshots (if it starts with @)
        MOUNT_POINT="${SUBVOL#@}"
        [ "${SUBVOL}" = "@snapshots" ] && MOUNT_POINT=".snapshots"
        ${SUDO} mkdir -p "${MNT}/${MOUNT_POINT}"
        ${SUDO} mount -o "subvol=${SUBVOL}" "${DEVICE}${PART_IDENTITYFIER}2" "${MNT}/${MOUNT_POINT}"
    done
else
    ${SUDO} mount "${DEVICE}${PART_IDENTITYFIER}2" "${MNT}"
fi

${SUDO} mkdir -p "${MNT}/boot"
${SUDO} mount "${DEVICE}${PART_IDENTITYFIER}1" "${MNT}/boot"

# extract rootfs
${SUDO} tar -xv --zstd -f "${ROOT_FS}" -C "${MNT}"

# install kernel and modules
# KERNEL_RELEASE=$(make ARCH="${ARCH}" -s kernelversion -C build/linux-build)
KERNEL_RELEASE=$(ls output/modules)
${SUDO} cp "${OUT_DIR}/Image.gz" "${OUT_DIR}/Image" "${MNT}/boot/"

${SUDO} mkdir -p "${MNT}/lib/modules"
${SUDO} cp -a "${OUT_DIR}/modules/${KERNEL_RELEASE}" "${MNT}/lib/modules"
${SUDO} install -D -p -m 644 "${OUT_DIR}/8723ds.ko" "${MNT}/lib/modules/${KERNEL_RELEASE}/kernel/drivers/net/wireless/8723ds.ko"

${SUDO} rm "${MNT}/lib/modules/${KERNEL_RELEASE}/build"
#${SUDO} rm "${MNT}/lib/modules/${KERNEL_RELEASE}/source"

${SUDO} depmod -a -b "${MNT}" "${KERNEL_RELEASE}"
echo '8723ds' >>8723ds.conf
${SUDO} mv 8723ds.conf "${MNT}/etc/modules-load.d/"

# install U-Boot
if [ "${BOOT_METHOD}" = 'script' ]; then
    ${SUDO} cp "${OUT_DIR}/boot.scr" "${MNT}/boot/"
elif [ "${BOOT_METHOD}" = 'extlinux' ]; then
    ${SUDO} mkdir -p "${MNT}/boot/extlinux"
    ROOT_FLAGS=""
    [ "${USE_BTRFS_SUBVOLS}" = "1" ] && ROOT_FLAGS="rootflags=subvol=@"
    (
        echo "label default
        linux   /Image
        append  mitigations=off earlycon=sbi console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootwait ${ROOT_FLAGS}"
    ) >extlinux.conf
    ${SUDO} mv extlinux.conf "${MNT}/boot/extlinux/extlinux.conf"
fi

# fstab
if [ "${USE_BTRFS_SUBVOLS}" = "1" ]; then
    (
        echo '# <device>    <dir>        <type>        <options>            <dump> <pass>
LABEL=boot    /boot        ext2          rw,defaults,noatime  0      1'
        for SUBVOL in ${BTRFS_SUBVOLS}; do
            MOUNT_POINT="/"
            [ "${SUBVOL}" != "@" ] && MOUNT_POINT="/${SUBVOL#@}"
            [ "${SUBVOL}" = "@snapshots" ] && MOUNT_POINT="/.snapshots"
            echo "LABEL=root    ${MOUNT_POINT}            btrfs         rw,defaults,noatime,subvol=${SUBVOL}  0      2"
        done
    ) >fstab
else
    (
        echo '# <device>    <dir>        <type>        <options>            <dump> <pass>
LABEL=boot    /boot        ext2          rw,defaults,noatime  0      1
LABEL=root    /            btrfs         rw,defaults,noatime  0      2'
    ) >fstab
fi
${SUDO} mv fstab "${MNT}/etc/fstab"

# set hostname
echo 'licheerv' >hostname
${SUDO} mv hostname "${MNT}/etc/"

# # updating ...
# ${SUDO} arch-chroot ${MNT} pacman -Syu
# ${SUDO} arch-chroot ${MNT} pacman -S wpa_supplicant
# ${SUDO} arch-chroot ${MNT} pacman -S netctl
# ${SUDO} arch-chroot ${MNT} pacman -S --asdeps dialog
${SUDO} arch-chroot ${MNT} sed -i 's/^#DisableSandbox/DisableSandbox/' /etc/pacman.conf
${SUDO} arch-chroot ${MNT} pacman -Syu --noconfirm
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox dhclient
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox dhcpcd
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --asdeps --disable-sandbox dialog
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox ell
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox glibc
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox ifplugd
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox iwd
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox libdaemon
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox nano
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox ncurses
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox netctl
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox run-parts
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox systemd-resolvconf
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox wireless_tools
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox wpa_supplicant
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox gcc
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox vim
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox git
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox openssh
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox btrfs-progs
${SUDO} arch-chroot ${MNT} pacman -S --noconfirm --disable-sandbox parted
# done
if [ "${USE_CHROOT}" != 0 ]; then
    echo ''
    echo 'Done! Now configure your new Archlinux!'
    echo ''
    echo 'You might want to update and install an editor as well as configure any network'
    echo ' -> https://wiki.archlinux.org/title/installation_guide#Configure_the_system'
    echo ''
    ${SUDO} arch-chroot "${MNT}"
else
    echo ''
    echo 'Done!'
fi

${SUDO} umount -R "${MNT}"
exit 0
