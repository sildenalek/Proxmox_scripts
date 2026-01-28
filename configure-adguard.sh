#!/bin/bash
# configure-adguard.sh - Настройка AdGuard Home после установки

CT_ID="100"  # Укажите ID вашего контейнера

echo "Настройка AdGuard Home в контейнере $CT_ID"

# 1. Сброс пароля администратора
pct exec $CT_ID -- bash -c '
    cd /opt/AdGuardHome
    /usr/local/bin/AdGuardHome --config /opt/AdGuardHome/AdGuardHome.yaml -s reset-password
'

# 2. Добавление дополнительных фильтров
pct exec $CT_ID -- bash -c '
    cat >> /opt/AdGuardHome/AdGuardHome.yaml << EOF

# Дополнительные фильтры (раскомментируйте при необходимости)
#filters:
#  - enabled: true
#    url: https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
#    name: StevenBlack Unified Hosts
#    id: 1001
#  - enabled: true
#    url: https://easylist.to/easylist/easylist.txt
#    name: EasyList
#    id: 1002
EOF
'

# 3. Настройка локальных DNS записей
pct exec $CT_ID -- bash -c '
    cat > /opt/AdGuardHome/local_dns.yml << EOF
# Локальные DNS записи
# Формат: домен:IP
# Пример:
# home.lan: 192.168.1.10
# router.lan: 192.168.1.1
EOF
'

# 4. Настройка периодического обновления фильтров
pct exec $CT_ID -- bash -c '
    cat > /etc/cron.daily/adguard-update << EOF
#!/bin/bash
# Ежедневное обновление фильтров AdGuard Home
curl -X POST http://127.0.0.1:3000/control/filtering/refresh || true
EOF
    chmod +x /etc/cron.daily/adguard-update
'

echo "Настройка завершена!"
echo "Не забудьте:"
echo "1. Открыть http://[IP_контейнера]:3000"
echo "2. Установить новый пароль администратора"
echo "3. Настроить фильтры и правила"
