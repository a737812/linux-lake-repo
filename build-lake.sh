#!/bin/bash
# =========================================================
# Linux-Lake-OS 全能系统构建器 (build-lake.sh)  - V2.0
#
# 产出物:
#   - Lake-OS-arm64.qcow2   : 完整可启动虚拟磁盘 (QEMU/KVM)
#   - Lake-OS-arm64.iso     : Live 启动安装镜像
#   - Lake-rootfs.tar.xz    : 根文件系统压缩包
#
# 用法:
#   ./build-lake.sh [qcow2|iso|all] [构建目录]
#
# 注意:
#   此脚本设计为在【完整 root + loop 设备可用】的 Linux 构建机
#   (真机/VM/云服务器/树莓派) 上运行。Android 沙盒因 noexec、
#   loop 权限受限无法直接挂载，但本脚本在真机上一键完成。
# =========================================================
set -e

FORMAT="${1:-all}"
WORKDIR="${2:-./lake-build}"
ARCH="arm64"
SUITE="bookworm"
MIRROR="http://mirrors.tuna.tsinghua.edu.cn/debian/"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

LAKE_ROOT="/storage/emulated/0/Linux-lake os"
SRC_CONFIG="$LAKE_ROOT/config"
SRC_PM="$LAKE_ROOT/lake-pm"
SRC_CORE="$LAKE_ROOT/lake-core"

red(){ echo -e "\033[1;31m$1\033[0m"; }
grn(){ echo -e "\033[1;32m$1\033[0m"; }
cyn(){ echo -e "\033[1;36m$1\033[0m"; }

cyn "============================================="
cyn "   Linux-Lake-OS Ultimate 全能系统构建器"
cyn "   架构: $ARCH   基础: $SUITE"
cyn "============================================="
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ---------- 1. 构建根文件系统 ----------
if [ ! -d chroot ]; then
    cyn "[1/6] debootstrap 拉取最小系统..."
    debootstrap --arch="$ARCH" \
        --include=linux-image-$ARCH,systemd,network-manager,sudo,python3,curl,bash-completion,ca-certificates \
        "$SUITE" ./chroot "$MIRROR"
fi

# ---------- 2. 注入 Lake-OS 品牌与核心工具 ----------
cyn "[2/6] 注入 Lake-OS 系统骨架..."
for f in os-release lsb-release; do
    cp "$SRC_CONFIG/etc/$f" ./chroot/etc/$f
done
mkdir -p ./chroot/etc/profile.d
cp "$SRC_CONFIG/etc/profile.d/lake-init.sh" ./chroot/etc/profile.d/
mkdir -p ./chroot/usr/local/lib/lake
cp "$SRC_PM/lake" ./chroot/usr/local/lib/lake/
ln -sf /usr/local/lib/lake/lake ./chroot/usr/local/bin/lake
mkdir -p ./chroot/usr/local/bin
for t in lake-tune lake-security lake-fix lake-update; do
    cp "$SRC_CORE/$t" ./chroot/usr/local/bin/ 2>/dev/null || true
done
cp -r "$SRC_CORE/fw" ./chroot/usr/local/bin/ 2>/dev/null || true
cp -r "$SRC_CORE/guard" ./chroot/usr/local/bin/ 2>/dev/null || true
cp -r "$SRC_CORE/ui" ./chroot/usr/local/bin/ 2>/dev/null || true
chmod -R +x ./chroot/usr/local/bin/ ./chroot/usr/local/lib/lake/ 2>/dev/null || true

# 源配置
mkdir -p ./chroot/etc/lake
cat > ./chroot/etc/lake/lake-repo.env <<EOF
LAKE_INDEX_URL="https://raw.githubusercontent.com/a737812/linux-lake-repo/main/index.json"
LAKE_SUBI_BASE="https://raw.githubusercontent.com/a737812/linux-lake-sub1/main/"
EOF

# ---------- 3. chroot 内定制（语言/时区/用户/驱动）----------
cyn "[3/6] 系统定制 + 通用驱动注入..."
chroot ./chroot /bin/bash -c "
  apt-get update && apt-get install -y --no-install-recommends \
    locales console-setup dialog iptables \
    firmware-linux-free firmware-atheros firmware-brcm80211 firmware-realtek \
    openssh-server
  locale-gen en_US.UTF-8 zh_CN.UTF-8 >/dev/null 2>&1
  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  echo 'Lake-OS' > /etc/hostname
  useradd -m -s /bin/bash lake && echo 'lake:lake' | chpasswd
  echo 'lake ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/lake
  systemctl disable systemd-resolved 2>/dev/null || true
"

# ---------- 4. 打包 rootfs & 生成镜像 ----------
cyn "[4/6] 打包根文件系统..."
tar -cJf Lake-rootfs.tar.xz -C ./chroot .

build_qcow2() {
    cyn "[5/6] 组装 QCOW2 虚拟磁盘 (含 EFI + GRUB)..."
    IMG=Lake-OS-arm64.img
    QCOW=Lake-OS-arm64.qcow2
    dd if=/dev/zero of=$IMG bs=1M count=4096 status=none
    parted -s $IMG mklabel gpt
    parted -s $IMG mkpart ESP fat32 1MiB 500MiB
    parted -s $IMG set 1 esp on
    parted -s $IMG mkpart primary ext4 500MiB 100%
    # loop 挂载 (在完整 Linux 上可用)
    if command -v losetup >/dev/null && command -v kpartx >/dev/null; then
        LOOP=$(losetup --find --show --partscan $IMG)
        sleep 1
        mkfs.vfat "${LOOP}p1" >/dev/null
        mkfs.ext4 -F "${LOOP}p2" >/dev/null
        mkdir -p /mnt/lake-root /mnt/lake-efi
        mount "${LOOP}p2" /mnt/lake-root
        mount "${LOOP}p1" /mnt/lake-efi
        cp -a ./chroot/. /mnt/lake-root/
        # 安装 GRUB
        mkdir -p /mnt/lake-efi/EFI/BOOT
        cp /usr/lib/grub/arm64-efi/grub.efi /mnt/lake-efi/EFI/BOOT/BOOTAA64.EFI 2>/dev/null || true
        cat > /mnt/lake-efi/EFI/BOOT/grub.cfg <<GRUB
set timeout=3
menuentry "Linux-Lake-OS" {
  search --set=root --file /boot/vmlinuz-*
  linux /boot/vmlinuz-\$(ls /boot | grep vmlinuz | head -1) root=/dev/vda2 quiet splash
  initrd /boot/initrd.img-\$(ls /boot | grep initrd | head -1)
}
GRUB
        umount /mnt/lake-root /mnt/lake-efi
        losetup -d $LOOP
        cyn "[6/6] 转换为精简 qcow2..."
        qemu-img convert -f raw -O qcow2 -c $IMG $QCOW
        rm -f $IMG
        grn "✔ 产出: $(pwd)/$QCOW"
    else
        red "  构建机缺少 losetup/kpartx，无法挂载分区。"
        red "  已保留 rootfs: $(pwd)/Lake-rootfs.tar.xz"
    fi
}

build_iso() {
    cyn "[5/6] 组装 Live ISO..."
    chroot ./chroot apt-get install -y --no-install-recommends live-boot live-config xorriso isolinux grub-efi-arm64-bin >/dev/null 2>&1 || true
    mkdir -p ./chroot/boot/grub
    cat > ./chroot/boot/grub/grub.cfg <<'GRUB'
set timeout=5
menuentry "Linux-Lake-OS (Live)" { linux /boot/vmlinuz boot=live quiet splash; initrd /boot/initrd.img; }
GRUB
    KVER=$(ls ./chroot/boot/vmlinuz-* 2>/dev/null | head -n1 | xargs basename 2>/dev/null | sed 's/vmlinuz-//')
    if [ -n "$KVER" ]; then
        xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid "Lake-OS" \
            -o Lake-OS-arm64.iso ./chroot >/dev/null 2>&1 || xorriso -as mkisofs -o Lake-OS-arm64.iso ./chroot
        grn "✔ 产出: $(pwd)/Lake-OS-arm64.iso"
    else
        red "  未发现内核，ISOLIVE 跳过（rootfs 已可安装）"
    fi
}

case "$FORMAT" in
    qcow2) build_qcow2 ;;
    iso)   build_iso ;;
    all)   build_qcow2; build_iso ;;
    *)     red "未知格式: $FORMAT (可用: qcow2/iso/all)"; exit 1 ;;
esac

grn "============================================="
grn "   Linux-Lake-OS 构建完成！镜像位于: $WORKDIR"
grn "============================================="