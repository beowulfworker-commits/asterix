#!/usr/bin/env bash
# РФ-локализация FreePBX/Asterisk (Debian 12 + FreePBX 17)
# Делает: часовой пояс, NTP через chrony (ru.pool.ntp.org), российские тоны,
# русские системные звуки Asterisk, NAT-автонастройку для PJSIP-транспорта.
# Логи: /root/ru-localize.log

set -euo pipefail

LOG="/root/ru-localize.log"
TZ="${TZ:-Europe/Moscow}"              # Измени при необходимости (например, Asia/Yekaterinburg)
USE_RU_LOCALE="${USE_RU_LOCALE:-no}"   # yes => системная локаль ru_RU.UTF-8

echo "==> РФ-локализация FreePBX/Asterisk" | tee -a "$LOG"

# --- Проверки окружения ---
if ! grep -q 'ID=debian' /etc/os-release || ! grep -q 'VERSION_ID="12' /etc/os-release; then
  echo "Скрипт рассчитан на Debian 12 (bookworm). Прерываю." | tee -a "$LOG"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >>"$LOG" 2>&1
apt-get install -y dnsutils curl ca-certificates >>"$LOG" 2>&1

# --- Часовой пояс и NTP: chrony ---
echo "==> Настройка таймзоны и NTP (chrony)..." | tee -a "$LOG"
timedatectl set-timezone "$TZ" >>"$LOG" 2>&1 || true
apt-get install -y chrony >>"$LOG" 2>&1

# Подменим пул в /etc/chrony/chrony.conf на российский
if grep -qE '^\s*pool\s+' /etc/chrony/chrony.conf; then
  sed -ri 's|^\s*pool\s+.*|pool ru.pool.ntp.org iburst|' /etc/chrony/chrony.conf
else
  echo "pool ru.pool.ntp.org iburst" >> /etc/chrony/chrony.conf
fi
systemctl enable --now chrony >>"$LOG" 2>&1 || true

# --- Системная локаль (опционально) ---
if [[ "$USE_RU_LOCALE" == "yes" ]]; then
  echo "==> Устанавливаю системную локаль ru_RU.UTF-8..." | tee -a "$LOG"
  apt-get install -y locales >>"$LOG" 2>&1
  sed -ri 's/^# ?(ru_RU\.UTF-8 UTF-8)/\1/' /etc/locale.gen
  locale-gen ru_RU.UTF-8 >>"$LOG" 2>&1
  update-locale LANG=ru_RU.UTF-8 >>"$LOG" 2>&1
fi

# --- Российские тоновые индикации ---
echo "==> Включаю российские тоновые индикации (indications.conf)..." | tee -a "$LOG"
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

# --- Русские системные звуки Asterisk ---
echo "==> Устанавливаю русские звуки Asterisk (core sounds)..." | tee -a "$LOG"
apt-get install -y asterisk-core-sounds-ru asterisk-core-sounds-ru-wav \
                    asterisk-core-sounds-ru-gsm asterisk-core-sounds-ru-g722 >>"$LOG" 2>&1 || true

# --- NAT/внешний IP для транспорта PJSIP ---
echo "==> Настраиваю NAT для PJSIP-транспорта..." | tee -a "$LOG"
PUBIP="$(dig +short myip.opendns.com @resolver1.opendns.com || true)"
[[ -z "$PUBIP" ]] && PUBIP="$(curl -4 -s https://ifconfig.co || true)"
[[ -z "$PUBIP" ]] && PUBIP="$(curl -4 -s https://icanhazip.com || true)"

PJ_CUSTOM="/etc/asterisk/pjsip.transports_custom_post.conf"
if [[ -n "$PUBIP" ]]; then
  cat > "$PJ_CUSTOM" <<EOF
[0.0.0.0-udp](+type=transport)
external_signaling_address=$PUBIP
external_media_address=$PUBIP
allow_reload=yes
EOF
  chown asterisk:asterisk "$PJ_CUSTOM" || true
  echo "   Внешний IP определён как: $PUBIP" | tee -a "$LOG"
else
  echo "   Не удалось определить внешний IP автоматически. Укажи его в GUI: Settings -> Asterisk SIP Settings." | tee -a "$LOG"
fi

# --- Перечитка конфигурации Asterisk ---
echo "==> Перечитываю конфигурацию..." | tee -a "$LOG"
systemctl restart asterisk >>"$LOG" 2>&1 || true
if command -v fwconsole >/dev/null 2>&1; then
  fwconsole reload >>"$LOG" 2>&1 || true
fi

# --- Итог ---
echo "==> Готово. Полезные проверки:" | tee -a "$LOG"
echo "    timedatectl status"
echo "    chronyc tracking && chronyc sources -v"
echo "    asterisk -rx 'core show settings' | grep -i country"
echo "    asterisk -rx 'pjsip show transports'"
