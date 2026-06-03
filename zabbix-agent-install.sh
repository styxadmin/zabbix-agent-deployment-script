#!/usr/bin/env bash
#
# zabbix-agent-install.sh
# --------------------------------------------------------------------------
# Interactive Zabbix agent installer + configurator.
#
# Maps to the Zabbix "Download" page workflow:
#   PART 1  -> interactively pick: Zabbix version, OS distribution,
#              OS version, Zabbix component                       (step 1)
#   PART 2  -> a/b  install Zabbix repository
#              c    install the Zabbix agent package              (step 2)
#   CONFIG  -> Server= (passive)                                  (step 3)
#              ListenPort=                                        (step 4)
#              ServerActive=                                      (step 5)
#              Hostname=  (asked interactively)                   (step 6)
#   PART 2  -> d    start the agent + enable at boot              (step 7)
#
# Config defaults below are taken from the supplied zabbix_agent2.txt example.
# Run as root:   sudo ./zabbix-agent-install.sh
# --------------------------------------------------------------------------

set -Eeuo pipefail

# ======================================================================
#  ORG DEFAULTS  (steps 3-5).  Edit these for your environment.
#  These are applied to the agent config automatically (non-interactive).
# ======================================================================
PASSIVE_SERVER="zabbix.microtechnamibia.com"          # -> Server=
LISTEN_PORT="20050"                                   # -> ListenPort=
SERVER_ACTIVE="zabbix.microtechnamibia.com:20051"     # -> ServerActive=
# Hostname (step 6) is asked interactively; default = this machine's name.

# ----------------------------------------------------------------------
#  Logging helpers
# ----------------------------------------------------------------------
if [ -t 2 ]; then
    C_BLUE='\033[1;34m'; C_YEL='\033[1;33m'; C_RED='\033[1;31m'
    C_GRN='\033[1;32m'; C_OFF='\033[0m'
else
    C_BLUE=''; C_YEL=''; C_RED=''; C_GRN=''; C_OFF=''
fi
log()  { printf "${C_BLUE}[*]${C_OFF} %s\n" "$*" >&2; }
ok()   { printf "${C_GRN}[+]${C_OFF} %s\n" "$*" >&2; }
warn() { printf "${C_YEL}[!]${C_OFF} %s\n" "$*" >&2; }
err()  { printf "${C_RED}[x]${C_OFF} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "Failed at line ${LINENO}. Review the output above."' ERR

# ----------------------------------------------------------------------
#  Interactive input helpers (read from the terminal, so the script also
#  works when piped, e.g. curl ... | sudo bash)
# ----------------------------------------------------------------------
ask() {                         # ask "Prompt" ["default"]  -> echoes answer
    local prompt="$1" def="${2-}" ans
    if [ -n "$def" ]; then
        read -r -p "$prompt [$def]: " ans < /dev/tty || true
        printf '%s' "${ans:-$def}"
    else
        read -r -p "$prompt: " ans < /dev/tty || true
        printf '%s' "$ans"
    fi
}

choose() {                      # choose "Title" opt1 opt2 ...  -> echoes chosen
    local title="$1"; shift
    local options=("$@") i sel
    {
        echo
        echo "$title"
        for i in "${!options[@]}"; do
            printf '  %d) %s\n' "$((i + 1))" "${options[$i]}"
        done
    } >&2
    while :; do
        read -r -p "Select [1-${#options[@]}]: " sel < /dev/tty || true
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#options[@]} )); then
            printf '%s' "${options[$((sel - 1))]}"
            return 0
        fi
        echo "  Invalid choice, try again." >&2
    done
}

download() {                    # download URL OUTFILE
    local url="$1" out="$2"
    if command -v wget >/dev/null 2>&1; then
        wget -O "$out" "$url" || die "Download failed: $url"
    elif command -v curl >/dev/null 2>&1; then
        curl -fSL "$url" -o "$out" || die "Download failed: $url"
    else
        die "Neither wget nor curl is available to download $url"
    fi
}

url_exists() {                  # url_exists URL  -> returns 0 if reachable (200)
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsI --max-time 15 "$url" >/dev/null 2>&1 && return 0
        curl -fs  --max-time 15 -r 0-0 "$url" -o /dev/null >/dev/null 2>&1 && return 0
        return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --spider --timeout=15 "$url" 2>/dev/null && return 0
        return 1
    fi
    return 0   # no probe tool available; assume present and let download try
}

# Pick the first candidate repo URL that actually exists. The Zabbix repo
# layout differs across versions (e.g. 7.2/7.4 use a ".../release/..." path,
# while 7.0/6.0 do not), so we probe instead of hard-coding one shape.
resolve_repo_url() {
    local u
    for u in "${CANDIDATES[@]}"; do
        log "Checking repo URL: $u"
        if url_exists "$u"; then
            REPO_URL="$u"
            ok "Found repository package."
            return 0
        fi
    done
    err "No Zabbix repository package found for Zabbix ${VER} on ${DISTRO} ${OSVER}."
    err "Tried:"
    for u in "${CANDIDATES[@]}"; do err "    $u"; done
    die "Check the version / OS-version combination, or see https://www.zabbix.com/download"
}

# Set a key=value in a Zabbix config file.
# Deletes every existing ACTIVE (uncommented) line for the key, then appends
# the desired one. Idempotent, comment documentation is preserved, and the
# anchored regex means setting "Server" never touches "ServerActive".
set_config() {
    local key="$1" value="$2" file="$3"
    sed -i -E "/^[[:space:]]*${key}=/d" "$file"
    printf '%s=%s\n' "$key" "$value" >> "$file"
    ok "Set ${key}=${value}"
}

# ----------------------------------------------------------------------
#  Pre-flight
# ----------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Please run as root:  sudo $0"

# ======================================================================
#  STEP 1 — Interactive selection
# ======================================================================
VER=$(choose "Select Zabbix version:" "7.4" "7.2" "7.0 (LTS)" "6.0 (LTS)")
VER="${VER%% *}"   # strip the "(LTS)" label -> 7.4 / 7.2 / 7.0 / 6.0

DISTRO=$(choose "Select OS distribution:" \
    "Ubuntu" \
    "Debian" \
    "RHEL / CentOS / Rocky / AlmaLinux / Oracle" \
    "SLES / openSUSE")

# Offer the detected OS version as the default.
DETECTED_VER=""
[ -r /etc/os-release ] && DETECTED_VER="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
OSVER_RAW=$(ask "Enter the OS version NUMBER only (24.04 for Ubuntu, 12 for Debian, 9 for RHEL, 15 for SLES)" "$DETECTED_VER")
# Be forgiving: extract just the version token from whatever was typed,
# so "Debian 12" -> "12" and "Ubuntu 24.04" -> "24.04".
OSVER=$(printf '%s' "$OSVER_RAW" | grep -oE '[0-9]+(\.[0-9]+)*' | head -n1 || true)
[ -n "$OSVER" ] || die "Could not read an OS version number from: '${OSVER_RAW}'"

COMPONENT=$(choose "Select Zabbix component:" "Zabbix agent 2" "Zabbix agent")

# ----------------------------------------------------------------------
#  Derive package / service / config path from the chosen component
# ----------------------------------------------------------------------
if [ "$COMPONENT" = "Zabbix agent 2" ]; then
    PKG="zabbix-agent2"; SERVICE="zabbix-agent2"
    CONF="/etc/zabbix/zabbix_agent2.conf"; IS_AGENT2=1
else
    PKG="zabbix-agent"; SERVICE="zabbix-agent"
    CONF="/etc/zabbix/zabbix_agentd.conf"; IS_AGENT2=0
fi

# ----------------------------------------------------------------------
#  Derive package family + repository URL from the chosen distribution
# ----------------------------------------------------------------------
case "$DISTRO" in
    Ubuntu) FAMILY=deb;  OSID=ubuntu ;;
    Debian) FAMILY=deb;  OSID=debian ;;
    RHEL*)  FAMILY=rhel ;;
    SLES*)  FAMILY=sles ;;
    *) die "Unsupported distribution: $DISTRO" ;;
esac

# Build an ordered list of candidate repo URLs (newer "release/" layout first,
# then the older layout). resolve_repo_url() picks the first that exists.
CANDIDATES=()
case "$FAMILY" in
    deb)
        CANDIDATES+=("https://repo.zabbix.com/zabbix/${VER}/release/${OSID}/pool/main/z/zabbix-release/zabbix-release_latest_${VER}+${OSID}${OSVER}_all.deb")
        CANDIDATES+=("https://repo.zabbix.com/zabbix/${VER}/${OSID}/pool/main/z/zabbix-release/zabbix-release_latest_${VER}+${OSID}${OSVER}_all.deb")
        ;;
    rhel)
        CANDIDATES+=("https://repo.zabbix.com/zabbix/${VER}/release/rhel/${OSVER}/noarch/zabbix-release-latest-${VER}.el${OSVER}.noarch.rpm")
        CANDIDATES+=("https://repo.zabbix.com/zabbix/${VER}/release/rhel/${OSVER}/noarch/zabbix-release-latest.el${OSVER}.noarch.rpm")
        CANDIDATES+=("https://repo.zabbix.com/zabbix/${VER}/rhel/${OSVER}/x86_64/zabbix-release-latest-${VER}.el${OSVER}.noarch.rpm")
        ;;
    sles)
        CANDIDATES+=("https://repo.zabbix.com/zabbix/${VER}/release/sles/${OSVER}/noarch/zabbix-release-latest-${VER}.sles${OSVER}.noarch.rpm")
        CANDIDATES+=("https://repo.zabbix.com/zabbix/${VER}/sles/${OSVER}/x86_64/zabbix-release-latest-${VER}.sles${OSVER}.noarch.rpm")
        ;;
esac

REPO_URL=""
resolve_repo_url
REL="$(basename "$REPO_URL")"

# ======================================================================
#  STEP 6 — Hostname (interactive)
# ======================================================================
DEFAULT_HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo '')"
HOSTNAME_VAL=$(ask "Enter Zabbix Hostname (must match the host name configured on the Zabbix server)" "$DEFAULT_HOST")
[ -n "$HOSTNAME_VAL" ] || die "Hostname is required."

# ----------------------------------------------------------------------
#  Confirmation
# ----------------------------------------------------------------------
cat >&2 <<EOF

=====================  REVIEW  =====================
  Zabbix version : ${VER}
  Distribution   : ${DISTRO} ${OSVER}
  Component       : ${COMPONENT}
  Package        : ${PKG}
  Service        : ${SERVICE}
  Config file    : ${CONF}
  Repo package   : ${REPO_URL}

  Config to apply:
    Server        = ${PASSIVE_SERVER}
    ListenPort    = ${LISTEN_PORT}
    ServerActive  = ${SERVER_ACTIVE}
    Hostname      = ${HOSTNAME_VAL}
====================================================
EOF
CONFIRM=$(ask "Proceed? (yes/no)" "yes")
[ "$CONFIRM" = "yes" ] || die "Aborted by user."

# ======================================================================
#  STEP 2 (part 2: a, b, c) — install repository + agent
# ======================================================================
log "Installing Zabbix repository and ${PKG} ..."
case "$FAMILY" in
    deb)
        TMP="/tmp/${REL}"
        log "a/b) repository: ${REPO_URL}"
        download "$REPO_URL" "$TMP"
        dpkg -i "$TMP"
        apt-get update -y
        log "c) installing ${PKG}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG"
        if [ "$IS_AGENT2" -eq 1 ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "zabbix-agent2-plugin-*" \
                || warn "Agent 2 plugin packages not installed (may be built in for this version)."
        fi
        ;;
    rhel)
        log "a/b) repository: ${REPO_URL}"
        rpm -Uvh "$REPO_URL"
        if command -v dnf >/dev/null 2>&1; then PM=dnf; else PM=yum; fi
        $PM -y clean all
        log "c) installing ${PKG}"
        $PM install -y "$PKG"
        if [ "$IS_AGENT2" -eq 1 ]; then
            $PM install -y 'zabbix-agent2-plugin-*' \
                || warn "Agent 2 plugin packages not installed (may be built in for this version)."
        fi
        ;;
    sles)
        log "a/b) repository: ${REPO_URL}"
        rpm -Uvh "$REPO_URL"
        zypper --gpg-auto-import-keys refresh
        log "c) installing ${PKG}"
        zypper --non-interactive install "$PKG"
        ;;
esac
ok "Package installation complete."

# ======================================================================
#  STEPS 3-6 — configure the agent
# ======================================================================
[ -f "$CONF" ] || die "Expected config not found after install: $CONF"
BACKUP="${CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$CONF" "$BACKUP"
log "Backed up original config to ${BACKUP}"

set_config "Server"       "$PASSIVE_SERVER" "$CONF"   # step 3 (passive server)
set_config "ListenPort"   "$LISTEN_PORT"    "$CONF"   # step 4
set_config "ServerActive" "$SERVER_ACTIVE"  "$CONF"   # step 5
set_config "Hostname"     "$HOSTNAME_VAL"   "$CONF"   # step 6

# ======================================================================
#  STEP 7 (part 2: d) — start + enable
# ======================================================================
log "Starting and enabling ${SERVICE} ..."
systemctl restart "$SERVICE"
systemctl enable "$SERVICE"

# ----------------------------------------------------------------------
#  Verify
# ----------------------------------------------------------------------
echo >&2
ok "Done. Effective settings in ${CONF}:"
grep -E '^(Server|ServerActive|ListenPort|Hostname)=' "$CONF" >&2 || true
echo >&2
systemctl --no-pager --full status "$SERVICE" | head -n 5 >&2 || true
echo >&2
warn "Passive checks use port ${LISTEN_PORT}. If a firewall is active, allow that"
warn "port from ${PASSIVE_SERVER}, e.g.:  ufw allow ${LISTEN_PORT}/tcp   (or firewalld equivalent)."
