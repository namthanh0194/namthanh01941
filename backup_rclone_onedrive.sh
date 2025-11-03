#!/usr/bin/env bash
set -euo pipefail

###################### CẤU HÌNH ######################
# Tên remote rclone (đặt theo khi bạn "rclone config")
REMOTE_NAME="onedrive"

# Thư mục trên OneDrive để lưu backup (mặc định theo hostname)
REMOTE_DIR="Backups_docker/${HOSTNAME}"

# Các thư mục cần backup (sửa theo nhu cầu)
SOURCES=(
  "/www/dk_project/dk_app"
#   "/www/wwwroot"   # thêm nếu cần
)

# Thư mục tạm lưu file nén trước khi upload
LOCAL_STAGING="/var/backups/rclone_staging"

# Số bản mới nhất cần giữ trên OneDrive
KEEP_RECENT=3

# Có giữ 1 bản cũ nhất trong nhóm < 30 ngày không? (1 = bật, 0 = tắt)
# Lưu ý: Bản này sẽ là bản cũ nhất trong các bản không phải KEEP_RECENT bản mới nhất
KEEP_ONE_OLDER_WITHIN_30D=1

# Mật độ nén (ưu tiên zstd nếu có)
# zstd nhanh + tốt, nếu không có thì dùng gzip.
######################################################

mkdir -p "$LOCAL_STAGING"

# Tạo tên file có timestamp
# Định dạng: backups-docker-<hostname>-YYYYMMDD-HHMMSS.tar.zst|gz
TS="$(date -u +%Y%m%d-%H%M%S)"
HOST="$(hostname)"
ARCHIVE_BASENAME="backups-docker-${HOST}-${TS}"
ARCHIVE_PATH_ZST="${LOCAL_STAGING}/${ARCHIVE_BASENAME}.tar.zst"
ARCHIVE_PATH_GZ="${LOCAL_STAGING}/${ARCHIVE_BASENAME}.tar.gz"

echo "[INFO] Bắt đầu nén dữ liệu lúc $(date -u +'%F %T') UTC ..."
if command -v zstd >/dev/null 2>&1; then
  # Nén zstd (dùng đa luồng nếu có)
  TAR_CMD=(tar -I "zstd -T0 -19" -cf "$ARCHIVE_PATH_ZST" --xattrs --acls)
  for s in "${SOURCES[@]}"; do TAR_CMD+=("$s"); done
  "${TAR_CMD[@]}"
  ARCHIVE_PATH="$ARCHIVE_PATH_ZST"
  echo "[INFO] Đã nén bằng zstd: $ARCHIVE_PATH"
else
  # Fallback gzip (pigz nếu có)
  if command -v pigz >/dev/null 2>&1; then
    TAR_CMD=(tar -I "pigz -9" -cf "$ARCHIVE_PATH_GZ" --xattrs --acls)
  else
    TAR_CMD=(tar -czf "$ARCHIVE_PATH_GZ" --xattrs --acls)
  fi
  for s in "${SOURCES[@]}"; do TAR_CMD+=("$s"); done
  "${TAR_CMD[@]}"
  ARCHIVE_PATH="$ARCHIVE_PATH_GZ"
  echo "[INFO] Đã nén bằng gzip: $ARCHIVE_PATH"
fi

REMOTE_PATH="${REMOTE_NAME}:${REMOTE_DIR}"
REMOTE_FILE="${REMOTE_PATH}/$(basename "$ARCHIVE_PATH")"

echo "[INFO] Upload lên OneDrive: $REMOTE_FILE"
# Upload (copyto để đích là file cụ thể)
rclone copyto "$ARCHIVE_PATH" "$REMOTE_FILE" --transfers=4 --checkers=8 --fast-list --retries=3 --low-level-retries=5

# Xác nhận file có trên OneDrive (dựa theo tên)
if rclone lsf "$REMOTE_PATH" --files-only | grep -Fxq "$(basename "$ARCHIVE_PATH")"; then
  echo "[INFO] Upload thành công. Xóa bản local: $ARCHIVE_PATH"
  rm -f "$ARCHIVE_PATH"
else
  echo "[ERROR] Không tìm thấy file vừa upload trên OneDrive. Giữ lại file local để an toàn." >&2
  exit 1
fi

#############################################
#           CHÍNH SÁCH GIỮ LẠI FILES        #
#############################################
# Mục tiêu:
#  - Giữ KEEP_RECENT bản mới nhất
#  - Và (nếu bật) giữ thêm 1 bản "cũ nhất" trong các bản không phải KEEP_RECENT bản mới nhất
#    nhưng phải trong vòng 30 ngày
#  - Xóa các bản còn lại trên OneDrive

echo "[INFO] Áp dụng retention trên OneDrive ..."

# Lấy danh sách file (tên) và sort ngược (mới -> cũ) theo tên có timestamp
# Chỉ xét các file đúng pattern backups-docker-<hostname>-YYYYMMDD-HHMMSS.tar.*
mapfile -t ALL_FILES < <(rclone lsf "$REMOTE_PATH" --files-only \
  | grep -E "^backups-docker-${HOST}-[0-9]{8}-[0-9]{6}\.tar\.(zst|gz)$" \
  | sort -r)

TOTAL=${#ALL_FILES[@]}
if (( TOTAL == 0 )); then
  echo "[INFO] Không có file nào trên OneDrive để dọn."
  exit 0
fi

# Bộ file cần giữ
declare -A KEEP
# 1) Giữ N bản mới nhất
for (( i=0; i<KEEP_RECENT && i<TOTAL; i++ )); do
  KEEP["${ALL_FILES[$i]}"]=1
done

# 2) Giữ 1 bản cũ nhất trong nhóm các bản không phải KEEP_RECENT bản mới nhất (nếu bật cờ)
#    Nhưng bản này phải trong vòng 30 ngày
if (( KEEP_ONE_OLDER_WITHIN_30D == 1 )); then
  THRESHOLD_30D_AGO="$(date -u -d '30 days ago' +%Y%m%d%H%M%S)"
  
  # Tìm bản cũ nhất trong các bản không phải KEEP_RECENT bản mới nhất
  # Duyệt từ cuối mảng (cũ nhất) lên, bỏ qua các bản đã được đánh dấu KEEP
  OLDEST_FILE=""
  for (( i=TOTAL-1; i>=KEEP_RECENT; i-- )); do
    f="${ALL_FILES[$i]}"
    # Bỏ qua nếu đã được đánh dấu giữ
    if [[ -n "${KEEP["$f"]+x}" ]]; then
      continue
    fi
    
    # Trích timestamp từ tên file
    # backups-docker-<host>-YYYYMMDD-HHMMSS.tar.*
    if [[ "$f" =~ ^backups-docker-${HOST}-([0-9]{8})-([0-9]{6})\.tar\.(zst|gz)$ ]]; then
      TSFILE="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"  # YYYYMMDDHHMMSS
      # Kiểm tra file này phải trong vòng 30 ngày (timestamp > THRESHOLD_30D_AGO)
      if [[ "$TSFILE" -gt "$THRESHOLD_30D_AGO" ]]; then
        OLDEST_FILE="$f"
        # Tìm được bản cũ nhất trong vòng 30 ngày, dừng lại
        break
      fi
    fi
  done
  
  # Nếu tìm thấy bản cũ nhất trong vòng 30 ngày, đánh dấu giữ
  if [[ -n "$OLDEST_FILE" ]]; then
    KEEP["$OLDEST_FILE"]=1
    echo "[INFO] Giữ thêm bản cũ nhất trong 30 ngày: $OLDEST_FILE"
  fi
fi

# 3) Xóa các file không thuộc KEEP
DELETED=0
for f in "${ALL_FILES[@]}"; do
  if [[ -z "${KEEP["$f"]+x}" ]]; then
    echo "[INFO] Xóa trên OneDrive: $f"
    rclone deletefile "${REMOTE_PATH}/${f}" || {
      echo "[WARN] Không xóa được: ${REMOTE_PATH}/${f}" >&2
    }
    ((DELETED++))
  fi
done
echo "[INFO] Dọn dẹp xong. Đã xóa ${DELETED} file."

echo "[DONE] Hoàn tất backup + retention lúc $(date -u +'%F %T') UTC"
