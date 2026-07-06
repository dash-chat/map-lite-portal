# One-time first-boot script, applied by `just netinstall` via
# `netinstall-cli -sm`. It runs once, locally, on the freshly flashed device —
# before anything is reachable over the network — so it sidesteps the
# expired-sticker-password problem entirely: the device comes up as a known AP
# with a known admin password, and ssh works immediately afterwards.
#
# Rendered from devices/<device>.conf (@PLACEHOLDER@ values). The stock mAP
# lite default configuration (netinstall -r) already builds the bridge, LAN
# address 192.168.88.1, DHCP server and wlan1 AP; this only overlays our
# credentials on top.

:delay 5s

# known admin password (also clears the factory "password expired" flag)
/user set [find where name="admin"] password="@ADMIN_PASSWORD@"

# wifi: WPA2 with our key, or an open network when the key is empty
:if ([:len "@WIFI_KEY@"] > 0) do={
  /interface wireless security-profiles set [find default=yes] \
    mode=dynamic-keys authentication-types=wpa2-psk \
    unicast-ciphers=aes-ccm group-ciphers=aes-ccm \
    wpa2-pre-shared-key="@WIFI_KEY@"
} else={
  /interface wireless security-profiles set [find default=yes] mode=none
}
/interface wireless set [find default-name="wlan1"] ssid="@SSID@" disabled=no

:log info "map-lite-portal: first-boot credentials applied"
