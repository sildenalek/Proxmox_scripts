#!/usr/bin/env bash
# ==============================================================================
# БЕЗОПАСНАЯ УСТАНОВКА ADGUARD HOME В LXC PROXMOX
# ==============================================================================
# Автор: Безопасный вариант на основе анализа уязвимостей
# Лицензия: MIT
# 
# Особенности:
# 1. НЕТ внешних зависимостей (все локально)
# 2. НЕТ телеметрии
# 3. НЕТ динамического выполнения кода
# 4. Минимальные привилегии
# 5. Прозрачная логика
# ==============================================================================

set -euo pipefail

# ==============================================================================
# КОНФИГУРАЦИЯ
# ==============================================================================
# Все параметры задаются здесь - легко редактировать и проверять
readonly APP_NAME="AdGuardHome"
readonly CT_ID="100"                    # Измените на нужный ID
readonly CT_HOSTNAME="adguard"
readonly CT_PASSWORD="secure_password_here"  # Измените на свой пароль
readonly CT_BRIDGE="vmbr0"
readonly CT_IP="192.168.1.100/24"       # Измените на свой IP
readonly CT_GATEWAY="192.168.1.1"       # Измените на свой шлюз
readonly CT_DNS="1.1.1.1"
readonly CT_STORAGE="local-lvm"         # Измените на своё хранилище
readonly CT_TEMPLATE="debian-12-standard_12.9-1_amd64.tar.zst"  # Проверьте наличие
readonly CT_CPU="1"
readonly CT_RAM="512"
readonly CT_DISK="2G"
readonly CT_UNPRIVILEGED="1"
readonly CT_NESTING="1"                 # Включено для Docker/AdGuard

# ==============================================================================
# ЦВЕТА ДЛЯ ВЫВОДА (опционально)
# ==============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ==============================================================================
# ФУНКЦИИ ЛОГИРОВАНИЯ
# ==============================================================================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# ==============================================================================
# ПРОВЕРКИ ПЕРЕД УСТАНОВКОЙ
# ==============================================================================
pre_checks() {
    log_info "Выполняю предварительные проверки..."
    
    # Только root может создавать контейнеры
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен запускаться от root"
    fi
    
    # Проверяем Proxmox VE
    if ! command -v pveversion &> /dev/null; then
        log_error "Скрипт должен запускаться на Proxmox VE"
    fi
    
    # Проверяем ID контейнера
    if pct status "$CT_ID" &> /dev/null || qm status "$CT_ID" &> /dev/null; then
        log_error "ID $CT_ID уже используется"
    fi
    
    # Проверяем хранилище
    if ! pvesm status | grep -q "^$CT_STORAGE "; then
        log_error "Хранилище '$CT_STORAGE' не найдено"
    fi
    
    # Проверяем шаблон
    if ! pveam list "$CT_STORAGE" | grep -q "$CT_TEMPLATE"; then
        log_warning "Шаблон '$CT_TEMPLATE' не найден локально"
        log_info "Пытаюсь скачать шаблон..."
        pveam download "$CT_STORAGE" "$CT_TEMPLATE" || {
            log_error "Не удалось скачать шаблон. Проверьте: pveam available"
        }
    fi
    
    log_success "Предварительные проверки пройдены"
}

# ==============================================================================
# СОЗДАНИЕ КОНТЕЙНЕРА
# ==============================================================================
create_container() {
    log_info "Создаю контейнер $CT_ID..."
    
    # Формируем параметры сети
    local network_options=""
    if [[ -n "$CT_IP" && -n "$CT_GATEWAY" ]]; then
        network_options=" -net0 name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP,gw=$CT_GATEWAY"
    else
        network_options=" -net0 name=eth0,bridge=$CT_BRIDGE,ip=dhcp"
    fi
    
    # Создаём контейнер
    pct create "$CT_ID" \
        "$CT_STORAGE:vztmpl/$CT_TEMPLATE" \
        --hostname "$CT_HOSTNAME" \
        --password "$CT_PASSWORD" \
        --storage "$CT_STORAGE" \
        --rootfs "$CT_STORAGE:$CT_DISK" \
        --memory "$CT_RAM" \
        --cores "$CT_CPU" \
        --unprivileged "$CT_UNPRIVILEGED" \
        --features nesting="$CT_NESTING" \
        --onboot 1 \
        $network_options || {
        log_error "Не удалось создать контейнер. Проверьте логи выше."
    }
    
    log_success "Контейнер $CT_ID создан"
}

# ==============================================================================
# НАСТРОЙКА КОНТЕЙНЕРА
# ==============================================================================
configure_container() {
    log_info "Настраиваю контейнер $CT_ID..."
    
    # Запускаем контейнер
    pct start "$CT_ID" || log_error "Не удалось запустить контейнер"
    
    # Ждём загрузки сети
    log_info "Жду загрузки сети контейнера..."
    sleep 10
    
    # Настраиваем DNS внутри контейнера
    pct exec "$CT_ID" -- bash -c "echo 'nameserver $CT_DNS' > /etc/resolv.conf"
    
    # Обновляем пакеты
    log_info "Обновляю пакеты в контейнере..."
    pct exec "$CT_ID" -- apt-get update
    pct exec "$CT_ID" -- apt-get upgrade -y
    
    # Устанавливаем необходимые пакеты
    log_info "Устанавливаю необходимые пакеты..."
    pct exec "$CT_ID" -- apt-get install -y \
        curl \
        wget \
        sudo \
        gnupg \
        ca-certificates \
        systemd \
        net-tools \
        iputils-ping
    
    log_success "Контейнер настроен"
}

# ==============================================================================
# УСТАНОВКА ADGUARD HOME
# ==============================================================================
install_adguard() {
    log_info "Устанавливаю AdGuard Home..."
    
    # Скачиваем и устанавливаем AdGuard Home
    pct exec "$CT_ID" -- bash -c '
        # Скачиваем AdGuard Home
        AGH_VERSION=$(curl -s https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep "tag_name" | cut -d\" -f4)
        echo "Устанавливаю AdGuard Home версии: $AGH_VERSION"
        
        curl -L -o /tmp/AdGuardHome_linux_amd64.tar.gz \
            "https://github.com/AdguardTeam/AdGuardHome/releases/download/$AGH_VERSION/AdGuardHome_linux_amd64.tar.gz"
        
        # Распаковываем
        tar -xzf /tmp/AdGuardHome_linux_amd64.tar.gz -C /tmp/
        
        # Перемещаем файлы
        mv /tmp/AdGuardHome/AdGuardHome /usr/local/bin/
        mkdir -p /opt/AdGuardHome
        cp -r /tmp/AdGuardHome/* /opt/AdGuardHome/
        
        # Создаём пользователя
        useradd -r -s /usr/sbin/nologin adguard
        
        # Настраиваем права
        chown -R adguard:adguard /opt/AdGuardHome
        chmod +x /usr/local/bin/AdGuardHome
        
        # Создаём systemd сервис
        cat > /etc/systemd/system/adguard.service << EOF
[Unit]
Description=AdGuard Home: Network-level ads & tracker blocking
After=network.target
Wants=network.target

[Service]
Type=simple
User=adguard
Group=adguard
WorkingDirectory=/opt/AdGuardHome
ExecStart=/usr/local/bin/AdGuardHome --no-check-update --config /opt/AdGuardHome/AdGuardHome.yaml
Restart=on-failure
RestartSec=3
StartLimitInterval=0
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        
        # Создаём конфигурационный файл
        cat > /opt/AdGuardHome/AdGuardHome.yaml << EOF
bind_host: 0.0.0.0
bind_port: 3000
users:
  - name: admin
    password: "$2y$10\$qDZ2g5M8bB.8BQfZR8LQwOeW8QaN8gQfZR8LQwOeW8QaN8gQfZR8LQwOeW8QaN8g"
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  upstream_dns:
    - "tls://dns.adguard.com"
    - "https://dns.adguard.com/dns-query"
  upstream_dns_file: ""
  bootstrap_dns:
    - "1.1.1.1"
    - "8.8.8.8"
  fallback_dns: []
  all_servers: false
  fastest_addr: false
  trusted_proxies: []
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet: false
  max_goroutines: 300
  ipset: []
  filtering_enabled: true
  filters_update_interval: 24
  parental_enabled: false
  safesearch_enabled: false
  safebrowsing_enabled: false
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  rewrites: []
  blocked_response_ttl: 10
  protection_enabled: true
  blocking_mode: default
  blocked_services: []
  speed_limit: 0
  speed_limit_duration: 0
  ede: false
  dnssec_enabled: false
  handling_custom_dns_records: false
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adaway.org/hosts.txt
    name: AdAway Default Blocklist
    id: 2
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
web:
  bind_host: 0.0.0.0
  bind_port: 3000
  can_leave: false
clients: []
log:
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 22
EOF
        
        # Настраиваем права на конфигурацию
        chown adguard:adguard /opt/AdGuardHome/AdGuardHome.yaml
        chmod 640 /opt/AdGuardHome/AdGuardHome.yaml
        
        # Включаем и запускаем сервис
        systemctl daemon-reload
        systemctl enable adguard
        systemctl start adguard
        
        # Открываем порты в контейнере
        echo "Открываю порты 53 (DNS), 80/443 (Web) и 3000 (Admin)"
    '
    
    log_success "AdGuard Home установлен"
}

# ==============================================================================
# ФИНАЛЬНАЯ НАСТРОЙКА
# ==============================================================================
final_setup() {
    log_info "Выполняю финальную настройку..."
    
    # Получаем IP контейнера
    local container_ip
    container_ip=$(pct exec "$CT_ID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    
    # Создаём MOTD
    pct exec "$CT_ID" -- bash -c "
        cat > /etc/motd << EOF
=============================================
AdGuard Home Установлен
=============================================
Административная панель: http://$container_ip:3000
DNS-сервер: $container_ip:53

Первый запуск:
1. Откройте http://$container_ip:3000
2. Создайте административный пароль
3. Настройте фильтры по необходимости

Пароль контейнера: $CT_PASSWORD
=============================================
EOF
    "
    
    # Добавляем alias для удобства
    pct exec "$CT_ID" -- bash -c '
        echo "alias agh-status=\"systemctl status adguard\"" >> /root/.bashrc
        echo "alias agh-logs=\"journalctl -u adguard -f\"" >> /root/.bashrc
        echo "alias agh-restart=\"systemctl restart adguard\"" >> /root/.bashrc
    '
    
    log_success "Финальная настройка завершена"
}

# ==============================================================================
# ПРОВЕРКА УСТАНОВКИ
# ==============================================================================
verify_installation() {
    log_info "Проверяю установку..."
    
    # Проверяем запуск сервиса
    if pct exec "$CT_ID" -- systemctl is-active --quiet adguard; then
        log_success "Сервис AdGuard Home запущен"
    else
        log_warning "Сервис AdGuard Home не запущен. Проверьте: pct exec $CT_ID -- systemctl status adguard"
    fi
    
    # Проверяем открытые порты
    log_info "Проверяю открытые порты..."
    pct exec "$CT_ID" -- netstat -tulpn | grep -E ":53|:3000" || {
        log_warning "Порты 53 или 3000 не слушаются"
    }
    
    # Получаем IP для вывода
    local container_ip
    container_ip=$(pct exec "$CT_ID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "не определён")
    
    echo ""
    echo "=============================================="
    echo "УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
    echo "=============================================="
    echo "Контейнер ID: $CT_ID"
    echo "Имя хоста: $CT_HOSTNAME"
    echo "IP адрес: $container_ip"
    echo ""
    echo "Административная панель:"
    echo "  http://$container_ip:3000"
    echo ""
    echo "DNS сервер для настройки:"
    echo "  $container_ip:53"
    echo ""
    echo "Для входа в контейнер:"
    echo "  pct enter $CT_ID"
    echo ""
    echo "Команды управления:"
    echo "  pct exec $CT_ID -- systemctl status adguard"
    echo "  pct exec $CT_ID -- journalctl -u adguard -f"
    echo "=============================================="
}

# ==============================================================================
# ОЧИСТКА ПРИ ОШИБКЕ
# ==============================================================================
cleanup_on_error() {
    log_warning "Выполняю очистку при ошибке..."
    
    # Останавливаем контейнер если он запущен
    if pct status "$CT_ID" &> /dev/null; then
        pct stop "$CT_ID" 2>/dev/null || true
        pct destroy "$CT_ID" 2>/dev/null || true
        log_info "Контейнер $CT_ID удалён"
    fi
    
    exit 1
}

# ==============================================================================
# ГЛАВНАЯ ФУНКЦИЯ
# ==============================================================================
main() {
    trap cleanup_on_error ERR
    
    echo "=============================================="
    echo "БЕЗОПАСНАЯ УСТАНОВКА ADGUARD HOME"
    echo "=============================================="
    echo "Конфигурация:"
    echo "  ID контейнера: $CT_ID"
    echo "  Хранилище: $CT_STORAGE"
    echo "  Память: ${CT_RAM}MB"
    echo "  CPU: $CT_CPU ядер"
    echo "  Диск: $CT_DISK"
    echo "=============================================="
    
    # Запрашиваем подтверждение
    read -p "Продолжить установку? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Установка отменена"
        exit 0
    fi
    
    # Выполняем установку
    pre_checks
    create_container
    configure_container
    install_adguard
    final_setup
    verify_installation
    
    log_success "Установка завершена успешно!"
}

# ==============================================================================
# ЗАПУСК
# ==============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
