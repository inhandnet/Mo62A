#!/usr/bin/env bash
set -uo pipefail
# NOTE: intentionally NOT 'set -e' — each setting is applied independently so a
# single failure (e.g. Wi-Fi AP out of range) never aborts the remaining steps.

# MO-62A first-boot helper: read the user's settings from the BOOT (FAT32)
# partition and apply them, then delete the file so no password is left on the
# card. Friendly "key=value" format — see the file's own header for details.
#
# Invoked by mo-62a-firstboot-install.sh. Can be run standalone for testing:
#     mo-62a-auto-config.sh [/path/to/sysconfig.txt]

CONFIG_FILE="${1:-/boot/firmware/sysconfig.txt}"
LOG=/var/log/mo-62a-auto-config.log
HOSTNAME_FILE=/etc/hostname
HOSTS_FILE=/etc/hosts

log() { echo "[mo-62a-config] $*"; }

# Recognized keys (also used to wipe the file afterwards).
DEVICE_GROUPS="audio video render input plugdev netdev bluetooth dialout gpio i2c"
KNOWN_KEYS="user_name user_password user_realname user_shell root_password \
hostname user_ssh_key root_ssh_key locale timezone \
wifi_ssid wifi_password wifi_country \
static_ip static_mask static_gateway static_dns"

declare -A CFG=()

parse_config() {
    CFG=()
    [ -f "$CONFIG_FILE" ] || { log "No config file at $CONFIG_FILE; nothing to apply"; return 1; }
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"                                   # strip CR from Windows edits
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value#"${value%%[![:space:]]*}"}"         # trim leading whitespace
            CFG[$key]="$value"
        fi
    done < "$CONFIG_FILE"
    log "Parsed ${#CFG[@]} active setting(s)"
    return 0
}

cfg() { echo "${CFG[$1]:-}"; }

# ── Application helpers ─────────────────────────────────────────────────────

# install_ssh_key <keyvalue> <authorized_keys_path> <owner>
# Accepts an inline public key OR a http/https/file URL to download.
install_ssh_key() {
    local key="$1" dest="$2" owner="$3" dir
    dir=$(dirname "$dest")
    mkdir -p "$dir"; chmod 700 "$dir"
    if [[ "$key" =~ ^(https?|file):// ]]; then
        if curl -fsSL --max-time 60 "$key" -o "$dest.tmp"; then
            mv "$dest.tmp" "$dest"
        else
            rm -f "$dest.tmp"; log "  WARNING: failed to fetch SSH key from $key"; return 1
        fi
    else
        printf '%s\n' "$key" > "$dest"
    fi
    chmod 600 "$dest"
    [ -n "$owner" ] && chown -R "$owner:$owner" "$dir" 2>/dev/null || true
    log "  installed SSH key -> $dest"
}

apply_hostname() {
    local host; host=$(cfg hostname)
    [ -n "$host" ] || return 0
    log "Setting hostname to $host"
    # Persist first so later services see the intended name. If hostnamed is
    # unavailable, still update the running kernel before discovery/X11 start.
    printf '%s\n' "$host" > "$HOSTNAME_FILE" || {
        log "  ERROR: could not save hostname"; return 1
    }
    if ! hostnamectl set-hostname "$host"; then
        log "  WARNING: hostnamectl failed; applying the runtime hostname directly"
        hostname "$host" || {
            log "  ERROR: could not set runtime hostname"; return 1
        }
    fi
    if [ -f "$HOSTS_FILE" ]; then
        sed -i '/^127\.0\.1\.1[[:space:]]/d' "$HOSTS_FILE" || return 1
        printf '127.0.1.1\t%s\n' "$host" >> "$HOSTS_FILE" || return 1
    fi
}

apply_user() {
    local user pw realname shell key
    user=$(cfg user_name)
    [ -n "$user" ] || { log "no user_name set; skipping user creation"; return 0; }
    pw=$(cfg user_password)
    realname=$(cfg user_realname); [ -n "$realname" ] || realname="$user"
    shell=$(cfg user_shell); [ -n "$shell" ] || shell="bash"
    if [ ! -x "/bin/$shell" ]; then
        log "  WARNING: /bin/$shell not found; falling back to bash"; shell="bash"
    fi

    if id "$user" >/dev/null 2>&1; then
        log "User $user already exists; updating shell/password"
        usermod -s "/bin/$shell" "$user" 2>/dev/null || true
    else
        log "Creating user $user (shell /bin/$shell)"
        useradd -m -s "/bin/$shell" -G sudo -c "$realname" "$user" || {
            log "  ERROR: useradd failed for $user"; return 1
        }
    fi
    # Hardware access without sudo, also over SSH: camera and video codecs,
    # GPU, sound, input, serial, GPIO/I2C, Wi-Fi and Bluetooth. docker is
    # left out on purpose because it is equivalent to root.
    local groups="" group
    for group in $DEVICE_GROUPS; do
        getent group "$group" >/dev/null 2>&1 && groups="${groups:+$groups,}$group"
    done
    if [ -n "$groups" ]; then
        log "Adding $user to device groups: $groups"
        usermod -aG "$groups" "$user" || log "  WARNING: could not add $user to $groups"
    fi
    [ -n "$pw" ] && printf '%s:%s\n' "$user" "$pw" | chpasswd

    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > "/etc/sudoers.d/010-${user}-nopasswd"
    chmod 440 "/etc/sudoers.d/010-${user}-nopasswd"

    key=$(cfg user_ssh_key)
    [ -n "$key" ] && install_ssh_key "$key" "/home/$user/.ssh/authorized_keys" "$user"
}

apply_root() {
    local pw key
    pw=$(cfg root_password)
    if [ -n "$pw" ]; then
        log "Setting root password"
        printf 'root:%s\n' "$pw" | chpasswd
    fi
    key=$(cfg root_ssh_key)
    [ -n "$key" ] && install_ssh_key "$key" "/root/.ssh/authorized_keys" "root"
}

apply_locale() {
    local locale; locale=$(cfg locale)
    [ -n "$locale" ] || return 0
    log "Setting locale to $locale"
    if grep -q "^${locale} " /etc/locale.gen 2>/dev/null; then
        sed -i "s/^# *\(${locale} .*\)/\1/" /etc/locale.gen
        locale-gen "$locale" || true
    fi
    update-locale LANG="$locale" || true
}

apply_timezone() {
    local tz; tz=$(cfg timezone)
    [ -n "$tz" ] || return 0
    log "Setting timezone to $tz"
    timedatectl set-timezone "$tz" 2>/dev/null && return 0
    if [ -f "/usr/share/zoneinfo/$tz" ]; then
        ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
        echo "$tz" > /etc/timezone
        dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true
    else
        log "  WARNING: timezone $tz not found"
    fi
}

apply_wifi() {
    local ssid pw country
    ssid=$(cfg wifi_ssid)
    [ -n "$ssid" ] || return 0
    pw=$(cfg wifi_password)
    [ -n "$pw" ] || { log "  WARNING: wifi_ssid set but wifi_password empty; skipping Wi-Fi"; return 0; }
    country=$(cfg wifi_country)

    log "Configuring Wi-Fi: $ssid"
    # NetworkManager has no per-connection country property; set the wireless
    # regulatory domain out-of-band via iw instead.
    if [ -n "$country" ]; then
        if command -v iw >/dev/null 2>&1; then
            iw reg set "$country" 2>/dev/null && log "  regdomain=$country" \
                || log "  WARNING: 'iw reg set $country' failed"
        else
            log "  WARNING: 'iw' not installed; cannot set regdomain $country"
        fi
    fi
    nmcli connection delete "WiFi-$ssid" 2>/dev/null || true
    if nmcli connection add type wifi con-name "WiFi-$ssid" ifname wlan0 ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pw" autoconnect yes; then
        nmcli connection up "WiFi-$ssid" || log "  Wi-Fi 'up' deferred (AP may be out of range)"
    else
        log "  WARNING: failed to add Wi-Fi connection $ssid"
    fi
}

# Convert a dotted netmask (255.255.255.0) to a CIDR prefix (24). A value that is
# already numeric is echoed back unchanged; anything unrecognised is passed
# through so nmcli can reject it with a clear error.
netmask_to_prefix() {
    local m="$1"
    case "$m" in
        *.*)
            local IFS=. bits=0 octet
            for octet in $m; do
                case "$octet" in
                    255) bits=$((bits+8));; 254) bits=$((bits+7));; 252) bits=$((bits+6));;
                    248) bits=$((bits+5));; 240) bits=$((bits+4));; 224) bits=$((bits+3));;
                    192) bits=$((bits+2));; 128) bits=$((bits+1));; 0) ;;
                    *) echo "$m"; return;;
                esac
            done
            echo "$bits" ;;
        *) echo "$m" ;;
    esac
}

apply_static_ip() {
    local ip mask prefix gw dns con="Wired connection 1"
    ip=$(cfg static_ip)
    [ -n "$ip" ] || return 0
    mask=$(cfg static_mask); [ -n "$mask" ] || mask=24
    # nmcli's ipv4.addresses wants a CIDR prefix, not a dotted netmask.
    prefix=$(netmask_to_prefix "$mask")
    gw=$(cfg static_gateway)
    dns=$(cfg static_dns)
    log "Configuring static IP $ip/$prefix on '$con'"
    nmcli connection modify "$con" ipv4.method manual ipv4.addresses "${ip}/${prefix}" \
        ${gw:+ipv4.gateway "$gw"} ${dns:+ipv4.dns "$dns"} || {
        log "  WARNING: static IP modify failed"; return 1
    }
    nmcli connection up "$con" || true
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    parse_config || exit 0
    if [ "${#CFG[@]}" -eq 0 ]; then
        log "No active settings; leaving defaults in place"
        rm -f "$CONFIG_FILE"
        return 0
    fi

    apply_hostname
    apply_user
    apply_root
    apply_locale
    apply_timezone
    apply_wifi
    apply_static_ip

    # Remove the file so no password remains readable on the FAT partition.
    rm -f "$CONFIG_FILE"
    sync
    log "Config applied and $CONFIG_FILE removed ($(date -Iseconds))"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [ "$(id -u)" -ne 0 ]; then
        log "ERROR: must run as root" >&2
        exit 1
    fi
    exec > >(tee -a "$LOG") 2>&1
    log "Starting ($(date -Iseconds)); config=$CONFIG_FILE"
    main "$@"
fi
