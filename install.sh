#!/usr/bin/env bash
# Rebecca Manager - by Mohmrzw

PANEL_DIR="/opt/rebecca"
PANEL_SERVICE_NAME="rebecca"
NODE_SERVICE_NAME="rebecca-node"
STATE_FILE="/etc/rebecca-manager.state"

CERTS_BASE_DIR="/var/lib/rebecca/certs"
CERT_MAIN_CERTFILE=""

# Panel commands (Rebecca-scripts)
PANEL_INSTALL_SQLITE_CMD='bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install'
PANEL_INSTALL_MYSQL_CMD='bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install --database mysql'
PANEL_INSTALL_MARIADB_CMD='bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install --database mariadb'
PANEL_INSTALL_MARIADB_DEV_CMD='bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install --database mariadb --dev'
PANEL_INSTALL_SCRIPT_ONLY_CMD='bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install-script'
PANEL_INSTALL_MAINTENANCE_CMD='bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install-service'
PANEL_CORE_UPDATE_CMD='rebecca core-update'

# Node commands
NODE_INSTALL_DEFAULT_CMD='bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca-node.sh)" @ install'
NODE_INSTALL_SCRIPT_ONLY_CMD='bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca-node.sh)" @ install-script'
NODE_INSTALL_MAINTENANCE_DEFAULT_CMD='bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca-node.sh)" @ install-service --name rebecca-node'
NODE_CORE_UPDATE_CMD='rebecca-node core-update'

# Colors
if command -v tput &>/dev/null; then
    RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4); MAGENTA=$(tput setaf 5); CYAN=$(tput setaf 6)
    BOLD=$(tput bold); RESET=$(tput sgr0)
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""; RESET=""
fi

[[ $EUID -ne 0 ]] && { echo -e "${RED}run as root.${RESET}"; exit 1; }

# State vars
PANEL_INSTALLED="no"
NODE_INSTALLED="no"
PANEL_DB="unknown"
PANEL_DOMAIN="not-set"
ADMIN_CONFIGURED="no"

load_state() {
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
    : "${PANEL_INSTALLED:=no}"
    : "${NODE_INSTALLED:=no}"
    : "${PANEL_DB:=unknown}"
    : "${PANEL_DOMAIN:=not-set}"
    : "${ADMIN_CONFIGURED:=no}"
}

save_state() {
    cat >"$STATE_FILE" <<EOF
PANEL_INSTALLED="$PANEL_INSTALLED"
NODE_INSTALLED="$NODE_INSTALLED"
PANEL_DB="$PANEL_DB"
PANEL_DOMAIN="$PANEL_DOMAIN"
ADMIN_CONFIGURED="$ADMIN_CONFIGURED"
EOF
}

mark_panel_installed() { PANEL_INSTALLED="yes"; PANEL_DB="$1"; save_state; }
mark_panel_uninstalled() { PANEL_INSTALLED="no"; PANEL_DB="unknown"; save_state; }
mark_node_installed() { NODE_INSTALLED="yes"; save_state; }
mark_node_uninstalled() { NODE_INSTALLED="no"; save_state; }

press_enter() { echo; read -rp "↩  Enter to continue..." _; }

status_icon() { [[ "$1" == "yes" ]] && echo -e "${GREEN}✅${RESET}" || echo -e "${RED}❌${RESET}"; }

section_title() { echo; echo -e "${BOLD}${MAGENTA}─ $1 ─────────────────────────────────────────────${RESET}"; echo; }

check_service_status() {
    local s="$1"
    if systemctl list-unit-files | grep -q "^$s"; then
        local a e icon
        a=$(systemctl is-active "$s" 2>/dev/null)
        e=$(systemctl is-enabled "$s" 2>/dev/null || echo "unknown")
        icon="🔴"; [[ "$a" == "active" ]] && icon="🟢"
        echo -e "  ${icon} ${BOLD}$s${RESET}  status: ${CYAN}$a${RESET}, enabled: ${CYAN}$e${RESET}"
    else
        echo -e "  ⚪ ${BOLD}$s${RESET}  ${RED}not found${RESET}"
    fi
}

strip_quotes() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v="${v%\"}"; v="${v#\"}"
    v="${v%\'}"; v="${v#\'}"
    echo "$v"
}

# ---------- domains / certs ----------

DOMAINS=()

domains_reset() { DOMAINS=(); }

domains_add() {
    local d
    d=$(strip_quotes "$1")
    d="${d// /}"
    [[ -z "$d" ]] && return
    case "$d" in localhost|127.0.0.1|0.0.0.0|example.com) return ;; esac
    for x in "${DOMAINS[@]}"; do [[ "$x" == "$d" ]] && return; done
    DOMAINS+=("$d")
}

domains_scan() {
    domains_reset
    CERT_MAIN_CERTFILE=""
    local env_file="$PANEL_DIR/.env"

    # UVICORN_SSL_CERTFILE = "path"
    if [[ -f "$env_file" ]]; then
        local line path base
        line=$(grep -E '^UVICORN_SSL_CERTFILE' "$env_file" 2>/dev/null | head -n1 || true)
        if [[ -n "$line" ]]; then
            path=${line#*=}
            path=$(strip_quotes "$path")
            if [[ -f "$path" ]]; then
                CERT_MAIN_CERTFILE="$path"
                base=$(dirname "$(dirname "$path")")
                [[ -d "$base" ]] && CERTS_BASE_DIR="$base"
                if command -v openssl &>/dev/null; then
                    local cn
                    cn=$(openssl x509 -in "$path" -noout -subject 2>/dev/null \
                         | sed -n 's/.*CN *= *//p' | sed 's#/.*##')
                    [[ -n "$cn" ]] && domains_add "$cn"
                    while IFS= read -r san; do
                        [[ -n "$san" ]] && domains_add "$san"
                    done < <(
                        openssl x509 -in "$path" -noout -text 2>/dev/null \
                          | awk '/Subject Alternative Name/{getline; print}' \
                          | tr ',' '\n' \
                          | sed -n 's/ *DNS://p'
                    )
                else
                    local d; d=$(basename "$(dirname "$path")"); [[ -n "$d" ]] && domains_add "$d"
                fi
            fi
        fi
    fi

    # .metadata → domains=...
    if [[ -d "$CERTS_BASE_DIR" ]]; then
        while IFS= read -r meta; do
            local ln
            ln=$(grep -E '^domains=' "$meta" 2>/dev/null | head -n1 || true)
            [[ -z "$ln" ]] && continue
            ln=${ln#domains=}
            for d in $ln; do domains_add "$d"; done
        done < <(find "$CERTS_BASE_DIR" -maxdepth 2 -type f -name '.metadata' 2>/dev/null)

        while IFS= read -r d; do
            [[ "$d" == "README" ]] && continue
            domains_add "$d"
        done < <(ls -1 "$CERTS_BASE_DIR" 2>/dev/null)
    fi
}

detect_runtime_state() {
    local mod="no"

    if systemctl list-unit-files | grep -q "^$PANEL_SERVICE_NAME" || [[ -d "$PANEL_DIR" ]]; then
        [[ "$PANEL_INSTALLED" != "yes" ]] && PANEL_INSTALLED="yes" && mod="yes"
    fi
    if systemctl list-unit-files | grep -q "^$NODE_SERVICE_NAME"; then
        [[ "$NODE_INSTALLED" != "yes" ]] && NODE_INSTALLED="yes" && mod="yes"
    fi

    if [[ "$PANEL_DB" == "unknown" || -z "$PANEL_DB" ]]; then
        local env_file="$PANEL_DIR/.env"
        if [[ -f "$env_file" ]]; then
            local ln dburl
            ln=$(grep -E '^SQLALCHEMY_DATABASE_URL' "$env_file" 2>/dev/null | head -n1 || true)
            if [[ -n "$ln" ]]; then
                dburl=${ln#*=}
                dburl=$(strip_quotes "$dburl")
                case "$dburl" in
                    sqlite*) PANEL_DB="sqlite" ;;
                    mysql*) PANEL_DB="mysql" ;;
                    postgresql*|postgres*) PANEL_DB="pgsql" ;;
                esac
                [[ -n "$PANEL_DB" ]] && mod="yes"
            fi
        fi
    fi

    domains_scan
    if ((${#DOMAINS[@]} > 0)); then
        local joined; joined=$(IFS=,; echo "${DOMAINS[*]}")
        [[ "$joined" != "$PANEL_DOMAIN" ]] && PANEL_DOMAIN="$joined" && mod="yes"
    fi

    [[ "$mod" == "yes" ]] && save_state
}

get_domain_cert_path() {
    local d="$1" cert_path
    cert_path="$CERTS_BASE_DIR/$d/fullchain.pem"
    [[ -f "$cert_path" ]] && { echo "$cert_path"; return 0; }
    if [[ -n "$CERT_MAIN_CERTFILE" && -f "$CERT_MAIN_CERTFILE" ]]; then
        echo "$CERT_MAIN_CERTFILE"
        return 0
    fi
    return 1
}

domain_days_left() {
    local d="$1" cert_path end_date end_ts now_ts
    if ! cert_path=$(get_domain_cert_path "$d"); then
        echo "-"
        return 1
    fi
    command -v openssl &>/dev/null || { echo "-"; return 1; }
    end_date=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -n "$end_date" ]] || { echo "-"; return 1; }
    end_ts=$(date -d "$end_date" +%s 2>/dev/null || date -j -f "%b %e %T %Y %Z" "$end_date" +%s 2>/dev/null)
    now_ts=$(date +%s)
    [[ -n "$end_ts" ]] || { echo "-"; return 1; }
    echo $(( (end_ts - now_ts) / 86400 ))
}

ssl_status_icon() {
    if [[ -z "$PANEL_DOMAIN" || "$PANEL_DOMAIN" == "not-set" ]]; then
        echo -e "${YELLOW}N/A${RESET}"
        return
    fi
    if [[ -n "$CERT_MAIN_CERTFILE" && -f "$CERT_MAIN_CERTFILE" ]]; then
        echo -e "${GREEN}✅${RESET}"
        return
    fi
    echo -e "${RED}❌${RESET}"
}

maint_status_icon() {
    if systemctl list-unit-files | grep -q '^rebecca-maint.service'; then
        if systemctl is-active --quiet 'rebecca-maint.service'; then
            echo -e "${GREEN}Maint: OK${RESET}"
        else
            echo -e "${YELLOW}Maint: inactive${RESET}"
        fi
    else
        echo -e "${RED}Maint: none${RESET}"
    fi
}

banner() {
    load_state
    detect_runtime_state
    clear
    echo -e "${BOLD}${BLUE}┌──────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}${BLUE}│${RESET}  💠  Rebecca Panel Manager (by Mohmrzw)           ${BOLD}${BLUE}│${RESET}"
    echo -e "${BOLD}${BLUE}├──────────────────────────────────────────────────────────┤${RESET}"
    echo -e "${BOLD}${BLUE}│${RESET}  🧩 Panel : $(status_icon "$PANEL_INSTALLED")   DB: ${CYAN}$PANEL_DB${RESET}           ${BOLD}${BLUE}│${RESET}"
    echo -e "${BOLD}${BLUE}│${RESET}  🌐 Node  : $(status_icon "$NODE_INSTALLED")                         ${BOLD}${BLUE}│${RESET}"
    echo -e "${BOLD}${BLUE}│${RESET}  🔐 SSL   : $(ssl_status_icon)                             ${BOLD}${BLUE}│${RESET}"
    printf  "${BOLD}${BLUE}│${RESET}  🛟 %-45s${BOLD}${BLUE}│${RESET}\n" "$(maint_status_icon)"
    echo -e "${BOLD}${BLUE}├──────────────────────────────────────────────────────────┤${RESET}"

    if ((${#DOMAINS[@]} > 0)) && command -v openssl &>/dev/null; then
        echo -e "${BOLD}${BLUE}│${RESET}  🌍 Domains & Days Left:                         ${BOLD}${BLUE}│${RESET}"
        for d in "${DOMAINS[@]}"; do
            local days status days_str
            days=$(domain_days_left "$d")
            if [[ "$days" == "-" ]]; then
                status="${RED}❌${RESET}"
                days_str="-"
            else
                if (( days < 0 )); then status="${RED}❌${RESET}"; else status="${GREEN}✅${RESET}"; fi
                days_str="${days}d"
            fi
            printf "${BOLD}${BLUE}│${RESET}    %-28s %s  %-8s${BOLD}${BLUE}│${RESET}\n" "$d" "$status" "$days_str"
        done
    else
        echo -e "${BOLD}${BLUE}│${RESET}  🌍 Domains: ${YELLOW}not detected${RESET}                   ${BOLD}${BLUE}│${RESET}"
    fi

    echo -e "${BOLD}${BLUE}└──────────────────────────────────────────────────────────┘${RESET}"
    echo
}

run_cmd() {
    local cmd="$1"
    [[ -z "$cmd" ]] && { echo -e "${RED}no command set.${RESET}"; press_enter; return 1; }
    echo -e "${YELLOW}>> ${CYAN}$cmd${RESET}"
    read -rp "run? (y/N): " a
    [[ "$a" =~ ^[Yy]$ ]] || { echo "canceled."; press_enter; return 1; }
    echo
    eval "$cmd"
    local st=$?
    echo
    [[ $st -eq 0 ]] && echo -e "${GREEN}ok.${RESET}" || echo -e "${RED}failed ($st).${RESET}"
    press_enter
    return $st
}

ensure_package() {
    local bin="$1" pkg="${2:-$1}"
    command -v "$bin" &>/dev/null && return 0
    echo -e "${YELLOW}installing ${BOLD}$pkg${RESET}"
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            apt-get update -y && apt-get install -y "$pkg"
        else
            echo -e "${RED}install $pkg manually.${RESET}"
            press_enter; return 1
        fi
    else
        echo -e "${RED}cannot detect OS.${RESET}"
        press_enter; return 1
    fi
}

# ---------- Panel ----------

panel_install_mariadb_version() {
    clear; section_title "Panel (MariaDB / custom version)"
    read -rp "version tag: " ver
    [[ -z "$ver" ]] && { echo "empty."; press_enter; return; }
    local url cmd
    url="https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh"
    cmd="bash -c \"\$(curl -sL $url)\" @ install --database mariadb --version $ver"
    run_cmd "$cmd" && mark_panel_installed "mariadb"
}

panel_menu() {
    while true; do
        clear; section_title "Panel management"
        echo -e "  1) 🧱 install/update (SQLite)"
        echo -e "  2) 💾 install/update (MySQL)"
        echo -e "  3) 🏦 install/update (MariaDB)"
        echo -e "  4) 🧪 install/update (MariaDB dev)"
        echo -e "  5) 🎯 install/update (MariaDB custom version)"
        echo -e "  6) 📎 install/update CLI only"
        echo -e "  7) 🩺 install/update maint service"
        echo -e "  8) ⚙️  core-update"
        echo -e "  9) 🗑  uninstall panel"
        echo; echo -e "  0) 🔙 back"; echo
        read -rp "> " o
        case "$o" in
            1) run_cmd "$PANEL_INSTALL_SQLITE_CMD"      && mark_panel_installed "sqlite"  ;;
            2) run_cmd "$PANEL_INSTALL_MYSQL_CMD"       && mark_panel_installed "mysql"   ;;
            3) run_cmd "$PANEL_INSTALL_MARIADB_CMD"     && mark_panel_installed "mariadb" ;;
            4) run_cmd "$PANEL_INSTALL_MARIADB_DEV_CMD" && mark_panel_installed "mariadb" ;;
            5) panel_install_mariadb_version ;;
            6) run_cmd "$PANEL_INSTALL_SCRIPT_ONLY_CMD" ;;
            7) run_cmd "$PANEL_INSTALL_MAINTENANCE_CMD" ;;
            8) run_cmd "$PANEL_CORE_UPDATE_CMD" ;;
            9) uninstall_panel ;;
            0) break ;;
            *) echo "bad option"; sleep 1 ;;
        esac
    done
}

uninstall_panel() {
    clear; section_title "Uninstall panel"
    echo -e "${RED}this stops $PANEL_SERVICE_NAME and removes $PANEL_DIR${RESET}"
    read -rp "type 'yes' to confirm: " a
    [[ "$a" == "yes" ]] || { echo "canceled."; press_enter; return; }
    systemctl stop "$PANEL_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$PANEL_SERVICE_NAME" 2>/dev/null || true
    [[ -d "$PANEL_DIR" ]] && rm -rf "$PANEL_DIR"
    mark_panel_uninstalled
    echo "done."; press_enter
}

# ---------- Node ----------

node_install_custom_name() {
    clear; section_title "Node install (custom)"
    read -rp "node name: " name
    [[ -z "$name" ]] && { echo "empty."; press_enter; return; }
    local url cmd
    url="https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca-node.sh"
    cmd="bash -c \"\$(curl -sL $url)\" @ install --name $name"
    run_cmd "$cmd" && mark_node_installed
}

node_install_maintenance_custom() {
    clear; section_title "Node maint (custom)"
    read -rp "node name: " name
    [[ -z "$name" ]] && { echo "empty."; press_enter; return; }
    local url cmd
    url="https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca-node.sh"
    cmd="bash -c \"\$(curl -sL $url)\" @ install-service --name $name"
    run_cmd "$cmd"
}

node_menu() {
    while true; do
        clear; section_title "Node management"
        echo -e "  1) 🌐 install/update default node"
        echo -e "  2) 🌐 install/update custom node"
        echo -e "  3) 📎 install/update node CLI only"
        echo -e "  4) 🩺 install/update maint (default)"
        echo -e "  5) 🩺 install/update maint (custom)"
        echo -e "  6) ⚙️  core-update node"
        echo -e "  7) 🗑  uninstall node service"
        echo; echo -e "  0) 🔙 back"; echo
        read -rp "> " o
        case "$o" in
            1) run_cmd "$NODE_INSTALL_DEFAULT_CMD" && mark_node_installed ;;
            2) node_install_custom_name ;;
            3) run_cmd "$NODE_INSTALL_SCRIPT_ONLY_CMD" && mark_node_installed ;;
            4) run_cmd "$NODE_INSTALL_MAINTENANCE_DEFAULT_CMD" ;;
            5) node_install_maintenance_custom ;;
            6) run_cmd "$NODE_CORE_UPDATE_CMD" ;;
            7) uninstall_node ;;
            0) break ;;
            *) echo "bad option"; sleep 1 ;;
        esac
    done
}

uninstall_node() {
    clear; section_title "Uninstall node"
    echo -e "${RED}stop/disable $NODE_SERVICE_NAME${RESET}"
    read -rp "type 'yes' to confirm: " a
    [[ "$a" == "yes" ]] || { echo "canceled."; press_enter; return; }
    systemctl stop "$NODE_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$NODE_SERVICE_NAME" 2>/dev/null || true
    mark_node_uninstalled
    echo "done."; press_enter
}

# ---------- Status ----------

status_menu() {
    load_state; detect_runtime_state
    clear; section_title "Status"
    echo -e "  panel : $(status_icon "$PANEL_INSTALLED")"
    echo -e "  DB    : ${CYAN}$PANEL_DB${RESET}"
    echo -e "  node  : $(status_icon "$NODE_INSTALLED")"
    echo -e "  domains: ${CYAN}$PANEL_DOMAIN${RESET}"
    echo -e "  admin flag: ${CYAN}$ADMIN_CONFIGURED${RESET}"
    echo; echo -e "${BOLD}services:${RESET}"
    check_service_status "$PANEL_SERVICE_NAME"
    check_service_status "$NODE_SERVICE_NAME"
    check_service_status "rebecca-maint.service"
    echo; echo -e "${BOLD}paths:${RESET}"
    [[ -d "$PANEL_DIR" ]] && echo -e "  panel dir: ${GREEN}$PANEL_DIR${RESET}" \
                          || echo -e "  panel dir: ${RED}$PANEL_DIR (missing)${RESET}"
    press_enter
}

# ---------- Domains overview ----------

domains_overview() {
    ensure_package "openssl" "openssl" || return
    load_state; detect_runtime_state
    clear; section_title "Domains & SSL overview"
    if ((${#DOMAINS[@]} == 0)); then
        echo -e "${YELLOW}no domains detected from certs.${RESET}"
        press_enter; return
    fi
    printf "%-35s %-6s %-10s\n" "Domain" "SSL" "DaysLeft"
    printf "%-35s %-6s %-10s\n" "-----------------------------------" "------" "----------"
    local d
    for d in "${DOMAINS[@]}"; do
        local days status
        days=$(domain_days_left "$d")
        if [[ "$days" == "-" ]]; then
            status="${RED}❌${RESET}"
        else
            if (( days < 0 )); then status="${RED}❌${RESET}"; else status="${GREEN}✅${RESET}"; fi
        fi
        printf "%-35s %-6s %-10s\n" "$d" "$status" "$days"
    done
    echo; echo "from local certs only."; press_enter
}

# ---------- SSL (local) ----------

ssl_show_info() {
    ensure_package "openssl" "openssl" || return
    clear; section_title "SSL (local cert info)"
    read -rp "domain: " d
    [[ -z "$d" ]] && { echo "empty."; press_enter; return; }
    local cert_path
    cert_path=$(get_domain_cert_path "$d") || { echo -e "${RED}no cert for $d${RESET}"; press_enter; return; }
    echo "cert: $cert_path"; echo
    openssl x509 -in "$cert_path" -noout -subject -issuer -dates 2>/dev/null || echo "cannot read cert"
    echo
    local days; days=$(domain_days_left "$d")
    [[ "$days" != "-" ]] && echo "days left: $days" || echo "days left: -"
    press_enter
}

ssl_menu() {
    while true; do
        clear; section_title "SSL (local)"
        echo -e "  1) 🌍 domains overview (days left)"
        echo -e "  2) 🔎 show cert info for domain"
        echo; echo -e "  0) 🔙 back"; echo
        read -rp "> " o
        case "$o" in
            1) domains_overview ;;
            2) ssl_show_info ;;
            0) break ;;
            *) echo "bad option"; sleep 1 ;;
        esac
    done
}

# ---------- Admins (CLI only, بدون لیست) ----------

admins_add() {
    clear; section_title "Create admin"
    echo "Runs: rebecca cli admin create"
    echo "CLI will ask for username/password/role."
    echo
    local cmd="rebecca cli admin create"
    if run_cmd "$cmd"; then ADMIN_CONFIGURED="yes"; save_state; fi
}

admins_delete() {
    clear; section_title "Delete admin"
    read -rp "username: " u
    [[ -z "$u" ]] && { echo "empty."; press_enter; return; }
    local cmd="rebecca cli admin delete --username $u"
    run_cmd "$cmd"
}

admins_change_role() {
    clear; section_title "Change admin role"
    echo "Runs: rebecca cli admin change-role --username USER --role ROLE"
    echo "Example roles: sudo, full_access"
    echo
    read -rp "username: " u
    [[ -z "$u" ]] && { echo "empty."; press_enter; return; }
    read -rp "new role: " r
    [[ -z "$r" ]] && { echo "empty."; press_enter; return; }
    local cmd="rebecca cli admin change-role --username $u --role $r"
    run_cmd "$cmd"
}

admins_import_from_env() {
    clear; section_title "Import admin from env"
    echo "Runs: rebecca cli admin import-from-env"
    echo "Make sure env has sudo admin vars set."
    echo
    local cmd="rebecca cli admin import-from-env"
    if run_cmd "$cmd"; then ADMIN_CONFIGURED="yes"; save_state; fi
}

admins_update() {
    clear; section_title "Update admin"
    echo "Runs: rebecca cli admin update --username USER [EXTRA]"
    echo "Example EXTRA: --password NEWPASS"
    echo
    read -rp "username: " u
    [[ -z "$u" ]] && { echo "empty."; press_enter; return; }
    read -rp "extra args (optional): " extra
    local cmd="rebecca cli admin update --username $u $extra"
    run_cmd "$cmd"
}

admins_menu() {
    while true; do
        clear; section_title "Admin management"
        echo -e "  1) ➕ create admin"
        echo -e "  2) ➖ delete admin"
        echo -e "  3) 🔁 change admin role"
        echo -e "  4) 📥 import admin from env"
        echo -e "  5) 🛠  update admin"
        echo; echo -e "  0) 🔙 back"; echo
        read -rp "> " o
        case "$o" in
            1) admins_add ;;
            2) admins_delete ;;
            3) admins_change_role ;;
            4) admins_import_from_env ;;
            5) admins_update ;;
            0) break ;;
            *) echo "bad option"; sleep 1 ;;
        esac
    done
}

# ---------- Rebecca control ----------

rebecca_ctrl_menu() {
    while true; do
        clear; section_title "Rebecca control (wrapper for 'rebecca' CLI)"
        echo -e "  1) ▶  rebecca up"
        echo -e "  2) ⏹  rebecca down"
        echo -e "  3) 🔁 rebecca restart"
        echo -e "  4) 📊 rebecca status"
        echo -e "  5) 📜 rebecca logs"
        echo -e "  6) 🧰 rebecca edit (docker-compose.yml)"
        echo -e "  7) 🧰 rebecca edit-env (.env)"
        echo -e "  8) 💾 rebecca backup"
        echo -e "  9) 🤖 rebecca backup-service"
        echo -e " 10) 🔐 rebecca ssl (built-in)"
        echo -e " 11) ❔ rebecca help"
        echo; echo -e "  0) 🔙 back"; echo
        read -rp "> " o
        case "$o" in
            1) run_cmd "rebecca up" ;;
            2) run_cmd "rebecca down" ;;
            3) run_cmd "rebecca restart" ;;
            4) run_cmd "rebecca status" ;;
            5) run_cmd "rebecca logs" ;;
            6) run_cmd "rebecca edit" ;;
            7) run_cmd "rebecca edit-env" ;;
            8) run_cmd "rebecca backup" ;;
            9) run_cmd "rebecca backup-service" ;;
            10) run_cmd "rebecca ssl" ;;
            11) run_cmd "rebecca help" ;;
            0) break ;;
            *) echo "bad option"; sleep 1 ;;
        esac
    done
}

# ---------- Settings ----------

settings_menu() {
    while true; do
        clear; section_title "Settings"
        echo -e "  panel dir : $PANEL_DIR"
        echo -e "  panel svc : $PANEL_SERVICE_NAME"
        echo -e "  node  svc : $NODE_SERVICE_NAME"
        echo -e "  certs dir : $CERTS_BASE_DIR"
        echo -e "  domains   : $PANEL_DOMAIN"
        echo -e "  admin flag: $ADMIN_CONFIGURED"
        echo -e "  state     : $STATE_FILE"
        echo
        echo -e "  1) ✏️  change panel dir"
        echo -e "  2) ✏️  change panel service"
        echo -e "  3) ✏️  change node service"
        echo -e "  4) ✏️  set domains manually"
        echo -e "  5) ✏️  change certs dir"
        echo -e "  6) 🔁 toggle admin flag"
        echo; echo -e "  0) 🔙 back"; echo
        read -rp "> " o
        case "$o" in
            1) read -rp "panel dir: " v; [[ -n "$v" ]] && PANEL_DIR="$v" ;;
            2) read -rp "panel svc: " v; [[ -n "$v" ]] && PANEL_SERVICE_NAME="$v" ;;
            3) read -rp "node svc : " v; [[ -n "$v" ]] && NODE_SERVICE_NAME="$v" ;;
            4) read -rp "domains (comma): " v; [[ -n "$v" ]] && { PANEL_DOMAIN="$v"; save_state; } ;;
            5) read -rp "certs dir: " v; [[ -n "$v" ]] && CERTS_BASE_DIR="$v" ;;
            6) [[ "$ADMIN_CONFIGURED" == "yes" ]] && ADMIN_CONFIGURED="no" || ADMIN_CONFIGURED="yes"; save_state ;;
            0) break ;;
            *) echo "bad option"; sleep 1 ;;
        esac
    done
}

# ---------- main ----------

main_menu() {
    load_state; detect_runtime_state
    while true; do
        banner
        section_title "Main menu"
        echo -e "  1) 🧩 panel install / update"
        echo -e "  2) 🌐 node install / update"
        echo -e "  3) 📊 status"
        echo -e "  4) 🔐 SSL (local)"
        echo -e "  5) 👤 admins (create/delete/change-role/import/update)"
        echo -e "  6) ⚙️  settings"
        echo -e "  7) 🌍 domains & SSL overview"
        echo -e "  8) ⚡ rebecca control (up/down/logs/ssl/backup)"
        echo; echo -e "  0) 🚪 exit"; echo
        read -rp "> " o
        case "$o" in
            1) panel_menu ;;
            2) node_menu ;;
            3) status_menu ;;
            4) ssl_menu ;;
            5) admins_menu ;;
            6) settings_menu ;;
            7) domains_overview ;;
            8) rebecca_ctrl_menu ;;
            0) echo "bye."; exit 0 ;;
            *) echo "bad option"; sleep 1 ;;
        esac
    done
}

main_menu
