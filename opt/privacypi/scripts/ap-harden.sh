#!/usr/bin/env bash
# Harden the WiFi AP: enable WPA3-SAE (transition mode), 802.11w (Management
# Frame Protection — anti-deauth), and AP-isolation (no lateral movement
# between WiFi clients).
#
# Note: rtl8192cu (and most cheap dongles) only support WPA2. This script
# probes capability and applies the strongest config the radio supports.
#
# Usage:
#   ap-harden.sh probe    # JSON of what's possible
#   ap-harden.sh apply    # apply maximum hardening this radio supports
#   ap-harden.sh status   # JSON of current state
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh
ACTION="${1:-status}"
HOSTAPD_CONF=/etc/hostapd/hostapd.conf

probe() {
  IFC=$(awk -F= '/^interface=/{print $2; exit}' "$HOSTAPD_CONF" 2>/dev/null || echo "$AP_IFACE")
  PHY=$(iw dev "$IFC" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
  if [[ -z "$PHY" ]]; then
    echo '{"error":"interface not found"}'
    return 1
  fi
  WPA3_OK="false"; MFP_OK="false"
  if iw phy "$PHY" info 2>/dev/null | grep -q "SAE"; then WPA3_OK="true"; fi
  if iw phy "$PHY" info 2>/dev/null | grep -q "MFP"; then MFP_OK="true"; fi
  echo "{\"phy\":\"$PHY\",\"interface\":\"$IFC\",\"wpa3_sae\":$WPA3_OK,\"mfp_802_11w\":$MFP_OK}"
}

apply() {
  cp "$HOSTAPD_CONF" "${HOSTAPD_CONF}.bak.$(date +%s)"
  CAP=$(probe)
  WPA3=$(echo "$CAP" | python3 -c "import json,sys; v=json.load(sys.stdin).get('wpa3_sae',False); print('true' if v is True else 'false')")
  MFP=$(echo "$CAP" | python3 -c "import json,sys; v=json.load(sys.stdin).get('mfp_802_11w',False); print('true' if v is True else 'false')")

  # Always: AP isolation (already a privacy win even on WPA2)
  if grep -q "^ap_isolate=" "$HOSTAPD_CONF"; then
    sed -i 's/^ap_isolate=.*/ap_isolate=1/' "$HOSTAPD_CONF"
  else
    echo "ap_isolate=1" >> "$HOSTAPD_CONF"
  fi

  # 802.11w MFP
  if [[ "$MFP" == "true" ]]; then
    if grep -q "^ieee80211w=" "$HOSTAPD_CONF"; then
      sed -i 's/^ieee80211w=.*/ieee80211w=2/' "$HOSTAPD_CONF"
    else
      echo "ieee80211w=2" >> "$HOSTAPD_CONF"
    fi
  fi

  # WPA3 SAE (transition mode = WPA2/WPA3 mixed for backward compat)
  if [[ "$WPA3" == "true" ]]; then
    sed -i 's/^wpa_key_mgmt=.*/wpa_key_mgmt=WPA-PSK SAE/' "$HOSTAPD_CONF"
    sed -i 's/^wpa=.*/wpa=2/' "$HOSTAPD_CONF"
    grep -q "^sae_require_mfp=" "$HOSTAPD_CONF" \
      || echo "sae_require_mfp=1" >> "$HOSTAPD_CONF"
  fi

  systemctl restart hostapd 2>&1 | tail -3
  sleep 2
  RUNNING=$(systemctl is-active hostapd)
  echo "{\"ok\":true,\"ap_isolate\":1,\"mfp\":$MFP,\"sae\":$WPA3,\"hostapd\":\"$RUNNING\"}"
}

status() {
  AP_ISO=$(awk -F= '/^ap_isolate=/{print $2; exit}' "$HOSTAPD_CONF" 2>/dev/null || echo "0")
  MFP=$(awk -F= '/^ieee80211w=/{print $2; exit}' "$HOSTAPD_CONF" 2>/dev/null || echo "0")
  KMG=$(awk -F= '/^wpa_key_mgmt=/{print $2; exit}' "$HOSTAPD_CONF" 2>/dev/null)
  echo "{\"ap_isolate\":\"$AP_ISO\",\"ieee80211w\":\"$MFP\",\"key_mgmt\":\"$KMG\"}"
}

case "$ACTION" in
  probe) probe ;;
  apply) apply ;;
  status) status ;;
  *) echo '{"ok":false}'; exit 2 ;;
esac
