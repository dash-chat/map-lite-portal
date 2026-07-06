# Tooling for the mAP lite captive portal. Run `just` for this list.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Optional knob, override like: `just router_ip=10.0.0.1 provision`
router_ip := ""

# Every device has its own host key and the link is local, so don't pin them.
# RouterOS (< 7.9) only offers an ssh-rsa (SHA-1) host key and SHA-1 DH kex,
# which OpenSSH >= 8.8 / 10.0 removed from its defaults — re-enable them or the
# handshake fails before the password is ever sent.
# ServerAlive*: changing the wifi credentials drops the link under an open ssh
# session; without keepalives that session hangs forever (ConnectTimeout only
# bounds connection setup), so make a dead link fail within ~6s instead.
ssh_opts := "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o ServerAliveInterval=2 -o ServerAliveCountMax=3 -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no -o HostKeyAlgorithms=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1"

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

# List your devices (devices/*.conf) and whether their network is in range
scan:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    files=(devices/*.conf)
    [ ${#files[@]} -gt 0 ] || { echo "error: no device files in devices/ — cp devices/example.conf.sample devices/<name>.conf and fill it in" >&2; exit 1; }
    nmcli radio wifi on
    visible=$(nmcli -t -f SSID device wifi list --rescan yes 2>/dev/null | sort -u)
    for f in "${files[@]}"; do
      ssid=""
      # shellcheck disable=SC1090
      source "$f"
      state="not in range"
      grep -Fxq "$ssid" <<< "$visible" && state="in range"
      printf '%-24s %-32s %s\n' "$(basename "$f" .conf)" "$ssid" "$state"
    done

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

# Takes a device name from devices/, or a raw admin password.
[doc("Build the portal and upload it to the router's flash/portal")]
upload device_or_password: build
    #!/usr/bin/env bash
    set -euo pipefail
    arg={{ quote(device_or_password) }}
    if [ -f "devices/$arg.conf" ]; then
      admin_password=""
      # shellcheck disable=SC1090
      source "devices/$arg.conf"
      pass="$admin_password"
    else
      pass="$arg"
    fi
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

# Open a RouterOS CLI on the device (device name from devices/, or a password)
cli device_or_password:
    #!/usr/bin/env bash
    set -euo pipefail
    arg={{ quote(device_or_password) }}
    if [ -f "devices/$arg.conf" ]; then
      admin_password=""
      # shellcheck disable=SC1090
      source "devices/$arg.conf"
      pass="$admin_password"
    else
      pass="$arg"
    fi
    ip={{ quote(router_ip) }}
    sshpass -p "$pass" ssh {{ ssh_opts }} "admin@${ip:-192.168.88.1}"

# Reflash a mAP lite over ETHERNET with a clean RouterOS + your credentials
# baked in, then push the portal. Unlike `provision` this needs no wifi and no
# working password up front: it sidesteps the expired-sticker-password problem
# by setting the admin password locally on first boot. Reads the DESIRED end
# state (ssid / wifi_key / admin_password) from devices/<device>.conf.
[doc("Flash a mAP lite over ethernet with baked-in credentials, then set up the portal")]
netinstall device routeros_version="7.23.1":
    #!/usr/bin/env bash
    set -euo pipefail
    device={{ quote(device) }}
    ver={{ quote(routeros_version) }}
    just={{ quote(just_executable()) }}

    log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
    warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
    die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
    # escape a value for a double-quoted RouterOS string, then for a sed RHS
    ros_quote() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g'; }
    sed_rhs()   { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

    command -v netinstall-cli >/dev/null || die "netinstall-cli not found — it ships in this project's devShell on x86_64-linux; run inside 'nix develop'"
    command -v nmcli >/dev/null || die "nmcli not found (NetworkManager is required)"

    # 1. desired end-state credentials
    conf="devices/$device.conf"
    [ -f "$conf" ] || die "no $conf — cp devices/example.conf.sample $conf and fill in the DESIRED ssid/wifi_key/admin_password"
    ssid=""; wifi_key=""; admin_password=""
    # shellcheck disable=SC1090
    source "$conf"
    [ -n "$ssid" ] || die "$conf sets no ssid"
    [ -n "$admin_password" ] || die "$conf sets an empty admin_password — netinstall needs a real one so ssh works afterwards"
    if [ -n "$wifi_key" ] && { [ ${#wifi_key} -lt 8 ] || [ ${#wifi_key} -gt 63 ]; }; then
      die "wifi_key must be 8-63 characters (WPA2 requirement), got ${#wifi_key}"
    fi

    # 2. RouterOS package for the mAP lite (mipsbe / QCA9533), cached
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/map-lite-portal"
    mkdir -p "$cache"
    npk="$cache/routeros-$ver-mipsbe.npk"
    if [ ! -s "$npk" ]; then
      url="https://download.mikrotik.com/routeros/$ver/routeros-$ver-mipsbe.npk"
      log "Downloading RouterOS $ver (mipsbe)"
      curl -fSL -o "$npk.part" "$url" || die "download failed: $url"
      mv "$npk.part" "$npk"
    fi
    log "RouterOS package: $npk"

    # 3. render the one-time first-boot credential script
    rsc=$(mktemp -t netinstall-firstboot.XXXXXX.rsc)
    sub() { sed_rhs "$(ros_quote "$1")"; }
    sed -e "s|@ADMIN_PASSWORD@|$(sub "$admin_password")|g" \
        -e "s|@WIFI_KEY@|$(sub "$wifi_key")|g" \
        -e "s|@SSID@|$(sub "$ssid")|g" \
        router/netinstall-firstboot.rsc.tpl > "$rsc"

    # 4. ethernet link (host .2, device gets .3 while flashing, .1 after boot)
    eth=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "ethernet" && $1 !~ /vboxnet|docker/ { print $1; exit }')
    [ -n "$eth" ] || die "no ethernet interface found — plug the device in over ethernet"
    host_ip=192.168.88.2
    dev_ip=192.168.88.3
    router_ip=192.168.88.1

    restore_net() { nmcli connection down map-netinstall >/dev/null 2>&1 || true; nmcli connection delete map-netinstall >/dev/null 2>&1 || true; }
    trap 'rm -f "$rsc"; restore_net' EXIT

    # 5. physical step: connect ethernet and enter etherboot mode
    cat <<EOF

    Flashing '$device' ($ssid) over ethernet interface '$eth'.

      1. Connect the mAP lite's ethernet port to this computer.
      2. Put it into etherboot mode: unplug power, hold the RESET button,
         re-apply power while holding RESET, and keep holding until the USR
         LED finishes blinking, goes solid, then turns OFF — release then.

    EOF
    read -rp "Press Enter once the device is connected and in etherboot mode... " _

    log "Assigning $host_ip/24 to $eth"
    nmcli connection delete map-netinstall >/dev/null 2>&1 || true
    nmcli connection add type ethernet ifname "$eth" con-name map-netinstall ipv4.method manual ipv4.addresses "$host_ip/24" >/dev/null
    nmcli connection up map-netinstall >/dev/null
    ip route show default | grep -q . || warn "no default route present — netinstall-cli can report 'FAILED TO REPLY'; keep wifi connected during the flash"

    # 6. flash (-r stock defconf builds the AP; -sm overlays our credentials)
    ni=$(command -v netinstall-cli)
    log "Flashing RouterOS (needs sudo) — do NOT unplug until it finishes"
    sudo "$ni" -r -sm "$rsc" -a "$dev_ip" -i "$eth" "$npk" \
      || die "netinstall failed — is the device in etherboot mode on $eth? Manual run: sudo $ni -r -sm $rsc -a $dev_ip -i $eth $npk"
    restore_net
    trap 'rm -f "$rsc"' EXIT

    # 7. finish over WIFI with the just-baked credentials. The device reboots
    #    into the stock default config, whose ethernet port may be a WAN port
    #    rather than the 192.168.88.1 LAN, so don't rely on the cable here.
    log "Flashed. Waiting ~1 min for the device to reboot, then joining '$ssid'"
    sleep 20
    "$just" connect "$ssid" "$wifi_key"
    wifi_dev=$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '$2 == "wifi" && $3 == "connected" { print $1; exit }')
    [ -n "$wifi_dev" ] || die "joined '$ssid' but no wifi device reports as connected"
    router_ip=$(nmcli -g IP4.GATEWAY device show "$wifi_dev" | head -n1)
    [ -n "$router_ip" ] || router_ip="192.168.88.1"
    for _ in $(seq 1 30); do ping -c 1 -W 1 "$router_ip" >/dev/null 2>&1 && break; sleep 2; done

    # 8. verify ssh with the baked password
    ros() { sshpass -p "$admin_password" ssh {{ ssh_opts }} "admin@$router_ip" "$1" | tr -d '\r'; }
    ok=""
    for _ in $(seq 1 30); do ros ':put ok' >/dev/null 2>&1 && { ok=1; break; }; sleep 2; done
    [ -n "$ok" ] || die "flashed, but not reachable over ssh at $router_ip yet — wait a moment, then finish with: just provision $ssid $wifi_key $admin_password"
    log "ssh works with the baked admin password"

    # 9. push the portal and configure the hotspot
    host_iface=$(ip -o route get "$router_ip" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    host_mac=$(tr 'a-f' 'A-F' < "/sys/class/net/$host_iface/address")
    "$just" router_ip="$router_ip" upload "$admin_password"
    log "Configuring hotspot"
    setup=$(mktemp -t portal-setup.XXXXXX.rsc)
    sed -e "s|@ROUTER_IP@|$router_ip|g" -e "s|@HOST_MAC@|$host_mac|g" router/portal-setup.rsc.tpl > "$setup"
    sshpass -p "$admin_password" scp {{ ssh_opts }} -q "$setup" "admin@$router_ip:/portal-setup.rsc"
    rm -f "$setup"
    import_out=$(ros '/import file-name=portal-setup.rsc')
    printf '%s\n' "$import_out" | sed 's/^/    /'
    printf '%s' "$import_out" | grep -q 'executed successfully' || die "hotspot setup script failed"
    count=$(ros ':put [:len [/ip hotspot find where name="map-lite-portal" and disabled=no]]')
    [ "$count" = 1 ] || die "hotspot server 'map-lite-portal' is not active"

    log "Done. '$device' is flashed and serving the captive portal."
    cat <<EOF

        SSID:            $ssid
        Router address:  $router_ip

        Connect a device to '$ssid' to see the portal. This machine
        ($host_mac) is bypassed for management access — remove the
        'map-lite-portal:host-bypass' ip-binding to test the portal from it.

        To iterate on the webapp: edit portal/ and re-run 'just upload $device'.
    EOF

# Scans for the networks of the devices in devices/*.conf, lets you pick one,
# asks for the target credentials (pass them as arguments to skip the
# prompts), provisions it, then updates its devices/ file:
#   just provision [target_ssid] [target_wifi_key] [target_admin_password]
[doc("Pick an in-range device from devices/ and turn it into a captive portal")]
provision target_ssid="" target_wifi_key="__ask__" target_admin_password="__ask__":
    #!/usr/bin/env bash
    set -euo pipefail
    target_ssid={{ quote(target_ssid) }}
    target_wifi_key={{ quote(target_wifi_key) }}
    target_admin_password={{ quote(target_admin_password) }}
    router_ip={{ quote(router_ip) }}
    just={{ quote(just_executable()) }}

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

    # on failure, get back on the wifi we came from instead of leaving the
    # machine stranded on the device's network without internet
    rsc=""
    prev_wifi=""
    cleanup() {
      status=$?
      [ -n "$rsc" ] && rm -f "$rsc"
      if [ "$status" -ne 0 ] && [ -n "$prev_wifi" ]; then
        warn "reconnecting to '$prev_wifi'"
        nmcli connection up "$prev_wifi" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup EXIT

    # 1. find which of the configured devices are in range
    command -v nmcli >/dev/null || die "nmcli not found (NetworkManager is required)"
    shopt -s nullglob
    files=(devices/*.conf)
    [ ${#files[@]} -gt 0 ] || die "no device files in devices/ — cp devices/example.conf.sample devices/<name>.conf and fill it in"
    log "Scanning for the networks of ${#files[@]} configured device(s)"
    nmcli radio wifi on
    up_files=()
    up_labels=()
    for _ in $(seq 1 5); do
      visible=$(nmcli -t -f SSID device wifi list --rescan yes 2>/dev/null | sort -u)
      up_files=()
      up_labels=()
      for f in "${files[@]}"; do
        ssid=""
        # shellcheck disable=SC1090
        source "$f"
        [ -n "$ssid" ] || { warn "$f sets no ssid — skipping"; continue; }
        if grep -Fxq "$ssid" <<< "$visible"; then
          up_files+=("$f")
          up_labels+=("$(basename "$f" .conf)  (SSID '$ssid')")
        fi
      done
      [ ${#up_files[@]} -gt 0 ] && break
      sleep 2
    done
    [ ${#up_files[@]} -gt 0 ] || die "none of the configured devices' networks are in range"

    # 2. pick the device
    if [ ${#up_files[@]} -eq 1 ]; then
      device_file="${up_files[0]}"
      log "In range: ${up_labels[0]}"
    else
      echo "Devices in range:"
      label=""
      PS3="Provision which device? "
      select label in "${up_labels[@]}"; do
        [ -n "$label" ] && break
      done
      [ -n "$label" ] || die "no device chosen"
      device_file=""
      for i in "${!up_labels[@]}"; do
        [ "${up_labels[$i]}" = "$label" ] && device_file="${up_files[$i]}"
      done
    fi
    device_name=$(basename "$device_file" .conf)
    ssid=""
    wifi_key=""
    admin_password=""
    # shellcheck disable=SC1090
    source "$device_file"
    connect_ssid="$ssid"
    connect_wifi_key="$wifi_key"
    connect_admin_password="$admin_password"
    log "Provisioning '$device_name'"

    # 3. target credentials (prompted unless given as arguments)
    if [ -z "$target_ssid" ]; then
      read -rp "Target wifi SSID [$connect_ssid]: " target_ssid
      target_ssid=${target_ssid:-$connect_ssid}
    fi
    if [ "$target_wifi_key" = "__ask__" ]; then
      read -rp "Target wifi key (empty = keep current): " reply
      target_wifi_key=${reply:-$connect_wifi_key}
    fi
    if [ "$target_admin_password" = "__ask__" ]; then
      read -rsp "Target admin password (empty = keep current): " reply
      echo
      target_admin_password=${reply:-$connect_admin_password}
    fi
    if [ -n "$target_wifi_key" ] && { [ ${#target_wifi_key} -lt 8 ] || [ ${#target_wifi_key} -gt 63 ]; }; then
      die "target wifi key must be 8-63 characters (WPA2 requirement), got ${#target_wifi_key}"
    fi

    # 4. reach the device over its current wifi
    prev_wifi=$(nmcli -t -f NAME,TYPE connection show --active | awk -F: '$2 == "802-11-wireless" { print $1; exit }' || true)
    "$just" connect "$connect_ssid" "$connect_wifi_key"
    wifi_dev=$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '$2 == "wifi" && $3 == "connected" { print $1; exit }')
    [ -n "$wifi_dev" ] || die "connected to '$connect_ssid' but no wifi device reports as connected"
    if [ -z "$router_ip" ]; then
      router_ip=$(nmcli -g IP4.GATEWAY device show "$wifi_dev" | head -n1)
      [ -n "$router_ip" ] || router_ip="192.168.88.1"
    fi
    wait_for_router
    host_iface=$(ip -o route get "$router_ip" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    [ -n "$host_iface" ] || die "cannot determine which interface reaches $router_ip"
    host_mac=$(tr 'a-f' 'A-F' < "/sys/class/net/$host_iface/address")

    # 5. authenticate (stored password, then factory-default empty, then target)
    log "Logging in to RouterOS at $router_ip"
    authed=""
    auth_err=""
    for candidate in "$connect_admin_password" "" "$target_admin_password"; do
      ros_password="$candidate"
      if auth_err=$(ros ':put ok' 2>&1 >/dev/null); then authed=1; break; fi
    done
    if [ -z "$authed" ]; then
      # a message here means ssh itself failed (e.g. algorithm negotiation),
      # not a rejected password — sshpass reports a bad password silently
      [ -n "$auth_err" ] && printf '%s\n' "$auth_err" | sed 's/^/    /' >&2
      warn "factory-fresh device? The sticker password ships expired and can't be used over ssh. Best fix: reflash with 'just netinstall $device_name' (bakes in a working password over ethernet). Or do the first login by hand in WebFig at http://$router_ip and put the new password in $device_file."
      die "cannot log in as admin@$router_ip with the stored password (or the factory-default empty one)"
    fi
    model=$(ros ':put ([/system routerboard get model] . " / RouterOS " . [/system resource get version])' 2>/dev/null || echo "unknown")
    log "Connected to: $model"
    case "$model" in
      *mAP*) ;;
      *) warn "device does not report as a mAP — continuing anyway" ;;
    esac

    # 6. build and upload the portal webapp
    "$just" router_ip="$router_ip" upload "$ros_password"

    # 7. configure the hotspot
    log "Configuring hotspot"
    rsc=$(mktemp -t portal-setup.XXXXXX.rsc)
    sed -e "s|@ROUTER_IP@|$router_ip|g" -e "s|@HOST_MAC@|$host_mac|g" router/portal-setup.rsc.tpl > "$rsc"
    sshpass -p "$ros_password" scp {{ ssh_opts }} -q "$rsc" "admin@$router_ip:/portal-setup.rsc"
    import_out=$(ros '/import file-name=portal-setup.rsc')
    printf '%s\n' "$import_out" | sed 's/^/    /'
    printf '%s' "$import_out" | grep -q 'executed successfully' || die "hotspot setup script failed"

    # 8. ensure the target credentials (last, so a dropped wifi link can't
    #    interrupt the setup; password first, so a dropped link can't leave
    #    us locked out mid-way)
    if [ "$target_admin_password" != "$ros_password" ]; then
      log "Setting admin password"
      ros "/user set [find where name=\"admin\"] password=\"$(ros_quote "$target_admin_password")\""
      ros_password="$target_admin_password"
      ros ':put ok' >/dev/null || die "cannot log in with the new admin password"
    fi
    current_ssid=$(ros ':put [/interface wireless get [find default-name="wlan1"] ssid]')
    current_key=$(ros ':put [/interface wireless security-profiles get [find default=yes] wpa2-pre-shared-key]')
    if [ "$current_ssid" != "$target_ssid" ] || [ "$current_key" != "$target_wifi_key" ]; then
      log "Setting wifi credentials (SSID '$target_ssid') — the wifi link will drop"
      if [ -n "$target_wifi_key" ]; then
        security_cmd="/interface wireless security-profiles set [find default=yes] mode=dynamic-keys authentication-types=wpa2-psk unicast-ciphers=aes-ccm group-ciphers=aes-ccm wpa2-pre-shared-key=\"$(ros_quote "$target_wifi_key")\""
      else
        security_cmd="/interface wireless security-profiles set [find default=yes] mode=none"
      fi
      # single ssh invocation: the session may drop as soon as the key changes
      ros "$security_cmd; /interface wireless set [find default-name=\"wlan1\"] ssid=\"$(ros_quote "$target_ssid")\" disabled=no" || true
      sleep 3
      "$just" connect "$target_ssid" "$target_wifi_key"
      wait_for_router
    fi

    # 9. verify, and record the device's new credentials
    log "Verifying"
    ros ':put ok' >/dev/null || die "cannot log in after provisioning"
    count=$(ros ':put [:len [/ip hotspot find where name="map-lite-portal" and disabled=no]]')
    [ "$count" = 1 ] || die "hotspot server 'map-lite-portal' is not active"
    {
      printf '%s\n' '# updated by just provision'
      printf 'ssid=%q\n' "$target_ssid"
      printf 'wifi_key=%q\n' "$target_wifi_key"
      printf 'admin_password=%q\n' "$target_admin_password"
    } > "$device_file"
    log "Updated $device_file with the new credentials"

    log "Done. '$device_name' is now a captive portal."
    cat <<EOF

        SSID:            $target_ssid
        Router address:  $router_ip

        Connect another device to '$target_ssid' to see the portal. This
        machine ($host_mac) is bypassed so it keeps management access —
        remove the 'map-lite-portal:host-bypass' ip-binding on the router
        to test the portal from it.

        To iterate on the webapp: edit portal/ and re-run
        'just upload $device_name'.
    EOF
