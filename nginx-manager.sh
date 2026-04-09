#!/bin/bash
# ═══════════════════════════════════════════════════════
#  nginx-manager.sh — Nginx Site Manager
# ═══════════════════════════════════════════════════════

SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
DEFAULT_BLOCK_NAME="_default_drop"
DEFAULT_BLOCK_FILE="$SITES_AVAILABLE/$DEFAULT_BLOCK_NAME"
SNAKEOIL_DIR="/etc/nginx/ssl/snakeoil"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Raw URL for self-update (override: NGINX_MANAGER_UPDATE_URL='https://.../raw/.../nginx-manager.sh')
SELF_UPDATE_URL="${NGINX_MANAGER_UPDATE_URL:-https://raw.githubusercontent.com/DmitryAce/scripts/main/nginx-manager.sh}"

SHORTCUT_NXM="/usr/local/bin/nxm"
SHORTCUT_DM="/usr/local/bin/dm"

# ────────────────────────────────────────────────────────
#  UTILITIES
# ────────────────────────────────────────────────────────

require_root() {
  [[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root (sudo)${RESET}"; exit 1; }
}

resolve_this_script_path() {
  local s="${BASH_SOURCE[0]}"
  if [[ "$s" != */* ]]; then
    s=$(command -v -- "$s" 2>/dev/null || command -v -- "${0##*/}" 2>/dev/null || printf '%s' "$s")
  fi
  if readlink -f "$s" &>/dev/null; then
    readlink -f "$s"
  elif command -v realpath &>/dev/null && realpath "$s" &>/dev/null; then
    realpath "$s"
  else
    echo "$(cd "$(dirname "$s")" && pwd)/$(basename "$s")"
  fi
}

self_update() {
  local dest tmp
  dest=$(resolve_this_script_path)

  if ! command -v curl &>/dev/null; then
    echo -e "${RED}curl not found — install curl${RESET}"
    return 1
  fi

  echo -e "  ${CYAN}Self-update${RESET} → ${DIM}$dest${RESET}"
  echo -e "  ${DIM}▸ $SELF_UPDATE_URL${RESET}\n"

  tmp=$(mktemp) || return 1
  if ! curl -fsSL "$SELF_UPDATE_URL" -o "$tmp"; then
    rm -f "$tmp"
    echo -e "  ${RED}✗ Download failed (network / URL)${RESET}"
    return 1
  fi

  if ! head -1 "$tmp" | grep -q '^#!/bin/bash'; then
    rm -f "$tmp"
    echo -e "  ${RED}✗ File is not a bash script — wrong URL?${RESET}"
    return 1
  fi

  chmod +x "$tmp"
  if ! install -m 755 "$tmp" "$dest"; then
    rm -f "$tmp"
    echo -e "  ${RED}✗ Cannot write $dest${RESET}"
    return 1
  fi
  rm -f "$tmp"
  echo -e "\n  ${GREEN}✓ Updated${RESET}  ${DIM}Run again: nginx-manager${RESET}\n"
  return 0
}

print_header() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ███╗   ██╗ ██████╗ ██╗███╗   ██╗██╗  ██╗"
  echo "  ████╗  ██║██╔════╝ ██║████╗  ██║╚██╗██╔╝"
  echo "  ██╔██╗ ██║██║  ███╗██║██╔██╗ ██║ ╚███╔╝ "
  echo "  ██║╚██╗██║██║   ██║██║██║╚██╗██║ ██╔██╗ "
  echo "  ██║ ╚████║╚██████╔╝██║██║ ╚████║██╔╝ ██╗"
  echo "  ╚═╝  ╚═══╝ ╚═════╝ ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝"
  echo -e "${RESET}${DIM}  Nginx Site Manager${RESET}"
  echo -e "${DIM}  ─────────────────────────────────────────${RESET}"
  echo
}

confirm() {
  local prompt="${1:-Are you sure?}"
  read -rp "$(echo -e "  ${YELLOW}⚠  ${prompt} [y/N]: ${RESET}")" ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

pause() {
  echo
  read -rp "$(echo -e "  ${DIM}Press Enter to continue...${RESET}")"
}

nginx_reload() {
  echo
  echo -e "  ${DIM}▸ nginx -t${RESET}"
  local out
  out=$(nginx -t 2>&1)
  if echo "$out" | grep -q "syntax is ok"; then
    echo -e "  ${GREEN}✓ Config OK${RESET}"
    echo -e "  ${DIM}▸ systemctl reload nginx${RESET}"
    if systemctl reload nginx 2>&1; then
      echo -e "  ${GREEN}✓ Nginx reloaded${RESET}"
    else
      echo -e "  ${RED}✗ Reload failed — try option [9] restart${RESET}"
    fi
  else
    echo -e "  ${RED}✗ Config test failed — nginx NOT reloaded${RESET}"
    echo
    echo "$out" | sed 's/^/    /'
  fi
}

# ────────────────────────────────────────────────────────
#  NGINX VERSION HELPERS
# ────────────────────────────────────────────────────────

nginx_version_gte() {
  local need_maj=$1 need_min=$2 need_pat=$3
  local ver
  ver=$(nginx -v 2>&1 | grep -oP '(?<=nginx/)\d+\.\d+\.\d+' || echo "0.0.0")
  local maj min pat
  IFS='.' read -r maj min pat <<< "$ver"
  (( maj > need_maj )) && return 0
  (( maj == need_maj && min > need_min )) && return 0
  (( maj == need_maj && min == need_min && pat >= need_pat )) && return 0
  return 1
}

nginx_has_ssl_reject() {
  nginx_version_gte 1 19 4
}

# ────────────────────────────────────────────────────────
#  SNAKEOIL CERT (fallback for nginx < 1.19.4)
# ────────────────────────────────────────────────────────

ensure_snakeoil_cert() {
  if [[ -f "$SNAKEOIL_DIR/cert.pem" && -f "$SNAKEOIL_DIR/key.pem" ]]; then
    return 0
  fi
  echo -e "  ${DIM}▸ Generating snakeoil cert (nginx < 1.19.4 fallback)...${RESET}"
  mkdir -p "$SNAKEOIL_DIR"
  if openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$SNAKEOIL_DIR/key.pem" \
      -out    "$SNAKEOIL_DIR/cert.pem" \
      -subj   "/CN=_" 2>/dev/null; then
    chmod 600 "$SNAKEOIL_DIR/key.pem"
    echo -e "  ${GREEN}✓ Snakeoil cert created: $SNAKEOIL_DIR${RESET}"
  else
    echo -e "  ${RED}✗ openssl failed — is openssl installed?${RESET}"
    return 1
  fi
}

# ────────────────────────────────────────────────────────
#  DEFAULT_SERVER CONFLICT DETECTION
# ────────────────────────────────────────────────────────

find_default_server_conflicts() {
  # Returns names of enabled configs (other than our drop block) that
  # contain "listen ... default_server" — they would conflict with ours.
  for f in "$SITES_ENABLED"/*; do
    [[ -e "$f" ]] || continue
    local name
    name=$(basename "$f")
    [[ "$name" == "$DEFAULT_BLOCK_NAME" ]] && continue
    local real
    real=$(readlink -f "$f")
    if grep -qP 'listen\s+.*\bdefault_server\b' "$real" 2>/dev/null; then
      echo "$name"
    fi
  done
}

disable_default_conflicts() {
  local found=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    rm -f "$SITES_ENABLED/$name"
    echo -e "  ${YELLOW}↳ Disabled conflicting default_server site: ${BOLD}$name${RESET}"
    found=1
  done < <(find_default_server_conflicts)
  [[ $found -eq 1 ]] && echo
}

# ────────────────────────────────────────────────────────
#  DEFAULT DROP BLOCK
# ────────────────────────────────────────────────────────

default_block_status() {
  if [[ -L "$SITES_ENABLED/$DEFAULT_BLOCK_NAME" ]]; then
    echo "enabled"
  elif [[ -f "$DEFAULT_BLOCK_FILE" ]]; then
    echo "disabled"
  else
    echo "missing"
  fi
}

write_default_block() {
  if nginx_has_ssl_reject; then
    cat > "$DEFAULT_BLOCK_FILE" <<'EOF'
# _default_drop — silently close all connections with unknown domain
server {
    listen 80  default_server;
    listen 443 ssl default_server;

    ssl_reject_handshake on;   # nginx >= 1.19.4: abort TLS before cert exchange

    server_name _;
    return 444;
}
EOF
  else
    ensure_snakeoil_cert || return 1
    cat > "$DEFAULT_BLOCK_FILE" <<EOF
# _default_drop — silently close all connections with unknown domain
# ssl_reject_handshake not available (nginx < 1.19.4); using snakeoil cert
server {
    listen 80  default_server;
    listen 443 ssl default_server;

    ssl_certificate     $SNAKEOIL_DIR/cert.pem;
    ssl_certificate_key $SNAKEOIL_DIR/key.pem;

    server_name _;
    return 444;
}
EOF
  fi
  echo -e "  ${GREEN}✓ Config written: $DEFAULT_BLOCK_FILE${RESET}"
}

manage_default_block() {
  while true; do
    print_header
    echo -e "  ${BOLD}Default Drop Block${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
    echo
    echo -e "  Drops all connections that don't match a known domain."
    echo -e "  Protects against IP-direct access, scanners and bots."
    echo

    if nginx_has_ssl_reject; then
      echo -e "  ${DIM}  listen 80  default_server;${RESET}"
      echo -e "  ${DIM}  listen 443 ssl default_server;${RESET}"
      echo -e "  ${DIM}  ssl_reject_handshake on;${RESET}"
      echo -e "  ${DIM}  server_name _; return 444;${RESET}"
    else
      echo -e "  ${DIM}  listen 80  default_server;${RESET}"
      echo -e "  ${DIM}  listen 443 ssl default_server;${RESET}"
      echo -e "  ${DIM}  ssl_certificate     $SNAKEOIL_DIR/cert.pem;${RESET}"
      echo -e "  ${DIM}  ssl_certificate_key $SNAKEOIL_DIR/key.pem;${RESET}"
      echo -e "  ${DIM}  server_name _; return 444;${RESET}"
      echo -e "  ${YELLOW}  ⚠  nginx < 1.19.4 detected — snakeoil cert fallback${RESET}"
    fi
    echo

    # Warn about any conflicts
    local conflict_list
    conflict_list=$(find_default_server_conflicts)
    if [[ -n "$conflict_list" ]]; then
      echo -e "  ${YELLOW}⚠  Conflicting default_server sites (will be disabled on enable):${RESET}"
      while IFS= read -r c; do
        [[ -n "$c" ]] && echo -e "     ${YELLOW}• $c${RESET}"
      done <<< "$conflict_list"
      echo
    fi

    local status
    status=$(default_block_status)

    case "$status" in
      enabled)
        echo -e "  Status: ${GREEN}${BOLD}● ACTIVE${RESET} — unknown connections are being dropped"
        echo
        echo -e "  ${CYAN}[1]${RESET}  Disable block"
        echo -e "  ${CYAN}[2]${RESET}  Recreate & re-enable config (reset)"
        echo -e "  ${DIM}[b]${RESET}  Back"
        echo
        read -rp "  Choose: " opt
        case "$opt" in
          1)
            rm -f "$SITES_ENABLED/$DEFAULT_BLOCK_NAME"
            echo -e "  ${YELLOW}↳ Drop block disabled${RESET}"
            nginx_reload; pause; return ;;
          2)
            disable_default_conflicts
            write_default_block || { pause; return; }
            ln -sf "$DEFAULT_BLOCK_FILE" "$SITES_ENABLED/$DEFAULT_BLOCK_NAME"
            nginx_reload; pause; return ;;
          b|B) return ;;
          *) ;;
        esac
        ;;

      disabled)
        echo -e "  Status: ${YELLOW}${BOLD}○ INACTIVE${RESET} — config exists but not enabled"
        echo
        echo -e "  ${CYAN}[1]${RESET}  Enable block"
        echo -e "  ${CYAN}[2]${RESET}  Recreate config (reset, keep disabled)"
        echo -e "  ${RED}[3]${RESET}  Delete config"
        echo -e "  ${DIM}[b]${RESET}  Back"
        echo
        read -rp "  Choose: " opt
        case "$opt" in
          1)
            disable_default_conflicts
            ln -sf "$DEFAULT_BLOCK_FILE" "$SITES_ENABLED/$DEFAULT_BLOCK_NAME"
            echo -e "  ${GREEN}✓ Drop block enabled${RESET}"
            nginx_reload; pause; return ;;
          2)
            write_default_block || { pause; return; }
            echo -e "  ${DIM}(Still disabled — use [1] to enable)${RESET}"
            pause; return ;;
          3)
            confirm "Delete the drop block config?" && {
              rm -f "$DEFAULT_BLOCK_FILE"
              echo -e "  ${GREEN}✓ Deleted${RESET}"
            }
            pause; return ;;
          b|B) return ;;
          *) ;;
        esac
        ;;

      missing)
        echo -e "  Status: ${RED}${BOLD}✗ NOT INSTALLED${RESET}"
        echo
        echo -e "  ${CYAN}[1]${RESET}  Create and enable  ${DIM}(recommended)${RESET}"
        echo -e "  ${CYAN}[2]${RESET}  Create only (keep disabled)"
        echo -e "  ${DIM}[b]${RESET}  Back"
        echo
        read -rp "  Choose: " opt
        case "$opt" in
          1)
            disable_default_conflicts
            write_default_block || { pause; return; }
            ln -sf "$DEFAULT_BLOCK_FILE" "$SITES_ENABLED/$DEFAULT_BLOCK_NAME"
            echo -e "  ${GREEN}✓ Drop block created and enabled${RESET}"
            nginx_reload; pause; return ;;
          2)
            write_default_block || { pause; return; }
            echo -e "  ${DIM}(Disabled — use [1] to enable)${RESET}"
            pause; return ;;
          b|B) return ;;
          *) ;;
        esac
        ;;
    esac
  done
}

# ────────────────────────────────────────────────────────
#  LIST SITES
# ────────────────────────────────────────────────────────

list_sites() {
  print_header
  echo -e "  ${BOLD}Sites Overview${RESET}"
  echo -e "  ${DIM}────────────────────────────────────${RESET}"
  echo

  local files=("$SITES_AVAILABLE"/*)
  if [[ ! -e "${files[0]}" ]]; then
    echo -e "  ${DIM}No sites found in $SITES_AVAILABLE${RESET}"
    pause; return
  fi

  printf "  ${BOLD}%-35s %-12s${RESET}\n" "SITE" "STATUS"
  printf "  ${DIM}%-35s %-12s${RESET}\n" "───────────────────────────────────" "────────────"

  for f in "$SITES_AVAILABLE"/*; do
    local name
    name=$(basename "$f")
    if [[ -L "$SITES_ENABLED/$name" ]]; then
      printf "  ${GREEN}%-35s %-12s${RESET}\n" "$name" "● enabled"
    else
      printf "  ${RED}%-35s %-12s${RESET}\n" "$name" "○ disabled"
    fi
  done

  pause
}

# ────────────────────────────────────────────────────────
#  VIEW / EDIT SITE CONFIGS
# ────────────────────────────────────────────────────────

collect_site_config_names() {
  local -n _arr=$1
  _arr=()
  local f
  for f in "$SITES_AVAILABLE"/*; do
    [[ -f "$f" ]] || continue
    _arr+=("$(basename "$f")")
  done
  if [[ ${#_arr[@]} -eq 0 ]]; then
    return 0
  fi
  local sorted=()
  mapfile -t sorted < <(printf '%s\n' "${_arr[@]}" | sort -u)
  _arr=("${sorted[@]}")
}

view_config_file() {
  local path="$1"
  echo
  echo -e "  ${BOLD}Просмотр файла${RESET}  ${DIM}$path${RESET}"
  echo -e "  ${YELLOW}────────────────────────────────────────────────${RESET}"
  echo -e "  ${GREEN}q${RESET}  — выйти в меню (в любой момент)"
  echo -e "  ${GREEN}Esc${RESET} — если внизу появилось «${BOLD}:${RESET}», сначала Esc, потом ${GREEN}q${RESET}"
  echo -e "  ${DIM}↑/↓  PgUp/PgDn — листать · дошли до конца — снова ${GREEN}q${RESET} или выход автоматически${RESET}"
  echo -e "  ${YELLOW}────────────────────────────────────────────────${RESET}"
  echo
  if command -v less &>/dev/null; then
    # -E: выход при первом достижении конца файла (не «зависать» на END)
    # -X: не чистить весь экран после выхода — удобнее вернуться в меню
    command less -E -X "$path"
  elif command -v more &>/dev/null; then
    echo -e "  ${DIM}more: пробел — далее, q — выход${RESET}\n"
    command more "$path"
  else
    sed 's/^/    /' "$path"
    echo
  fi
}

edit_config_file() {
  local path="$1"
  echo
  echo -e "  ${DIM}▸ Editing $path${RESET}"
  echo -e "  ${DIM}  (set EDITOR or VISUAL; else sensible-editor / nano / vi)${RESET}\n"
  if command -v sensible-editor &>/dev/null; then
    sensible-editor "$path"
  elif [[ -n "${VISUAL:-}" ]]; then
    # shellcheck disable=SC2086
    $VISUAL "$path"
  elif [[ -n "${EDITOR:-}" ]]; then
    # shellcheck disable=SC2086
    $EDITOR "$path"
  elif command -v nano &>/dev/null; then
    nano "$path"
  else
    vi "$path"
  fi
}

manage_site_configs() {
  while true; do
    print_header
    echo -e "  ${BOLD}View / edit site configs${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
    echo
    echo -e "  ${DIM}Files in $SITES_AVAILABLE${RESET}"
    echo

    local names=()
    collect_site_config_names names

    if [[ ${#names[@]} -eq 0 ]]; then
      echo -e "  ${DIM}No config files found.${RESET}"
      pause
      return
    fi

    local i badge
    for i in "${!names[@]}"; do
      if [[ -L "$SITES_ENABLED/${names[$i]}" ]]; then
        badge="${GREEN}● enabled${RESET}"
      else
        badge="${RED}○ disabled${RESET}"
      fi
      echo -e "  ${CYAN}[$((i + 1))]${RESET}  ${names[$i]}  $(echo -e "$badge")"
    done
    echo
    echo -e "  ${DIM}[b]${RESET}  Back to main menu"
    echo

    read -rp "  Select config number: " choice
    case "$choice" in
      b|B) return ;;
    esac

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#names[@]} )); then
      echo -e "  ${RED}Invalid choice${RESET}"
      sleep 1
      continue
    fi

    local site="${names[$((choice - 1))]}"
    local cfg="$SITES_AVAILABLE/$site"

    while true; do
      print_header
      echo -e "  ${BOLD}Config:${RESET}  $site"
      echo -e "  ${DIM}$cfg${RESET}"
      echo
      echo -e "  ${CYAN}[1]${RESET}  View in pager  ${DIM}(less / more)${RESET}"
      echo -e "  ${CYAN}[2]${RESET}  Edit in editor  ${DIM}(EDITOR / nano / vi)${RESET}"
      echo -e "  ${CYAN}[3]${RESET}  Test only       ${DIM}(nginx -t)${RESET}"
      echo -e "  ${CYAN}[4]${RESET}  Test & reload nginx"
      echo -e "  ${DIM}[b]${RESET}  Pick another config"
      echo

      read -rp "  Choose: " act
      case "$act" in
        1) view_config_file "$cfg"; pause ;;
        2) edit_config_file "$cfg"; pause ;;
        3) nginx_check; ;;
        4) nginx_reload; pause ;;
        b|B) break ;;
        *) ;;
      esac
    done
  done
}

# ────────────────────────────────────────────────────────
#  ENABLE SITE
# ────────────────────────────────────────────────────────

enable_site() {
  print_header
  echo -e "  ${BOLD}Enable a Site${RESET}\n"

  local disabled=()
  for f in "$SITES_AVAILABLE"/*; do
    [[ ! -e "$f" ]] && continue
    local name
    name=$(basename "$f")
    [[ ! -L "$SITES_ENABLED/$name" ]] && disabled+=("$name")
  done

  if [[ ${#disabled[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}All sites are already enabled.${RESET}"
    pause; return
  fi

  echo -e "  ${DIM}Disabled sites:${RESET}\n"
  for i in "${!disabled[@]}"; do
    echo -e "  ${CYAN}[$((i+1))]${RESET}  ${disabled[$i]}"
  done
  echo

  read -rp "  Select site number: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#disabled[@]} )); then
    echo -e "  ${RED}Invalid choice${RESET}"; pause; return
  fi

  local site="${disabled[$((choice-1))]}"
  ln -sf "$SITES_AVAILABLE/$site" "$SITES_ENABLED/$site"
  echo -e "  ${GREEN}✓ Enabled: $site${RESET}"
  nginx_reload
  pause
}

# ────────────────────────────────────────────────────────
#  DISABLE SITE
# ────────────────────────────────────────────────────────

disable_site() {
  print_header
  echo -e "  ${BOLD}Disable a Site${RESET}\n"

  local enabled=()
  for f in "$SITES_ENABLED"/*; do
    [[ -L "$f" ]] && enabled+=("$(basename "$f")")
  done

  if [[ ${#enabled[@]} -eq 0 ]]; then
    echo -e "  ${YELLOW}No enabled sites found.${RESET}"
    pause; return
  fi

  echo -e "  ${DIM}Enabled sites:${RESET}\n"
  for i in "${!enabled[@]}"; do
    echo -e "  ${CYAN}[$((i+1))]${RESET}  ${enabled[$i]}"
  done
  echo

  read -rp "  Select site number: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#enabled[@]} )); then
    echo -e "  ${RED}Invalid choice${RESET}"; pause; return
  fi

  local site="${enabled[$((choice-1))]}"
  if confirm "Disable $site?"; then
    rm -f "$SITES_ENABLED/$site"
    echo -e "  ${GREEN}✓ Disabled: $site${RESET}"
    nginx_reload
  fi
  pause
}

# ────────────────────────────────────────────────────────
#  GENERATE SITE CONFIG
# ────────────────────────────────────────────────────────

generate_site_config() {
  local domain="$1" port="$2" static_dir="$3" media_dir="$4"

  echo "server {"
  echo "    listen 80;"
  echo "    server_name ${domain} www.${domain};"
  echo ""

  if [[ -n "$static_dir" ]]; then
    echo "    location /static/ {"
    echo "        alias ${static_dir}/;"
    echo "        expires 30d;"
    echo "        add_header Cache-Control \"public, immutable\";"
    echo "    }"
    echo ""
  fi

  if [[ -n "$media_dir" ]]; then
    echo "    location /media/ {"
    echo "        alias ${media_dir}/;"
    echo "        expires 7d;"
    echo "        add_header Cache-Control \"public, max-age=604800\";"
    echo "    }"
    echo ""
  fi

  cat <<EOF
    location / {
        proxy_pass         http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        'upgrade';
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
}

# ────────────────────────────────────────────────────────
#  ADD NEW SITE
# ────────────────────────────────────────────────────────

add_site() {
  print_header
  echo -e "  ${BOLD}Add New Site Config${RESET}\n"

  read -rp "  $(echo -e "${CYAN}Domain name${RESET} (e.g. example.com): ")" domain
  if [[ -z "$domain" ]]; then
    echo -e "  ${RED}Domain cannot be empty.${RESET}"; pause; return
  fi

  read -rp "  $(echo -e "${CYAN}App port${RESET} on loopback (e.g. 3000): ")" port
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo -e "  ${RED}Invalid port.${RESET}"; pause; return
  fi

  echo
  echo -e "  ${CYAN}Static directory${RESET} ${DIM}(served at /static/, e.g. CSS/JS)${RESET}"
  read -rp "  Path (or Enter to skip): " static_dir
  if [[ -n "$static_dir" && ! -d "$static_dir" ]]; then
    echo -e "  ${YELLOW}⚠  Directory does not exist — creating it...${RESET}"
    mkdir -p "$static_dir" && echo -e "  ${GREEN}✓ Created $static_dir${RESET}"
  fi

  echo
  echo -e "  ${CYAN}Media directory${RESET} ${DIM}(served at /media/, e.g. uploads)${RESET}"
  read -rp "  Path (or Enter to skip): " media_dir
  if [[ -n "$media_dir" && ! -d "$media_dir" ]]; then
    echo -e "  ${YELLOW}⚠  Directory does not exist — creating it...${RESET}"
    mkdir -p "$media_dir" && echo -e "  ${GREEN}✓ Created $media_dir${RESET}"
  fi

  local config_file="$SITES_AVAILABLE/$domain"

  if [[ -f "$config_file" ]]; then
    echo -e "\n  ${YELLOW}⚠  Config already exists for $domain${RESET}"
    confirm "Overwrite?" || { pause; return; }
  fi

  generate_site_config "$domain" "$port" "$static_dir" "$media_dir" > "$config_file"
  echo -e "\n  ${GREEN}✓ Config written: $config_file${RESET}"

  echo
  if confirm "Enable site now?"; then
    ln -sf "$config_file" "$SITES_ENABLED/$domain"
    echo -e "  ${GREEN}✓ Site enabled${RESET}"
    nginx_reload

    echo
    if confirm "Obtain SSL certificate with Certbot?"; then
      if command -v certbot &>/dev/null; then
        echo -e "  ${DIM}Running certbot...${RESET}\n"
        certbot --nginx -d "$domain" -d "www.$domain"
        echo -e "\n  ${GREEN}✓ SSL configured${RESET}"
        nginx_reload
      else
        echo -e "  ${RED}✗ certbot not found${RESET}"
        echo -e "  ${DIM}  apt install certbot python3-certbot-nginx${RESET}"
      fi
    fi
  fi

  pause
}

# ────────────────────────────────────────────────────────
#  DELETE SITE
# ────────────────────────────────────────────────────────

delete_site() {
  print_header
  echo -e "  ${BOLD}Delete a Site Config${RESET}\n"

  local names=()
  for f in "$SITES_AVAILABLE"/*; do
    [[ -e "$f" ]] && names+=("$(basename "$f")")
  done

  if [[ ${#names[@]} -eq 0 ]]; then
    echo -e "  ${DIM}No sites found.${RESET}"
    pause; return
  fi

  echo -e "  ${DIM}Available sites:${RESET}\n"
  for i in "${!names[@]}"; do
    local badge
    if [[ -L "$SITES_ENABLED/${names[$i]}" ]]; then
      badge="${GREEN}● enabled${RESET}"
    else
      badge="${RED}○ disabled${RESET}"
    fi
    echo -e "  ${CYAN}[$((i+1))]${RESET}  ${names[$i]}  $(echo -e "$badge")"
  done
  echo

  read -rp "  Select site to delete: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#names[@]} )); then
    echo -e "  ${RED}Invalid choice${RESET}"; pause; return
  fi

  local site="${names[$((choice-1))]}"
  echo -e "\n  ${RED}Permanently delete: ${BOLD}$site${RESET}"

  if confirm "Delete $site?"; then
    [[ -L "$SITES_ENABLED/$site" ]] && rm -f "$SITES_ENABLED/$site" && \
      echo -e "  ${YELLOW}↳ Removed symlink from sites-enabled${RESET}"
    rm -f "$SITES_AVAILABLE/$site"
    echo -e "  ${GREEN}✓ Deleted: $site${RESET}"
    nginx_reload
  fi
  pause
}

# ────────────────────────────────────────────────────────
#  NGINX CONFIG TEST
# ────────────────────────────────────────────────────────

nginx_check() {
  print_header
  echo -e "  ${BOLD}Nginx Config Test${RESET}"
  echo -e "  ${DIM}────────────────────────────────────${RESET}"
  echo
  echo -e "  ${DIM}▸ nginx -t${RESET}\n"
  local out
  out=$(nginx -t 2>&1)
  echo "$out" | sed 's/^/    /'
  echo
  if echo "$out" | grep -q "syntax is ok"; then
    echo -e "  ${GREEN}${BOLD}✓ Config is valid${RESET}"
  else
    echo -e "  ${RED}${BOLD}✗ Config has errors — fix before restarting${RESET}"
  fi
  pause
}

# ────────────────────────────────────────────────────────
#  NGINX RESTART
# ────────────────────────────────────────────────────────

nginx_restart() {
  print_header
  echo -e "  ${BOLD}Restart Nginx${RESET}"
  echo -e "  ${DIM}────────────────────────────────────${RESET}"
  echo
  echo -e "  ${DIM}▸ nginx -t${RESET}\n"
  local out
  out=$(nginx -t 2>&1)
  echo "$out" | sed 's/^/    /'
  echo

  if echo "$out" | grep -q "syntax is ok"; then
    echo -e "  ${GREEN}✓ Config OK${RESET}"
    echo
    if confirm "Restart nginx now?"; then
      echo
      echo -e "  ${DIM}▸ systemctl restart nginx${RESET}\n"
      if systemctl restart nginx; then
        echo -e "  ${GREEN}${BOLD}✓ Nginx restarted successfully${RESET}"
      else
        echo -e "  ${RED}${BOLD}✗ Restart failed${RESET}"
        echo -e "  ${DIM}  journalctl -xe | grep nginx${RESET}"
      fi
    fi
  else
    echo -e "  ${RED}${BOLD}✗ Config errors — restart aborted${RESET}"
    echo -e "  ${DIM}  Fix the errors above, then try again.${RESET}"
  fi
  pause
}

# ────────────────────────────────────────────────────────
#  SETTINGS (symlinks nxm / dm)
# ────────────────────────────────────────────────────────

resolve_nginx_manager_bin() {
  local p
  p=$(command -v nginx-manager 2>/dev/null) && { echo "$p"; return; }
  echo "/usr/local/bin/nginx-manager"
}

resolve_docker_manager_bin() {
  local p
  p=$(command -v docker-manager 2>/dev/null) && { echo "$p"; return; }
  echo "/usr/local/bin/docker-manager"
}

shortcut_nxm_enabled() {
  [[ -L "$SHORTCUT_NXM" ]]
}

shortcut_dm_enabled() {
  [[ -L "$SHORTCUT_DM" ]]
}

warn_conflict() {
  local short="$1"
  local p
  p=$(command -v -- "$short" 2>/dev/null || true)
  [[ -z "$p" ]] && return 0
  [[ "$p" == "$SHORTCUT_NXM" || "$p" == "$SHORTCUT_DM" ]] && return 0
  echo -e "  ${YELLOW}⚠  «${short}» уже занято:${RESET} ${BOLD}$p${RESET}"
  return 1
}

_create_symlink() {
  local link="$1" target="$2"
  ln -sf "$target" "$link" 2>/dev/null && return 0
  echo -e "  ${RED}✗ Не удалось создать $link → $target${RESET}"
  return 1
}

_remove_symlink() {
  local link="$1"
  rm -f "$link" 2>/dev/null && return 0
  echo -e "  ${RED}✗ Не удалось удалить $link${RESET}"
  return 1
}

toggle_nxm() {
  if shortcut_nxm_enabled; then
    if confirm "Удалить симлинк nxm?"; then
      _remove_symlink "$SHORTCUT_NXM" && echo -e "  ${GREEN}✓ nxm удалён${RESET}"
    fi
  else
    warn_conflict nxm || true
    local bin
    bin=$(resolve_nginx_manager_bin)
    echo -e "  ${DIM}Будет: $SHORTCUT_NXM → $bin${RESET}"
    if confirm "Создать симлинк nxm?"; then
      _create_symlink "$SHORTCUT_NXM" "$bin" && echo -e "  ${GREEN}✓ nxm создан — работает сразу${RESET}"
    fi
  fi
}

toggle_dm() {
  if shortcut_dm_enabled; then
    if confirm "Удалить симлинк dm?"; then
      _remove_symlink "$SHORTCUT_DM" && echo -e "  ${GREEN}✓ dm удалён${RESET}"
    fi
  else
    warn_conflict dm || true
    local bin
    bin=$(resolve_docker_manager_bin)
    echo -e "  ${DIM}Будет: $SHORTCUT_DM → $bin${RESET}"
    if confirm "Создать симлинк dm?"; then
      _create_symlink "$SHORTCUT_DM" "$bin" && echo -e "  ${GREEN}✓ dm создан — работает сразу${RESET}"
    fi
  fi
}

settings_menu() {
  while true; do
    print_header
    echo -e "  ${BOLD}Settings${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
    echo -e "  ${DIM}Симлинки в /usr/local/bin — работают сразу, в любой оболочке.${RESET}"
    echo
    local nxm_st dm_st
    if shortcut_nxm_enabled; then
      nxm_st="${GREEN}${BOLD}● активен${RESET}  ${DIM}→ $(readlink -f "$SHORTCUT_NXM" 2>/dev/null)${RESET}"
    else
      nxm_st="${RED}○ выключен${RESET}"
    fi
    if shortcut_dm_enabled; then
      dm_st="${GREEN}${BOLD}● активен${RESET}  ${DIM}→ $(readlink -f "$SHORTCUT_DM" 2>/dev/null)${RESET}"
    else
      dm_st="${RED}○ выключен${RESET}"
    fi
    echo -e "  nxm  ${DIM}(nginx-manager)${RESET}     $(echo -e "$nxm_st")"
    echo -e "  dm   ${DIM}(docker-manager)${RESET}    $(echo -e "$dm_st")"
    echo
    echo -e "  ${CYAN}[1]${RESET}  Переключить  nxm"
    echo -e "  ${CYAN}[2]${RESET}  Переключить  dm"
    echo -e "  ${DIM}[b]${RESET}  Назад"
    echo

    read -rp "  Choose: " sopt
    case "$sopt" in
      1) toggle_nxm; pause ;;
      2) toggle_dm; pause ;;
      b|B) return ;;
      *) ;;
    esac
  done
}

# ────────────────────────────────────────────────────────
#  MAIN MENU
# ────────────────────────────────────────────────────────

main_menu() {
  while true; do
    print_header
    echo -e "  ${BOLD}Main Menu${RESET}\n"
    echo -e "  ${CYAN}[1]${RESET}  List all sites"
    echo -e "  ${CYAN}[2]${RESET}  Enable a site"
    echo -e "  ${CYAN}[3]${RESET}  Disable a site"
    echo -e "  ${CYAN}[4]${RESET}  Add new site config"
    echo -e "  ${CYAN}[5]${RESET}  Delete a site config"
    echo -e "  ${CYAN}[6]${RESET}  View / edit site config  ${DIM}(pager + editor)${RESET}"

    local db_status badge
    db_status=$(default_block_status)
    case "$db_status" in
      enabled)  badge="${GREEN}● active${RESET}" ;;
      disabled) badge="${YELLOW}○ inactive${RESET}" ;;
      *)        badge="${RED}✗ not installed${RESET}" ;;
    esac
    echo -e "  ${CYAN}[7]${RESET}  Default drop block       $(echo -e "$badge")"

    echo -e "  ${DIM}  ─────────────────────────────────${RESET}"
    echo -e "  ${CYAN}[8]${RESET}  Test config  ${DIM}(nginx -t)${RESET}"
    echo -e "  ${CYAN}[9]${RESET}  Restart nginx  ${DIM}(systemctl restart)${RESET}"
    echo
    echo -e "  ${CYAN}[s]${RESET}  Settings  ${DIM}(nxm / dm)${RESET}"
    echo -e "  ${DIM}[q]${RESET}  Quit"
    echo

    read -rp "  $(echo -e "${BOLD}Choose:${RESET} ")" opt
    case "$opt" in
      1) list_sites ;;
      2) enable_site ;;
      3) disable_site ;;
      4) add_site ;;
      5) delete_site ;;
      6) manage_site_configs ;;
      7) manage_default_block ;;
      8) nginx_check ;;
      9) nginx_restart ;;
      s|S) settings_menu ;;
      q|Q) echo -e "\n  ${DIM}Bye!${RESET}\n"; exit 0 ;;
      *) echo -e "  ${RED}Unknown option${RESET}"; sleep 1 ;;
    esac
  done
}

if [[ "${1:-}" == "update" ]]; then
  require_root
  self_update || exit 1
  exit 0
fi

require_root
main_menu