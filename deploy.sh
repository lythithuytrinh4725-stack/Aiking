#!/bin/bash
# =============================================================
#  GoClaw Full Deploy Script
#  Domain: aikingx.vn
#  Author: Claude AI
# =============================================================
set -e

# ---- Màu sắc terminal ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()    { echo -e "\n${BLUE}========== $1 ==========${NC}"; }

# ---- Cấu hình ----
DOMAIN="aikingx.vn"
DOMAIN_API="api.aikingx.vn"
EMAIL="admin@aikingx.vn"            # Email nhận cert SSL
TELEGRAM_TOKEN="8615374882:AAEc8IRfAhMT_SoCgyngOSvu5GsVvo30elg"
INSTALL_DIR="/opt/goclaw"
REPO_URL="https://github.com/nextlevelbuilder/goclaw.git"

# ============================================================
# PHASE 1 — Cập nhật hệ thống
# ============================================================
step "PHASE 1: Cập nhật hệ thống"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget git ufw \
    nginx certbot python3-certbot-nginx \
    ca-certificates gnupg lsb-release apt-transport-https

success "Cập nhật xong"

# ============================================================
# PHASE 2 — Cài Docker Engine + Docker Compose v2
# ============================================================
step "PHASE 2: Cài Docker"

if ! command -v docker &>/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    success "Docker cài xong: $(docker --version)"
else
    success "Docker đã có: $(docker --version)"
fi

docker compose version &>/dev/null || error "Docker Compose v2 không tìm thấy!"

# ============================================================
# PHASE 3 — Cấu hình UFW Firewall
# ============================================================
step "PHASE 3: Cấu hình Firewall"

# Giữ SSH port hiện tại (thêm cả 22 và 2018 để an toàn)
ufw allow 22/tcp
ufw allow 2018/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
success "Firewall OK: SSH(22,2018), HTTP(80), HTTPS(443)"

# ============================================================
# PHASE 4 — Clone GoClaw
# ============================================================
step "PHASE 4: Clone GoClaw"

if [ -d "$INSTALL_DIR/.git" ]; then
    info "GoClaw đã tồn tại, cập nhật..."
    cd "$INSTALL_DIR" && git pull
else
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi
success "GoClaw source: $INSTALL_DIR"

# ============================================================
# PHASE 5 — Tạo .env
# ============================================================
step "PHASE 5: Cấu hình .env"

cd "$INSTALL_DIR"

# Chạy script generate secrets có sẵn
chmod +x prepare-env.sh
bash prepare-env.sh

# Sinh mật khẩu DB ngẫu nhiên
DB_PASS=$(openssl rand -hex 20)

# Hàm set biến vào .env (không ghi đè nếu đã có)
set_env() {
    local key="$1" val="$2"
    if grep -q "^${key}=" .env 2>/dev/null; then
        # Nếu giá trị rỗng thì ghi đè
        current=$(grep "^${key}=" .env | cut -d= -f2-)
        if [ -z "$current" ]; then
            sed -i "s|^${key}=.*|${key}=${val}|" .env
        fi
    else
        echo "${key}=${val}" >> .env
    fi
}

# Bổ sung cấu hình
set_env "POSTGRES_USER"             "goclaw"
set_env "POSTGRES_PASSWORD"         "$DB_PASS"
set_env "POSTGRES_DB"               "goclaw"
set_env "GOCLAW_TELEGRAM_TOKEN"     "$TELEGRAM_TOKEN"
set_env "GOCLAW_PORT"               "18790"
set_env "GOCLAW_UI_PORT"            "3000"

success ".env đã cấu hình xong"
info "DB Password: $DB_PASS (lưu lại nếu cần)"

# ============================================================
# PHASE 6 — Deploy Docker Compose
# ============================================================
step "PHASE 6: Deploy Docker Compose"

cd "$INSTALL_DIR"

docker compose \
    -f docker-compose.yml \
    -f docker-compose.postgres.yml \
    -f docker-compose.selfservice.yml \
    pull

docker compose \
    -f docker-compose.yml \
    -f docker-compose.postgres.yml \
    -f docker-compose.selfservice.yml \
    up -d

info "Chờ services khởi động (30 giây)..."
sleep 30

# Kiểm tra health
if curl -sf http://localhost:18790/health &>/dev/null; then
    success "GoClaw API: OK (port 18790)"
else
    warn "GoClaw API chưa sẵn sàng, kiểm tra: docker compose logs goclaw"
fi

if curl -sf http://localhost:3000 &>/dev/null; then
    success "GoClaw UI: OK (port 3000)"
else
    warn "GoClaw UI chưa sẵn sàng"
fi

# ============================================================
# PHASE 7 — Nginx Reverse Proxy
# ============================================================
step "PHASE 7: Cấu hình Nginx"

# Xóa default site
rm -f /etc/nginx/sites-enabled/default

# Copy nginx config
cp /opt/goclaw-deploy/nginx/aikingx.vn.conf /etc/nginx/sites-available/aikingx.vn

# Enable site
ln -sf /etc/nginx/sites-available/aikingx.vn /etc/nginx/sites-enabled/aikingx.vn

# Test và reload
nginx -t && systemctl reload nginx
success "Nginx cấu hình xong"

# ============================================================
# PHASE 8 — SSL với Let's Encrypt
# ============================================================
step "PHASE 8: Cấp SSL (Let's Encrypt)"

# Kiểm tra domain đã trỏ về server chưa
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s api.ipify.org)
DOMAIN_IP=$(getent hosts "$DOMAIN" | awk '{print $1}' 2>/dev/null || dig +short "$DOMAIN" 2>/dev/null | tail -1)

if [ "$SERVER_IP" = "$DOMAIN_IP" ]; then
    certbot --nginx \
        -d "$DOMAIN" \
        -d "www.$DOMAIN" \
        -d "$DOMAIN_API" \
        --non-interactive \
        --agree-tos \
        -m "$EMAIL"
    systemctl reload nginx
    success "SSL đã cấp cho $DOMAIN"
else
    warn "Domain $DOMAIN chưa trỏ đúng về IP $SERVER_IP (hiện trỏ tới: $DOMAIN_IP)"
    warn "Hãy trỏ DNS xong rồi chạy lệnh sau để cấp SSL:"
    echo ""
    echo "  certbot --nginx -d $DOMAIN -d www.$DOMAIN -d $DOMAIN_API \\"
    echo "    --non-interactive --agree-tos -m $EMAIL"
    echo ""
fi

# ============================================================
# PHASE 9 — Telegram Webhook
# ============================================================
step "PHASE 9: Cấu hình Telegram Webhook"

# Thử set webhook (nếu SSL đã sẵn sàng)
if curl -sf https://$DOMAIN &>/dev/null; then
    WEBHOOK_URL="https://${DOMAIN_API}/webhook/telegram"
    RESULT=$(curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/setWebhook" \
        -H "Content-Type: application/json" \
        -d "{\"url\": \"$WEBHOOK_URL\"}")

    if echo "$RESULT" | grep -q '"ok":true'; then
        success "Telegram Webhook đã set: $WEBHOOK_URL"
    else
        warn "Webhook lỗi: $RESULT"
    fi
else
    warn "SSL chưa ready, set webhook sau bằng script webhook-setup.sh"
fi

# ============================================================
# DONE
# ============================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  DEPLOY HOÀN TẤT!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  Dashboard: ${CYAN}https://$DOMAIN${NC}"
echo -e "  API:       ${CYAN}https://$DOMAIN_API${NC}"
echo -e "  Local UI:  ${CYAN}http://localhost:3000${NC}"
echo -e "  Local API: ${CYAN}http://localhost:18790${NC}"
echo ""
echo -e "${YELLOW}Bước tiếp theo:${NC}"
echo "  1. Mở https://$DOMAIN trên trình duyệt"
echo "  2. Vào Settings → Providers → Thêm AI Provider"
echo "     - Base URL: <URL proxy của bạn>"
echo "     - API Key: <key của bạn>"
echo "     - Models: gpt-5.1-all, gemini-2.5-pro"
echo "  3. Vào Channels → Telegram để kết nối bot"
echo ""
echo "  Xem logs: cd $INSTALL_DIR && docker compose logs -f"
echo "  Trạng thái: bash /opt/goclaw-deploy/check-status.sh"
echo ""
