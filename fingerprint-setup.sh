#!/usr/bin/env bash
set -euo pipefail
# setup-fingerprint-x1c6.sh
# For Ubuntu 24.04 + ThinkPad X1 Carbon Gen6 (06cb:009a)
# Prepares python3-validity + open-fprintd, backs up old data, starts services.
# Interactive enrollment must be done manually after script finishes.

LOGFILE="/var/log/setup-fingerprint-$(date +%Y%m%d-%H%M%S).log"
echo "Log will be written to $LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

echo "==> Kiểm tra lsusb để xác nhận thiết bị fingerprint"
if ! command -v lsusb >/dev/null 2>&1; then
  echo "lsusb không tìm thấy. Cài usbutils..."
  apt update
  apt install -y usbutils
fi

echo "lsusb output:"
lsusb

echo
echo "==> Kiểm tra xem có device 06cb:009a không"
if lsusb | grep -iq "06cb:009a"; then
  echo "Thiết bị 06cb:009a được phát hiện — tiếp tục."
else
  echo "WARNING: Không tìm thấy 06cb:009a. Nếu máy bạn khác thiết bị, dừng lại."
  echo "Bạn vẫn có thể tiếp tục nhưng driver này có thể không phù hợp."
  read -p "Tiếp tục cài đặt? (y/N): " yn
  yn=${yn:-N}
  if [[ "$yn" != "y" && "$yn" != "Y" ]]; then
    echo "Thoát."
    exit 1
  fi
fi

echo
echo "==> Backup cấu hình validity và fprintd (nếu có)"
USER_HOME=$(eval echo "~$SUDO_USER")
if [ -z "$USER_HOME" ]; then
  USER_HOME="$HOME"
fi
BACKUP_DIR="$USER_HOME/validity-fprintd-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "Backup: $BACKUP_DIR"
# backup per-user validity config
if [ -d "$USER_HOME/.config/validity" ]; then
  cp -a "$USER_HOME/.config/validity" "$BACKUP_DIR/" || true
fi
# backup system config
if [ -d /etc/open-fprintd ]; then
  cp -a /etc/open-fprintd "$BACKUP_DIR/" || true
fi
if [ -d /etc/fprintd ]; then
  cp -a /etc/fprintd "$BACKUP_DIR/" || true
fi

echo
echo "==> Gỡ fprintd + libpam-fprintd nếu có (tránh xung đột)"
apt update
DEBS_TO_REMOVE=(fprintd libpam-fprintd)
for pkg in "${DEBS_TO_REMOVE[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "Removing $pkg ..."
    apt remove --purge -y "$pkg"
  else
    echo "$pkg not installed, skip."
  fi
done
apt autoremove -y

echo
echo "==> Thêm PPA uunicorn/open-fprintd (đã test cho Ubuntu 24.04)"
if ! grep -R "uunicorn/open-fprintd" /etc/apt/sources.list.d >/dev/null 2>&1; then
  apt install -y software-properties-common
  add-apt-repository -y ppa:uunicorn/open-fprintd
else
  echo "PPA đã tồn tại, bỏ qua."
fi

echo "apt update..."
apt update

echo
echo "==> Cài open-fprintd, python3-validity, fprintd-clients"
apt install -y open-fprintd python3-validity fprintd-clients || {
  echo "Lỗi khi cài gói. Kiểm tra $LOGFILE"
  exit 2
}

echo
echo "==> Kích hoạt và start service python3-validity + open-fprintd"
# service name may be python3-validity.service
systemctl enable --now python3-validity.service || {
  echo "Không bật được python3-validity.service — thử python-validity.service"
  systemctl enable --now python-validity.service || true
}
systemctl enable --now open-fprintd.service || true

sleep 1
echo "Trạng thái python3-validity.service (ngắn):"
systemctl status python3-validity.service --no-pager | sed -n '1,6p' || true

echo
echo "==> Xoá per-user enrollment cũ (nếu bạn muốn khởi sạch)"
read -p "Bạn có muốn xóa tất cả enroll đã lưu cho user hiện tại ($SUDO_USER)? (y/N): " delyn
delyn=${delyn:-N}
if [[ "$delyn" == "y" || "$delyn" == "Y" ]]; then
  echo "Xóa enroll của $SUDO_USER..."
  fprintd-delete "$SUDO_USER" || true
  rm -rf "$USER_HOME/.config/validity" || true
  echo "Đã xóa dữ liệu vân tay (backup có tại $BACKUP_DIR)."
else
  echo "Bỏ qua xóa enroll."
fi

echo
echo "==> Hướng dẫn enroll (phải chạy thủ công, interactive)"
cat <<'EOF'

BƯỚC ENROLL (chạy như user bình thường — KHÔNG SUDO):
1) Mở terminal bình thường (không phải root).
2) Chạy:
   fprintd-enroll
   hoặc enroll một ngón cụ thể, ví dụ:
   fprintd-enroll -f left-index-finger

3) Làm theo hướng dẫn: đặt ngón tay lên sensor nhiều lần, chạm nhẹ, giữ cố định vị trí.
4) Sau khi hoàn tất, test bằng:
   fprintd-verify
   hoặc khóa màn hình và thử unlock.

LOG debug (nếu gặp lỗi):
  sudo journalctl -u python3-validity.service -n 200 --no-pager
  sudo journalctl -u open-fprintd.service -n 200 --no-pager

EOF

echo
echo "==> (Tùy chọn) chạy tự động fprintd-enroll cho ngón trỏ trái (interactive)"
read -p "Bạn có muốn chạy 'fprintd-enroll -f left-index-finger' bây giờ (interactive)? (y/N): " runEnroll
runEnroll=${runEnroll:-N}
if [[ "$runEnroll" == "y" || "$runEnroll" == "Y" ]]; then
  echo "Bắt đầu enroll (interactive). Lưu ý: chạy dưới user bình thường (không dùng sudo)."
  su - "$SUDO_USER" -c "fprintd-enroll -f left-index-finger"
fi

echo
echo "==> Hoàn tất script. Nếu gặp lỗi, gửi nội dung cuối log:"
echo "  tail -n 200 $LOGFILE"
echo
echo "Lưu ý: luôn enroll nhiều ngón (ví dụ left-index và right-index) để tiện mở."
