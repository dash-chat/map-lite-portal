# Captive portal setup for a MikroTik mAP lite.
# Template rendered by scripts/provision.sh (@PLACEHOLDER@ values) and
# imported on the router with /import. Idempotent: safe to re-import.

:local routerIp "@ROUTER_IP@"
:local hostMac "@HOST_MAC@"

# Find the LAN interface: the one that owns the router's address.
:local lanIf ""
:foreach id in=[/ip address find] do={
  :local addr [/ip address get $id address]
  :if ([:pick $addr 0 [:find $addr "/"]] = $routerIp) do={
    :set lanIf [/ip address get $id interface]
  }
}
:if ([:len $lanIf] = 0) do={
  :error ("map-lite-portal: no interface owns address " . $routerIp)
}
:put ("map-lite-portal: LAN interface is " . $lanIf)

# Bypass the provisioning host so the hotspot never cuts our management
# session (also means this host never sees the portal — remove the binding
# to test the portal from it).
:if ([:len [/ip hotspot ip-binding find where comment="map-lite-portal:host-bypass"]] = 0) do={
  /ip hotspot ip-binding add mac-address=$hostMac type=bypassed comment="map-lite-portal:host-bypass"
} else={
  /ip hotspot ip-binding set [find where comment="map-lite-portal:host-bypass"] mac-address=$hostMac
}

# Hotspot profile: serve our pages from flash/portal, log users in through
# the passwordless "trial" method (the Connect button on login.html).
# trial-uptime-limit=0s means the trial session is unlimited.
:if ([:len [/ip hotspot profile find where name="map-lite-portal"]] = 0) do={
  /ip hotspot profile add name="map-lite-portal"
}
/ip hotspot profile set [find where name="map-lite-portal"] \
  hotspot-address=[:toip $routerIp] \
  html-directory="flash/portal" \
  login-by=http-chap,cookie,trial \
  trial-uptime-limit=0s \
  trial-user-profile=default \
  http-cookie-lifetime=3d

# Hotspot server on the LAN interface. Clients keep getting addresses from
# the existing DHCP server; the hotspot only intercepts unauthenticated
# traffic and redirects it to the portal.
:if ([:len [/ip hotspot find where name="map-lite-portal"]] = 0) do={
  /ip hotspot add name="map-lite-portal" interface=$lanIf profile="map-lite-portal"
}
/ip hotspot set [find where name="map-lite-portal"] interface=$lanIf profile="map-lite-portal" disabled=no

:put "map-lite-portal: hotspot configured"
