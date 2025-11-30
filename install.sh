#!/usr/bin/env bash
# Rebecca Manager - by Mohmrzw
# Final Version: Merged CLI Control Menu

PANEL_DIR="/opt/rebecca"
PANEL_SERVICE_NAME="rebecca"
NODE_SERVICE_NAME="rebecca-node"
NODE_DIR="/opt/rebecca-node"
PANEL_DATA_DIR="/var/lib/rebecca"
NODE_DATA_DIR="/var/lib/rebecca-node"
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

# --- UI & COLORS ---
if command -v tput &>/dev/null; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    MAGENTA=$(tput setaf 5)
    CYAN=$(tput setaf 6)
    WHITE=$(tput setaf 7)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; WHITE=""; BOLD=""; RESET=""
fi

# Custom UI Elements
BORDER="${MAGENTA}=============================================================================${RESET}"
THIN_BORDER="${MAGENTA}-----------------------------------------------------------------------------${RESET}"

[[ $EUID -ne 0 ]] && { echo -e "${RED}Error: Please run as root.${RESET}"; exit 1; }

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

press_enter() { echo; echo -ne "${MAGENTA}↩  Press Enter to continue...${RESET}"; read -r _; }

status_icon() { [[ "$1" == "yes" ]] && echo -e "${GREEN}INSTALLED${RESET}" || echo -e "${RED}NOT INSTALLED${RESET}"; }

# Enhanced Header
draw_header() {
    clear
    echo -e "${MAGENTA}    ____  _________  _____________________${RESET}"
    echo -e "${MAGENTA}   / __ \\/ ____/ _ )/ ____/ ____/ ____/   |${RESET}"
    echo -e "${CYAN}  / /_/ / __/ / __  / __/ / /   / /   / /| |${RESET}"
    echo -e "${CYAN} / _, _/ /___/ /_/ / /___/ /___/ /___/ ___ |${RESET}"
    echo -e "${CYAN}/_/ |_/_____/_____/_____/\\____/\\____/_/  |_|${RESET}"
    echo -e "${MAGENTA}                                              ${RESET}"
    echo
    echo -e " ${BLUE}Created by:${RESET} ${WHITE}@mohmrzw${RESET}  |  ${BLUE}ExploreTechIR${RESET}"
    echo -e " ${BLUE}GitHub:${RESET}     https://github.com/MohmRzw"
    echo -e " ${BLUE}YouTube:${RESET}    https://youtube.com/@mohmrzw"
    echo -e " ${BLUE}Telegram:${RESET}   https://t.me/ExploreTechIR"
    echo
}

section_title() { 
    draw_header
    echo -e "${BOLD}${WHITE}:: $1 ::${RESET}"
    echo -e "${THIN_BORDER}"
    echo 
}

check_service_status() {
    local s="$1"
    if systemctl list-unit-files | grep -q "^$s"; then
        local a e icon
        a=$(systemctl is-active "$s" 2>/dev/null)
        e=$(systemctl is-enabled "$s" 2>/dev/null || echo "unknown")
        icon="${RED}●${RESET}"; [[ "$a" == "active" ]] && icon="${GREEN}●${RESET}"
        printf "  %-30s status: %s %-10s enabled: %s\n" "$s" "$icon" "${WHITE}$a${RESET}" "${CYAN}$e${RESET}"
    else
        printf "  %-30s ${RED}not found${RESET}\n" "$s"
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

    local panel_present="no"
    if systemctl is-active --quiet "$PANEL_SERVICE_NAME" || [[ -d "$PANEL_DIR" ]]; then
        panel_present="yes"
    fi
    if [[ "$panel_present" == "yes" && "$PANEL_INSTALLED" != "yes" ]]; then
        PANEL_INSTALLED="yes"
        mod="yes"
    elif [[ "$panel_present" == "no" && "$PANEL_INSTALLED" != "no" ]]; then
        PANEL_INSTALLED="no"
        mod="yes"
    fi

    local node_present="no"
    if systemctl is-active --quiet "$NODE_SERVICE_NAME" || [[ -d "$NODE_DIR" ]]; then
        node_present="yes"
    fi
    if [[ "$node_present" == "yes" && "$NODE_INSTALLED" != "yes" ]]; then
        NODE_INSTALLED="yes"
        mod="yes"
    elif [[ "$node_present" == "no" && "$NODE_INSTALLED" != "no" ]]; then
        NODE_INSTALLED="no"
        mod="yes"
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
        echo -e "${GREEN}ACTIVE${RESET}"
        return
    fi
    echo -e "${RED}MISSING${RESET}"
}

maint_status_icon() {
    if systemctl list-unit-files | grep -q '^rebecca-maint.service'; then
        if systemctl is-active --quiet 'rebecca-maint.service'; then
            echo -e "${GREEN}Active${RESET}"
        else
            echo -e "${YELLOW}Inactive${RESET}"
        fi
    else
        echo -e "${RED}None${RESET}"
    fi
}

banner() {
    load_state
    detect_runtime_state
    draw_header

    echo -e "${BOLD}System Status:${RESET}"
    echo -e "${THIN_BORDER}"
    printf "  %-10s %-25s ${MAGENTA}|${RESET}  %-10s %-20s\n" "🧩 Panel:" "$(status_icon "$PANEL_INSTALLED")" "🛢  DB Type:" "${CYAN}$PANEL_DB${RESET}"
    printf "  %-10s %-25s ${MAGENTA}|${RESET}  %-10s %-20s\n" "🌐 Node:" "$(status_icon "$NODE_INSTALLED")" "🔐 SSL:" "$(ssl_status_icon)"
    printf "  %-10s %-25s ${MAGENTA}|${RESET}  %-10s %-20s\n" "🛟 Maint:" "$(maint_status_icon)" "" ""
    echo -e "${THIN_BORDER}"

    if ((${#DOMAINS[@]} > 0)) && command -v openssl &>/dev/null; then
        echo -e "  🌍 ${BOLD}Domains & SSL Expiry:${RESET}"
        for d in "${DOMAINS[@]}"; do
            local days status days_str
            days=$(domain_days_left "$d")
            if [[ "$days" == "-" ]]; then
                status="${RED}EXPIRED/INV${RESET}"
                days_str="-"
            else
                if (( days < 0 )); then status="${RED}EXPIRED${RESET}"; else status="${GREEN}VALID${RESET}"; fi
                days_str="${days} days"
            fi
            printf "    ${CYAN}%-25s${RESET} %-15s %s\n" "$d" "$status" "$days_str"
        done
        echo -e "${THIN_BORDER}"
    fi
}

run_cmd() {
    local cmd="$1"
    [[ -z "$cmd" ]] && { echo -e "${RED}No command set.${RESET}"; press_enter; return 1; }
    echo
    echo -e "${YELLOW}>> Executing: ${CYAN}$cmd${RESET}"
    echo -e "${THIN_BORDER}"
    read -rp "Are you sure you want to run this? (y/N): " a
    [[ "$a" =~ ^[Yy]$ ]] || { echo -e "${RED}Operation canceled.${RESET}"; press_enter; return 1; }
    echo
    eval "$cmd"
    local st=$?
    echo
    [[ $st -eq 0 ]] && echo -e "${GREEN}✔ Operation successful.${RESET}" || echo -e "${RED}✘ Operation failed (Exit Code: $st).${RESET}"
    press_enter
    return $st
}

ensure_package() {
    local bin="$1" pkg="${2:-$1}"
    command -v "$bin" &>/dev/null && return 0
    echo -e "${YELLOW}Installing dependency: ${BOLD}$pkg${RESET}"
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            apt-get update -y && apt-get install -y "$pkg"
        else
            echo -e "${RED}Please install $pkg manually.${RESET}"
            press_enter; return 1
        fi
    else
        echo -e "${RED}Cannot detect OS.${RESET}"
        press_enter; return 1
    fi
}

# ---------- Panel ----------

panel_install_mariadb_version() {
    section_title "Panel (MariaDB / Custom Version)"
    echo -ne "${CYAN}Enter version tag: ${RESET}"
    read -r ver
    [[ -z "$ver" ]] && { echo "Input empty."; press_enter; return; }
    local url cmd
    url="https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh"
    cmd="bash -c \"\$(curl -sL $url)\" @ install --database mariadb --version $ver"
    run_cmd "$cmd" && mark_panel_installed "mariadb"
}

panel_menu() {
    while true; do
        section_title "Panel Management"
        echo -e "  ${CYAN}1)${RESET} 🧱 Install / Update (SQLite)"
        echo -e "  ${CYAN}2)${RESET} 💾 Install / Update (MySQL)"
        echo -e "  ${CYAN}3)${RESET} 🏦 Install / Update (MariaDB)"
        echo -e "  ${CYAN}4)${RESET} 🧪 Install / Update (MariaDB Dev)"
        echo -e "  ${CYAN}5)${RESET} 🎯 Install / Update (MariaDB Custom)"
        echo -e "  ${CYAN}6)${RESET} 📎 Install / Update CLI Only"
        echo -e "  ${CYAN}7)${RESET} 🩺 Install / Update Maint Service"
        echo -e "  ${CYAN}8)${RESET} ⚙️  Core Update"
        echo -e "  ${CYAN}9)${RESET} 🗑  Uninstall Panel"
        echo
        echo -e "  ${CYAN}0)${RESET} 🔙 Back to Main Menu"
        echo
        echo -ne "${MAGENTA}Select option [0-9] -> ${RESET}"
        read -r o
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
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

uninstall_panel() {
    section_title "Uninstall Panel"
    echo -e "${RED}${BOLD}WARNING:${RESET} This will stop Rebecca panel containers/services and remove files."
    echo -ne "${YELLOW}Type 'yes' to confirm: ${RESET}"
    read -r a
    [[ "$a" != "yes" ]] && { echo "Canceled."; press_enter; return; }

    if [[ -d "$PANEL_DIR" ]]; then
        if command -v docker &>/dev/null; then
            if [[ -f "$PANEL_DIR/docker-compose.yml" ]]; then
                ( cd "$PANEL_DIR" && docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true )
            fi
        fi
    fi

    if command -v docker &>/dev/null; then
        docker ps -a --format '{{.ID}} {{.Names}}' | awk '/rebecca/ {print $1}' | xargs -r docker rm -f
    fi

    systemctl stop "$PANEL_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$PANEL_SERVICE_NAME" 2>/dev/null || true
    systemctl stop "rebecca-maint.service" 2>/dev/null || true
    systemctl disable "rebecca-maint.service" 2>/dev/null || true

    rm -f "/etc/systemd/system/$PANEL_SERVICE_NAME.service" "/etc/systemd/system/rebecca-maint.service"
    systemctl daemon-reload

    [[ -d "$PANEL_DIR" ]] && rm -rf "$PANEL_DIR"

    echo -ne "${YELLOW}Remove data directory $PANEL_DATA_DIR ? (y/N): ${RESET}"
    read -r r
    if [[ "$r" =~ ^[Yy]$ ]]; then
        [[ -d "$PANEL_DATA_DIR" ]] && rm -rf "$PANEL_DATA_DIR"
    fi

    for f in /usr/local/bin/rebecca /usr/bin/rebecca; do
        [[ -f "$f" ]] && rm -f "$f"
    done

    mark_panel_uninstalled
    echo -e "${GREEN}Uninstall complete.${RESET}"; press_enter
}

# ---------- Node ----------

node_install_custom_name() {
    section_title "Node Install (Custom Name)"
    echo -ne "${CYAN}Enter node name: ${RESET}"
    read -r name
    [[ -z "$name" ]] && { echo "Empty input."; press_enter; return; }
    local url cmd
    url="https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca-node.sh"
    cmd="bash -c \"\$(curl -sL $url)\" @ install --name $name"
    run_cmd "$cmd" && mark_node_installed
}

node_install_maintenance_custom() {
    section_title "Node Maintenance (Custom Name)"
    echo -ne "${CYAN}Enter node name: ${RESET}"
    read -r name
    [[ -z "$name" ]] && { echo "Empty input."; press_enter; return; }
    local url cmd
    url="https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca-node.sh"
    cmd="bash -c \"\$(curl -sL $url)\" @ install-service --name $name"
    run_cmd "$cmd"
}

node_menu() {
    while true; do
        section_title "Node Management"
        echo -e "  ${CYAN}1)${RESET} 🌐 Install / Update Default Node"
        echo -e "  ${CYAN}2)${RESET} 🌐 Install / Update Custom Node"
        echo -e "  ${CYAN}3)${RESET} 📎 Install / Update Node CLI Only"
        echo -e "  ${CYAN}4)${RESET} 🩺 Install / Update Maint (Default)"
        echo -e "  ${CYAN}5)${RESET} 🩺 Install / Update Maint (Custom)"
        echo -e "  ${CYAN}6)${RESET} ⚙️  Core Update Node"
        echo -e "  ${CYAN}7)${RESET} 🗑  Uninstall Node"
        echo
        echo -e "  ${CYAN}0)${RESET} 🔙 Back to Main Menu"
        echo
        echo -ne "${MAGENTA}Select option [0-9] -> ${RESET}"
        read -r o
        case "$o" in
            1) run_cmd "$NODE_INSTALL_DEFAULT_CMD" && mark_node_installed ;;
            2) node_install_custom_name ;;
            3) run_cmd "$NODE_INSTALL_SCRIPT_ONLY_CMD" && mark_node_installed ;;
            4) run_cmd "$NODE_INSTALL_MAINTENANCE_DEFAULT_CMD" ;;
            5) node_install_maintenance_custom ;;
            6) run_cmd "$NODE_CORE_UPDATE_CMD" ;;
            7) uninstall_node ;;
            0) break ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

uninstall_node() {
    section_title "Uninstall Node"
    echo -e "${RED}${BOLD}WARNING:${RESET} This will stop Rebecca-node containers/services and remove files."
    echo -ne "${YELLOW}Type 'yes' to confirm: ${RESET}"
    read -r a
    [[ "$a" != "yes" ]] && { echo "Canceled."; press_enter; return; }

    if [[ -d "$NODE_DIR" ]]; then
        if command -v docker &>/dev/null; then
            if [[ -f "$NODE_DIR/docker-compose.yml" ]]; then
                ( cd "$NODE_DIR" && docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true )
            fi
        fi
    fi

    if command -v docker &>/dev/null; then
        docker ps -a --format '{{.ID}} {{.Names}}' | awk '/rebecca-node/ {print $1}' | xargs -r docker rm -f
    fi

    systemctl stop "$NODE_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$NODE_SERVICE_NAME" 2>/dev/null || true
    systemctl stop "rebecca-node-maint.service" 2>/dev/null || true
    systemctl disable "rebecca-node-maint.service" 2>/dev/null || true

    rm -f "/etc/systemd/system/$NODE_SERVICE_NAME.service" "/etc/systemd/system/rebecca-node-maint.service"
    systemctl daemon-reload

    [[ -d "$NODE_DIR" ]] && rm -rf "$NODE_DIR"

    echo -ne "${YELLOW}Remove node data dir $NODE_DATA_DIR ? (y/N): ${RESET}"
    read -r r
    if [[ "$r" =~ ^[Yy]$ ]]; then
        [[ -d "$NODE_DATA_DIR" ]] && rm -rf "$NODE_DATA_DIR"
    fi

    for f in /usr/local/bin/rebecca-node /usr/bin/rebecca-node; do
        [[ -f "$f" ]] && rm -f "$f"
    done

    mark_node_uninstalled
    echo -e "${GREEN}Uninstall complete.${RESET}"; press_enter
}

# ---------- Status ----------

status_menu() {
    load_state; detect_runtime_state
    section_title "Detailed Status"
    echo -e "  Panel        : $(status_icon "$PANEL_INSTALLED")"
    echo -e "  DB           : ${CYAN}$PANEL_DB${RESET}"
    echo -e "  Node         : $(status_icon "$NODE_INSTALLED")"
    echo -e "  Domains      : ${CYAN}$PANEL_DOMAIN${RESET}"
    echo -e "  Admin Config : ${CYAN}$ADMIN_CONFIGURED${RESET}"
    echo
    echo -e "${BOLD}${BLUE}Services:${RESET}"
    check_service_status "$PANEL_SERVICE_NAME"
    check_service_status "$NODE_SERVICE_NAME"
    check_service_status "rebecca-maint.service"
    echo
    echo -e "${BOLD}${BLUE}Paths:${RESET}"
    if [[ -d "$PANEL_DIR" ]]; then
        echo -e "  Panel Dir : ${GREEN}$PANEL_DIR${RESET}"
    else
        echo -e "  Panel Dir : ${RED}$PANEL_DIR (Missing)${RESET}"
    fi
    press_enter
}

# ---------- Domains overview ----------

domains_overview() {
    ensure_package "openssl" "openssl" || return
    load_state; detect_runtime_state
    section_title "Domains & SSL Overview"
    if ((${#DOMAINS[@]} == 0)); then
        echo -e "${YELLOW}No domains detected from certs.${RESET}"
        press_enter; return
    fi
    printf "${BLUE}%-35s %-10s %-10s${RESET}\n" "DOMAIN" "STATUS" "DAYS LEFT"
    echo -e "${THIN_BORDER}"
    local d
    for d in "${DOMAINS[@]}"; do
        local days status
        days=$(domain_days_left "$d")
        if [[ "$days" == "-" ]]; then
            status="${RED}INVALID${RESET}"
        else
            if (( days < 0 )); then status="${RED}EXPIRED${RESET}"; else status="${GREEN}VALID${RESET}"; fi
        fi
        printf "%-35s %-10s %-10s\n" "$d" "$status" "$days"
    done
    echo -e "${THIN_BORDER}"
    echo -e "${WHITE}Note: Info from local certificates only.${RESET}"
    press_enter
}

# ---------- SSL (local) ----------

ssl_show_info() {
    ensure_package "openssl" "openssl" || return
    section_title "SSL Certificate Info"
    echo -ne "${CYAN}Enter domain: ${RESET}"
    read -r d
    [[ -z "$d" ]] && { echo "Empty input."; press_enter; return; }
    local cert_path
    cert_path=$(get_domain_cert_path "$d") || { echo -e "${RED}No cert found for $d${RESET}"; press_enter; return; }
    echo -e "Cert Path: ${CYAN}$cert_path${RESET}"; echo
    openssl x509 -in "$cert_path" -noout -subject -issuer -dates 2>/dev/null || echo "${RED}Cannot read certificate.${RESET}"
    echo
    local days; days=$(domain_days_left "$d")
    [[ "$days" != "-" ]] && echo -e "Days Left: ${GREEN}$days${RESET}" || echo -e "Days Left: ${RED}-${RESET}"
    press_enter
}

ssl_menu() {
    while true; do
        section_title "SSL Management (Local)"
        echo -e "  ${CYAN}1)${RESET} 🌍 Domains Overview (Days Left)"
        echo -e "  ${CYAN}2)${RESET} 🔎 Show Cert Info for Domain"
        echo
        echo -e "  ${CYAN}0)${RESET} 🔙 Back"
        echo
        echo -ne "${MAGENTA}Select option [0-9] -> ${RESET}"
        read -r o
        case "$o" in
            1) domains_overview ;;
            2) ssl_show_info ;;
            0) break ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

# ---------- Admins (CLI only) ----------

admins_add() {
    section_title "Create Admin"
    echo -e "${WHITE}This will run: ${CYAN}rebecca cli admin create${RESET}"
    echo -e "${WHITE}The CLI will ask for username, password, and role.${RESET}"
    echo
    local cmd="rebecca cli admin create"
    if run_cmd "$cmd"; then ADMIN_CONFIGURED="yes"; save_state; fi
}

admins_delete() {
    section_title "Delete Admin"
    echo -ne "${CYAN}Username: ${RESET}"
    read -r u
    [[ -z "$u" ]] && { echo "Empty input."; press_enter; return; }
    local cmd="rebecca cli admin delete --username $u"
    run_cmd "$cmd"
}

admins_change_role() {
    section_title "Change Admin Role"
    echo -e "Usage: rebecca cli admin change-role --username USER --role ROLE"
    echo -e "Roles example: sudo, full_access"
    echo
    echo -ne "${CYAN}Username: ${RESET}"
    read -r u
    [[ -z "$u" ]] && { echo "Empty input."; press_enter; return; }
    echo -ne "${CYAN}New Role: ${RESET}"
    read -r r
    [[ -z "$r" ]] && { echo "Empty input."; press_enter; return; }
    local cmd="rebecca cli admin change-role --username $u --role $r"
    run_cmd "$cmd"
}

admins_import_from_env() {
    section_title "Import Admin from Env"
    echo -e "${WHITE}Runs: ${CYAN}rebecca cli admin import-from-env${RESET}"
    echo -e "Ensure .env has sudo admin variables set."
    echo
    local cmd="rebecca cli admin import-from-env"
    if run_cmd "$cmd"; then ADMIN_CONFIGURED="yes"; save_state; fi
}

admins_update() {
    section_title "Update Admin"
    echo -e "Runs: rebecca cli admin update --username USER [EXTRA]"
    echo -e "Example EXTRA: --password NEWPASS"
    echo
    echo -ne "${CYAN}Username: ${RESET}"
    read -r u
    [[ -z "$u" ]] && { echo "Empty input."; press_enter; return; }
    echo -ne "${CYAN}Extra Args (optional): ${RESET}"
    read -r extra
    local cmd="rebecca cli admin update --username $u $extra"
    run_cmd "$cmd"
}

admins_menu() {
    while true; do
        section_title "Admin Management"
        echo -e "  ${CYAN}1)${RESET} ➕ Create Admin"
        echo -e "  ${CYAN}2)${RESET} ➖ Delete Admin"
        echo -e "  ${CYAN}3)${RESET} 🔁 Change Admin Role"
        echo -e "  ${CYAN}4)${RESET} 📥 Import Admin from Env"
        echo -e "  ${CYAN}5)${RESET} 🛠  Update Admin"
        echo
        echo -e "  ${CYAN}0)${RESET} 🔙 Back"
        echo
        echo -ne "${MAGENTA}Select option [0-9] -> ${RESET}"
        read -r o
        case "$o" in
            1) admins_add ;;
            2) admins_delete ;;
            3) admins_change_role ;;
            4) admins_import_from_env ;;
            5) admins_update ;;
            0) break ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

# ---------- Settings ----------

settings_menu() {
    while true; do
        section_title "Settings"
        echo -e "  ${BLUE}Panel Dir:${RESET}    $PANEL_DIR"
        echo -e "  ${BLUE}Panel Svc:${RESET}    $PANEL_SERVICE_NAME"
        echo -e "  ${BLUE}Node Svc:${RESET}     $NODE_SERVICE_NAME"
        echo -e "  ${BLUE}Certs Dir:${RESET}    $CERTS_BASE_DIR"
        echo -e "  ${BLUE}Domains:${RESET}      $PANEL_DOMAIN"
        echo -e "  ${BLUE}State File:${RESET}   $STATE_FILE"
        echo -e "${THIN_BORDER}"
        echo -e "  ${CYAN}1)${RESET} ✏️  Change Panel Dir"
        echo -e "  ${CYAN}2)${RESET} ✏️  Change Panel Service"
        echo -e "  ${CYAN}3)${RESET} ✏️  Change Node Service"
        echo -e "  ${CYAN}4)${RESET} ✏️  Set Domains Manually"
        echo -e "  ${CYAN}5)${RESET} ✏️  Change Certs Dir"
        echo -e "  ${CYAN}6)${RESET} 🔁 Toggle Admin Config Flag"
        echo
        echo -e "  ${CYAN}0)${RESET} 🔙 Back"
        echo
        echo -ne "${MAGENTA}Select option [0-9] -> ${RESET}"
        read -r o
        case "$o" in
            1) echo -ne "New Panel Dir: "; read -r v; [[ -n "$v" ]] && PANEL_DIR="$v" ;;
            2) echo -ne "New Panel Svc: "; read -r v; [[ -n "$v" ]] && PANEL_SERVICE_NAME="$v" ;;
            3) echo -ne "New Node Svc : "; read -r v; [[ -n "$v" ]] && NODE_SERVICE_NAME="$v" ;;
            4) echo -ne "Domains (comma): "; read -r v; [[ -n "$v" ]] && { PANEL_DOMAIN="$v"; save_state; } ;;
            5) echo -ne "New Certs Dir: "; read -r v; [[ -n "$v" ]] && CERTS_BASE_DIR="$v" ;;
            6) [[ "$ADMIN_CONFIGURED" == "yes" ]] && ADMIN_CONFIGURED="no" || ADMIN_CONFIGURED="yes"; save_state ;;
            0) break ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

# ---------- Rebecca Control (CLI Wrapper) ----------

rebecca_ctrl_menu() {
    while true; do
        section_title "Rebecca Control (Wrapper for 'rebecca' CLI)"
        echo -e "  ${CYAN}1)${RESET} ▶  rebecca up"
        echo -e "  ${CYAN}2)${RESET} ⏹  rebecca down"
        echo -e "  ${CYAN}3)${RESET} 🔁 rebecca restart"
        echo -e "  ${CYAN}4)${RESET} 📊 rebecca status"
        echo -e "  ${CYAN}5)${RESET} 📜 rebecca logs"
        echo -e "  ${CYAN}6)${RESET} 🧰 rebecca edit (docker-compose.yml)"
        echo -e "  ${CYAN}7)${RESET} 🧰 rebecca edit-env (.env)"
        echo -e "  ${CYAN}8)${RESET} 💾 rebecca backup"
        echo -e "  ${CYAN}9)${RESET} 🤖 rebecca backup-service"
        echo -e " ${CYAN}10)${RESET} 🔐 rebecca ssl (built-in)"
        echo -e " ${CYAN}11)${RESET} ❔ rebecca help"
        echo
        echo -e "  ${CYAN}0)${RESET} 🔙 Back"
        echo
        echo -ne "${MAGENTA}Select option [0-9] -> ${RESET}"
        read -r o
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
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

# ---------- Main ----------

main_menu() {
    load_state; detect_runtime_state
    while true; do
        banner
        echo -e "  ${CYAN}1)${RESET} 🧩 Panel Install / Update"
        echo -e "  ${CYAN}2)${RESET} 🌐 Node Install / Update"
        echo -e "  ${CYAN}3)${RESET} 📊 Detailed Status"
        echo -e "  ${CYAN}4)${RESET} 🔐 SSL (Local Certs)"
        echo -e "  ${CYAN}5)${RESET} 👤 Admin Management"
        echo -e "  ${CYAN}6)${RESET} ⚙️  Settings & Config"
        echo -e "  ${CYAN}7)${RESET} 🌍 Domains & SSL Overview"
        echo -e "  ${CYAN}8)${RESET} ⚡ Rebecca Control (Up/Down/Logs...)"
        echo
        echo -e "  ${CYAN}0)${RESET} 🚪 Exit"
        echo
        echo -ne "${MAGENTA}Select option [0-9] -> ${RESET}"
        read -r o
        case "$o" in
            1) panel_menu ;;
            2) node_menu ;;
            3) status_menu ;;
            4) ssl_menu ;;
            5) admins_menu ;;
            6) settings_menu ;;
            7) domains_overview ;;
            8) rebecca_ctrl_menu ;;
            0) echo -e "${GREEN}Goodbye!${RESET}"; exit 0 ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

main_menu
