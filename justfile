# Tooling for the mAP lite captive portal. Run `just` for this list.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Optional knobs, override like: `just router_ip=10.0.0.1 skip_wifi=1 provision ...`
router_ip := ""
skip_wifi := ""

# Every device has its own host key and the link is local, so don't pin them.
ssh_opts := "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no"

[private]
default:
    @just --list

# ---- portal webapp ----------------------------------------------------------

# Build the portal webapp into portal/dist
build:
    cd portal && { [ -d node_modules ] || pnpm install --silent; } && pnpm build

# Run the portal dev server (sample hotspot values are substituted)
dev:
    cd portal && pnpm dev

# Type-check the portal with svelte-check
check:
    cd portal && pnpm check

# Remove portal build artifacts and node_modules
clean:
    rm -rf portal/dist portal/node_modules

# ---- device tooling -----------------------------------------------------------

# Join a wifi network with NetworkManager (empty key = open network)
connect ssid wifi_key="":
    #!/usr/bin/env bash
    set -euo pipefail
    ssid={{ quote(ssid) }}
    key={{ quote(wifi_key) }}
    nmcli radio wifi on
    found=""
    for _ in $(seq 1 20); do
      if nmcli -t -f SSID device wifi list --rescan yes 2>/dev/null | grep -Fxq "$ssid"; then found=1; break; fi
      sleep 2
    done
    [ -n "$found" ] || { echo "error: wifi network '$ssid' not found — is the mAP lite powered on and in range?" >&2; exit 1; }
    # drop any stale profile so a previously stored key can't shadow the given one
    nmcli connection delete "$ssid" >/dev/null 2>&1 || true
    if [ -n "$key" ]; then
      nmcli device wifi connect "$ssid" password "$key" >/dev/null
    else
      nmcli device wifi connect "$ssid" >/dev/null
    fi
    echo "connected to '$ssid'"

# Build the portal and upload portal/dist to the router's flash/portal
upload admin_password: build
    #!/usr/bin/env bash
    set -euo pipefail
    pass={{ quote(admin_password) }}
    ip={{ quote(router_ip) }}
    ip="${ip:-192.168.88.1}"
    ros() { sshpass -p "$pass" ssh {{ ssh_opts }} "admin@$ip" "$1" | tr -d '\r'; }
    # '/file add' exists on recent RouterOS 7; fall back to sftp mkdir on older ones
    mkdir_remote() {
      ros "/file add type=directory name=\"$1\"" >/dev/null 2>&1 \
        || printf 'mkdir %s\n' "$1" | sshpass -p "$pass" sftp -b - {{ ssh_opts }} "admin@$ip" >/dev/null 2>&1 \
        || true
    }
    echo "uploading portal to flash/portal on $ip"
    mkdir_remote flash/portal
    sshpass -p "$pass" scp {{ ssh_opts }} -q portal/dist/*.html "admin@$ip:/flash/portal/"
    if [ -d portal/dist/assets ]; then
      mkdir_remote flash/portal/assets
      sshpass -p "$pass" scp {{ ssh_opts }} -q portal/dist/assets/* "admin@$ip:/flash/portal/assets/"
    fi
    uploaded=$(ros ':put [:len [/file find where name~"flash/portal/" and type!="directory"]]')
    expected=$(find portal/dist -type f | wc -l)
    [ "$uploaded" -ge "$expected" ] || { echo "error: upload verification failed: $uploaded/$expected files in flash/portal" >&2; exit 1; }
    echo "$uploaded files in flash/portal"

# Open a RouterOS CLI on the device
cli admin_password:
    ip={{ quote(router_ip) }}; sshpass -p {{ quote(admin_password) }} ssh {{ ssh_opts }} "admin@${ip:-192.168.88.1}"

# The device ends up with the given ssid / wifi key / admin password. When it
# currently has different credentials (e.g. factory-fresh), pass all three
# connect_* values for how to reach it now:
#   just provision dash-portal secret123 pass MikroTik-ABCDEF '' ''
[doc("Turn a powered-on mAP lite (wifi in range) into a captive portal")]
provision ssid wifi_key admin_password connect_ssid="" connect_wifi_key="" connect_admin_password="":
    #!/usr/bin/env bash
    set -euo pipefail
    ssid={{ quote(ssid) }}
    wifi_key={{ quote(wifi_key) }}
    admin_password={{ quote(admin_password) }}
    connect_ssid={{ quote(connect_ssid) }}
    connect_wifi_key={{ quote(connect_wifi_key) }}
    connect_admin_password={{ quote(connect_admin_password) }}
    router_ip={{ quote(router_ip) }}
    skip_wifi={{ quote(skip_wifi) }}
    just={{ quote(just_executable()) }}
    if [ -z "$connect_ssid" ]; then
      connect_ssid="$ssid"
      connect_wifi_key="$wifi_key"
      connect_admin_password="$admin_password"
    fi

    log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
    warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
    die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
    ros() { sshpass -p "$ros_password" ssh {{ ssh_opts }} "admin@$router_ip" "$1" | tr -d '\r'; }
    # escape a value for use inside a double-quoted RouterOS string
    ros_quote() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g'; }
    wait_for_router() {
      log "Waiting for $router_ip to respond"
      for _ in $(seq 1 30); do
        if ping -c 1 -W 1 "$router_ip" >/dev/null 2>&1; then return 0; fi
        sleep 1
      done
      die "$router_ip is not responding"
    }

    # 1. reach the device over wifi
    if [ -z "$skip_wifi" ]; then
      command -v nmcli >/dev/null || die "nmcli not found (NetworkManager is required, or set skip_wifi=1)"
      "$just" connect "$connect_ssid" "$connect_wifi_key"
      wifi_dev=$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '$2 == "wifi" && $3 == "connected" { print $1; exit }')
      [ -n "$wifi_dev" ] || die "connected to '$connect_ssid' but no wifi device reports as connected"
      if [ -z "$router_ip" ]; then
        router_ip=$(nmcli -g IP4.GATEWAY device show "$wifi_dev" | head -n1)
        [ -n "$router_ip" ] || router_ip="192.168.88.1"
      fi
    else
      [ -n "$router_ip" ] || router_ip="192.168.88.1"
    fi
    wait_for_router
    host_iface=$(ip -o route get "$router_ip" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    [ -n "$host_iface" ] || die "cannot determine which interface reaches $router_ip"
    host_mac=$(tr 'a-f' 'A-F' < "/sys/class/net/$host_iface/address")

    # 2. authenticate (given password, then factory-default empty, then target)
    log "Logging in to RouterOS at $router_ip"
    authed=""
    for candidate in "$connect_admin_password" "" "$admin_password"; do
      ros_password="$candidate"
      if ros ':put ok' >/dev/null 2>&1; then authed=1; break; fi
    done
    [ -n "$authed" ] || die "cannot log in as admin@$router_ip with the given password (or the factory-default empty one)"
    model=$(ros ':put ([/system routerboard get model] . " / RouterOS " . [/system resource get version])' 2>/dev/null || echo "unknown")
    log "Connected to: $model"
    case "$model" in
      *mAP*) ;;
      *) warn "device does not report as a mAP — continuing anyway" ;;
    esac

    # 3. build and upload the portal webapp
    "$just" router_ip="$router_ip" upload "$ros_password"

    # 4. configure the hotspot
    log "Configuring hotspot"
    rsc=$(mktemp -t portal-setup.XXXXXX.rsc)
    trap 'rm -f "$rsc"' EXIT
    sed -e "s|@ROUTER_IP@|$router_ip|g" -e "s|@HOST_MAC@|$host_mac|g" router/portal-setup.rsc.tpl > "$rsc"
    sshpass -p "$ros_password" scp {{ ssh_opts }} -q "$rsc" "admin@$router_ip:/portal-setup.rsc"
    import_out=$(ros '/import file-name=portal-setup.rsc')
    printf '%s\n' "$import_out" | sed 's/^/    /'
    printf '%s' "$import_out" | grep -q 'executed successfully' || die "hotspot setup script failed"

    # 5. ensure the target credentials (last, so a dropped wifi link can't
    #    interrupt the setup; password first, so a dropped link can't leave
    #    us locked out mid-way)
    if [ "$admin_password" != "$ros_password" ]; then
      log "Setting admin password"
      ros "/user set [find where name=\"admin\"] password=\"$(ros_quote "$admin_password")\""
      ros_password="$admin_password"
      ros ':put ok' >/dev/null || die "cannot log in with the new admin password"
    fi
    current_ssid=$(ros ':put [/interface wireless get [find default-name="wlan1"] ssid]')
    current_key=$(ros ':put [/interface wireless security-profiles get [find default=yes] wpa2-pre-shared-key]')
    if [ "$current_ssid" != "$ssid" ] || [ "$current_key" != "$wifi_key" ]; then
      log "Setting wifi credentials (SSID '$ssid') — the wifi link will drop"
      if [ -n "$wifi_key" ]; then
        security_cmd="/interface wireless security-profiles set [find default=yes] mode=dynamic-keys authentication-types=wpa2-psk unicast-ciphers=aes-ccm group-ciphers=aes-ccm wpa2-pre-shared-key=\"$(ros_quote "$wifi_key")\""
      else
        security_cmd="/interface wireless security-profiles set [find default=yes] mode=none"
      fi
      # single ssh invocation: the session may drop as soon as the key changes
      ros "$security_cmd; /interface wireless set [find default-name=\"wlan1\"] ssid=\"$(ros_quote "$ssid")\" disabled=no" || true
      if [ -z "$skip_wifi" ]; then
        sleep 3
        "$just" connect "$ssid" "$wifi_key"
        wait_for_router
      else
        warn "wifi credentials changed with skip_wifi set; reconnect to '$ssid' yourself"
      fi
    fi

    # 6. verify
    log "Verifying"
    ros ':put ok' >/dev/null || die "cannot log in after provisioning"
    count=$(ros ':put [:len [/ip hotspot find where name="map-lite-portal" and disabled=no]]')
    [ "$count" = 1 ] || die "hotspot server 'map-lite-portal' is not active"

    log "Done. The mAP lite is now a captive portal."
    cat <<EOF

        SSID:            $ssid
        Router address:  $router_ip

        Connect another device to '$ssid' to see the portal. This machine
        ($host_mac) is bypassed so it keeps management access — remove the
        'map-lite-portal:host-bypass' ip-binding on the router to test the
        portal from it.

        To iterate on the webapp: edit portal/ and re-run 'just upload'.
    EOF
