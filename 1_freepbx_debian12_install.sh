#!/usr/bin/env bash
# FreePBX 17 + Asterisk LTS на Debian 12 (bookworm)
# Обвязка вокруг официального инсталлятора FreePBX с базовой подготовкой ОС.
# Непрерывная, неинтерактивная установка. Логи: /root/freepbx-wrapper.log и /var/log/pbx/freepbx17-install-*.log

set -euo pipefail

### === ПАРАМЕТРЫ, МОЖНО МЕНЯТЬ ===
TIMEZONE="${TIMEZONE:-UTC}"         # Часовой пояс для сервера (пример: Europe/Moscow)
ENABLE_UFW="${ENABLE_UFW:-no}"      # yes|no — включить UFW и открыть порты (для старта лучше no, чтобы не конфликтовать с Firewall в FreePBX)
INSTALL_DAHDI="${INSTALL_DAHDI:-no}" # yes|no — ставить DAHDI/wanpipe (только если есть плата; зафиксирует ядро)
EXTRA_ARGS="${EXTRA_ARGS:-}"        # Доп. флаги для офиц. скрипта: --opensourceonly | --testing | --nofreepbx | --noasterisk | --dahdi-only

WRAP_LOG="/root/freepbx-wrapper.log"

### === ПРОВЕРКИ ОКРУЖЕНИЯ ===
if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт от root" >&2
  exit 1
fi

if ! grep -q 'ID=debian' /etc/os-release || ! grep -q 'VERSION_ID="12' /etc/os-release; then
  echo "Этот инсталлятор рассчитан на Debian 12 (bookworm). Обнаружено:" | tee -a "$WRAP_LOG"
  cat /etc/os-release | tee -a "$WRAP_LOG"
  exit 1
fi

echo "==> Старт установки FreePBX 17 на Debian 12" | tee -a "$WRAP_LOG"
date | tee -a "$WRAP_LOG"

### === ОБНОВЛЕНИЕ ОС ===
export DEBIAN_FRONTEND=noninteractive
apt-get update -y        >>"$WRAP_LOG" 2>&1
apt-get full-upgrade -y  >>"$WRAP_LOG" 2>&1
apt-get install -y curl wget ca-certificates gnupg lsb-release \
  net-tools iproute2 htop logrotate tzdata >>"$WRAP_LOG" 2>&1

### === ЧАСОВОЙ ПОЯС ===
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone "$TIMEZONE"   >>"$WRAP_LOG" 2>&1 || true
fi

### === УСТАНОВКА FREEPBX 17 (ОФИЦИАЛЬНЫЙ СКРИПТ) ===
# Источник: https://github.com/FreePBX/sng_freepbx_debian_install
cd /tmp
wget -q https://github.com/FreePBX/sng_freepbx_debian_install/raw/master/sng_freepbx_debian_install.sh -O /tmp/sng_freepbx_debian_install.sh
chmod +x /tmp/sng_freepbx_debian_install.sh

ARGS=""
if [[ "$INSTALL_DAHDI" == "yes" ]]; then
  ARGS+=" --dahdi"
fi
# Доп. флаги, если заданы
if [[ -n "$EXTRA_ARGS" ]]; then
  ARGS+=" ${EXTRA_ARGS}"
fi

echo "==> Запускаю официальный установщик FreePBX 17 с аргументами: ${ARGS}" | tee -a "$WRAP_LOG"
bash /tmp/sng_freepbx_debian_install.sh ${ARGS} | tee -a "$WRAP_LOG"

### === ПОСТ-НАСТРОЙКИ ===
# Включим автозапуск ключевых служб (обычно уже активны после скрипта)
systemctl enable --now asterisk apache2 mariadb  >>"$WRAP_LOG" 2>&1 || true

# Fail2Ban обычно устанавливается официальным скриптом; просто убедимся, что он активен
if systemctl list-unit-files | grep -q fail2ban.service; then
  systemctl enable --now fail2ban >>"$WRAP_LOG" 2>&1 || true
fi

# Не включаем UFW по умолчанию, чтобы не конфликтовать с FreePBX Firewall.
# Если все же нужно - открываем SIP/RTP/HTTP(S)/UCP и включаем.
if [[ "$ENABLE_UFW" == "yes" ]]; then
  apt-get install -y ufw >>"$WRAP_LOG" 2>&1
  ufw allow OpenSSH
  ufw allow 80,443/tcp
  ufw allow 5060/udp
  ufw allow 5060/tcp
  ufw allow 5061/tcp             # SIP TLS, если понадобится
  ufw allow 10000:20000/udp      # RTP диапазон Asterisk
  ufw allow 8001,8003/tcp        # UCP (веб-клиент/виджеты)
  yes | ufw enable
fi

### === ВЫВОД ПОДСКАЗОК ===
IPV4="$(hostname -I | awk '{print $1}')"
echo
echo "==> Установка завершена."
echo "Открой в браузере:  http://${IPV4}/admin"
echo "При первом входе FreePBX предложит создать Admin-пользователя."
echo
echo "Полезные проверки:"
echo "  asterisk -rx 'core show version'     # версия Asterisk"
echo "  fwconsole --version                  # версия FreePBX"
echo "  asterisk -rx 'module show like chan' # убедиться, что chan_sip отсутствует, используем PJSIP"
echo "  asterisk -rx 'pjsip show endpoints'  # после добавления расширений"
echo
echo "Логи установки FreePBX: /var/log/pbx/freepbx17-install-<timestamp>.log"
echo "Лог обвязки:            $WRAP_LOG"
