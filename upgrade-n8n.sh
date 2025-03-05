#!/bin/bash

#Cách sử dụng
#curl -sSL https://raw.githubusercontent.com/namthanh0194/namthanh01941/refs/heads/main/upgrade-n8n.sh > upgrade-n8n.sh && chmod +x upgrade-n8n.sh && sudo ./upgrade-n8n.sh

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then 
  echo "Script này cần được chạy với quyền root"
  exit 1
fi

# Đường dẫn thư mục n8n
N8N_DIR="/home/n8n"
BACKUP_DIR="/root/backup-n8n"

# Hiển thị cảnh báo
echo "=== CẢNH BÁO ==="
echo "Việc nâng cấp n8n có thể ảnh hưởng đến dữ liệu."
echo "Bạn nên backup dữ liệu trước khi tiếp tục."
echo "================="

# Hỏi người dùng có muốn backup
read -p "Bạn có muốn backup dữ liệu n8n không? (y/n): " answer
if [[ $answer == [yY] || $answer == [yY][eE][sS] ]]; then
    echo "Bắt đầu backup..."
    
    # Tạo thư mục backup nếu chưa tồn tại
    mkdir -p "$BACKUP_DIR"
    
    # Tạo backup sử dụng rsync
    rsync -a --delete "$N8N_DIR/" "$BACKUP_DIR/"
    
    if [ $? -eq 0 ]; then
        echo "Backup hoàn tất tại $BACKUP_DIR"
    else
        echo "Lỗi khi backup! Hủy quá trình nâng cấp."
        exit 1
    fi
else
    read -p "Bạn có chắc chắn muốn tiếp tục mà không backup? (y/n): " confirm
    if [[ $confirm != [yY] && $confirm != [yY][eE][sS] ]]; then
        echo "Hủy quá trình nâng cấp."
        exit 1
    fi
fi

# Bắt đầu quá trình nâng cấp
echo "Bắt đầu nâng cấp n8n..."

# Di chuyển đến thư mục n8n
cd "$N8N_DIR"

# Pull image mới nhất
docker-compose pull

# Dừng và xóa container cũ
docker-compose down

# Khởi động container với image mới
docker-compose up -d

# Kiểm tra trạng thái
echo "Đợi 10 giây để kiểm tra trạng thái..."
sleep 10

if docker-compose ps | grep -q "Up"; then
    echo "Nâng cấp n8n thành công!"
    echo "Kiểm tra logs:"
    docker-compose logs --tail=50
else
    echo "Có lỗi xảy ra! Container không hoạt động."
    echo "Kiểm tra logs:"
    docker-compose logs --tail=50
fi

echo "Hoàn tất quá trình nâng cấp."
