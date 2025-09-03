#!/usr/bin/env bash
# Локализация FreePBX/Asterisk под РФ (Debian 12 + FreePBX 17)
# Делает: таймзону, NTP RU, русские тоны, русские звуки, NAT-автоопределение для PJSIP-транспорта.
# Ничего не ломает в GUI FreePBX. Повторный запуск безопасен.

set -euo pipefail
LOG="/root/ru-localize.log"
TZ="${TZ:-Europe/Moscow}"              # Можно изменить (напр. Asia/Yekaterinburg)
USE_RU_LOCALE="${USE_RU_LOCALE:-no}"   # yes => установить системную локаль ru_RU.UTF-8
DNSUTILS_PKG="dnsutils"                # в bookworm это пакет bind9-dnsutils

echo "==> РФ-локализация FreePBX/Asterisk" | tee -a "$LOG"
grep -q 'VERSION_ID="12' /etc/os-release || { echo "Требуется Debian 12 (bookworm)"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >>"$LOG" 2>&1
apt-get install -y $DNSUTILS_PKG curl ca-certificates >>"$LOG" 2>&1

### 1) Таймзона и NTP (ru.pool.ntp.org)
echo "==> Настройка таймзоны и NTP (chrony)..." | tee -a "$LOG"
timedatectl set-timezone "$TZ" >>"$LOG" 2>&1 || true

apt-get install -y chrony >>"$LOG" 2>&1
sed -ri 's|^pool .*|pool ru.pool.ntp.org iburst|' /etc/chrony/chrony.conf
systemctl enable --now chrony

### 2) Системная локаль (опционально ru_RU.UTF-8)
if [[ "$USE_RU_LOCALE" == "yes" ]]; then
  echo "==> Устанавливаю локаль ru_RU.UTF-8..." | tee -a "$LOG"
  apt-get install -y locales >>"$LOG" 2>&1
  sed -ri 's/^# ?(ru_RU\.UTF-8 UTF-8)/\1/' /etc/locale.gen
  locale-gen ru_RU.UTF-8 >>"$LOG" 2>&1
  update-locale LANG=ru_RU.UTF-8 >>"$LOG" 2>&1
fi

### 3) Русские тоны вызова (indications.conf)
echo "==> Включаю российские тоновые индикации..." | tee -a "$LOG"
INC="/etc/asterisk/indications.conf"
if [[ -f "$INC" ]]; then
  if grep -q '^country=' "$INC"; then
    sed -ri 's/^country=.*/country=ru/' "$INC"
  else
    sed -i '1i [general]\ncountry=ru\n' "$INC"
  fi
else
  cat > "$INC" <<'EOF'
[general]
country=ru
EOF
fi
# Примечание: country=ru включает встроенные параметры тонов для РФ.

### 4) Русские звуковые пакеты Asterisk (core sounds)
echo "==> Ставлю русские звуки Asterisk (core sounds)..." | tee -a "$LOG"
apt-get install -y asterisk-core-sounds-ru asterisk-core-sounds-ru-wav asterisk-core-sounds-ru-gsm asterisk-core-sounds-ru-g722 >>"$LOG" 2>&1 || true
# В Debian доступны ru-пакеты в нескольких кодеках; ставим самые полезные.

### 5) NAT/внешний адрес для PJSIP-транспорта (0.0.0.0-udp)
echo "==> Настраиваю NAT для PJSIP-транспорта..." | tee -a "$LOG"
PUBIP="$(dig +short myip.opendns.com @resolver1.opendns.com || true)"
[[ -z "$PUBIP" ]] && PUBIP="$(curl -4 -s https://ifconfig.co || true)"
[[ -z "$PUBIP" ]] && PUBIP="$(curl -4 -s https://icanhazip.com || true)"
if [[ -n "$PUBIP" ]]; then
  PJ_CUSTOM="/etc/asterisk/pjsip.transports_custom_post.conf"
  # Дополняем сессию транспорта, созданную FreePBX, значениями внешнего адреса
  cat > "$PJ_CUSTOM" <<EOF
[0.0.0.0-udp](+type=transport)
external_signaling_address=$PUBIP
external_media_address=$PUBIP
allow_reload=yes
EOF
  chown asterisk:asterisk "$PJ_CUSTOM" || true
  echo "   Внешний IP определён как: $PUBIP" | tee -a "$LOG"
else
  echo "   Не удалось автоматически определить внешний IP. Укажи его в GUI: Settings -> Asterisk SIP Settings." | tee -a "$LOG"
fi

### 6) Перезапуск/перечитка
echo "==> Перечитываю конфигурацию..." | tee -a "$LOG"
systemctl restart asterisk || true
if command -v fwconsole >/dev/null 2>&1; then
  fwconsole reload >>"$LOG" 2>&1 || true
fi

echo "==> Готово. Проверь:"
echo "    asterisk -rx 'core show settings' | grep -i country"
echo "    asterisk -rx 'pjsip show transports'"
