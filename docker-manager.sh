#!/bin/bash
# ═══════════════════════════════════════════════════════
#  docker-manager.sh — Interactive Docker TUI
# ═══════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# По умолчанию GitHub; если пушите только в GitLab — один раз поставьте скрипт вручную, затем:
#   export DOCKER_MANAGER_UPDATE_URL='https://gitlab.com/GROUP/PROJECT/-/raw/main/scripts/docker-manager/docker-manager.sh'
#   docker-manager update
SELF_UPDATE_URL="${DOCKER_MANAGER_UPDATE_URL:-https://raw.githubusercontent.com/DmitryAce/scripts/main/docker-manager.sh}"

# ────────────────────────────────────────────────────────
#  UTILITIES
# ────────────────────────────────────────────────────────

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
  if install -m 755 "$tmp" "$dest" 2>/dev/null; then
    :
  elif sudo install -m 755 "$tmp" "$dest" 2>/dev/null; then
    :
  else
    rm -f "$tmp"
    echo -e "  ${RED}✗ Cannot write $dest — run: sudo docker-manager update${RESET}"
    return 1
  fi
  rm -f "$tmp"
  echo -e "\n  ${GREEN}✓ Updated${RESET}  ${DIM}Run again: docker-manager${RESET}\n"
  return 0
}

require_docker() {
  if ! command -v docker &>/dev/null; then
    echo -e "${RED}docker not found in PATH${RESET}"
    echo -e "  ${DIM}Install Docker Engine and try again.${RESET}"
    exit 1
  fi
  if ! docker info &>/dev/null; then
    echo -e "${RED}Cannot connect to Docker daemon${RESET}"
    echo -e "  ${DIM}Add your user to group docker: sudo usermod -aG docker \"\$USER\" && newgrp docker${RESET}"
    echo -e "  ${DIM}Or run: sudo $0${RESET}"
    exit 1
  fi
}

print_header() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "   ██████╗  ██████╗  ██████╗██╗  ██╗███████╗██████╗ "
  echo "   ██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝██╔════╝██╔══██╗"
  echo "   ██║  ██║██║   ██║██║     █████╔╝ █████╗  ██████╔╝"
  echo "   ██║  ██║██║   ██║██║     ██╔═██╗ ██╔══╝  ██╔══██╗"
  echo "   ██████╔╝╚██████╔╝╚██████╗██║  ██╗███████╗██║  ██║"
  echo "   ╚═════╝  ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝"
  echo -e "${RESET}${DIM}  Docker Manager${RESET}"
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

# Sets SELECTED_NAME to chosen container name, or empty on cancel/invalid
pick_container() {
  local mode="${1:-all}" # all | running
  SELECTED_NAME=""
  local names=()
  if [[ "$mode" == running ]]; then
    mapfile -t names < <(docker ps --format '{{.Names}}' 2>/dev/null)
  else
    mapfile -t names < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
  fi

  if [[ ${#names[@]} -eq 0 ]]; then
    echo -e "  ${DIM}No containers.${RESET}"
    return 1
  fi

  echo -e "  ${DIM}Containers:${RESET}\n"
  local i
  for i in "${!names[@]}"; do
    echo -e "  ${CYAN}[$((i + 1))]${RESET}  ${names[$i]}"
  done
  echo
  read -rp "  Select number (or Enter to cancel): " choice
  [[ -z "$choice" ]] && return 1
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#names[@]} )); then
    echo -e "  ${RED}Invalid choice${RESET}"
    return 1
  fi
  SELECTED_NAME="${names[$((choice - 1))]}"
  return 0
}

# ────────────────────────────────────────────────────────
#  CONTAINERS OVERVIEW
# ────────────────────────────────────────────────────────

containers_overview() {
  print_header
  echo -e "  ${BOLD}All containers${RESET}"
  echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
  echo

  local out
  out=$(docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1) || {
    echo -e "  ${RED}✗ $out${RESET}"
    pause
    return
  }

  echo "$out" | sed 's/^/    /'
  echo
  local running total
  running=$(docker ps -q | wc -l | tr -d ' ')
  total=$(docker ps -aq | wc -l | tr -d ' ')
  echo -e "  ${DIM}Running: ${running}  |  Total: ${total}${RESET}"
  pause
}

containers_running_only() {
  print_header
  echo -e "  ${BOLD}Running containers${RESET}"
  echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
  echo

  local out
  out=$(docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1) || {
    echo -e "  ${RED}✗ $out${RESET}"
    pause
    return
  }

  echo "$out" | sed 's/^/    /'
  pause
}

# ────────────────────────────────────────────────────────
#  LOGS
# ────────────────────────────────────────────────────────

container_logs() {
  print_header
  echo -e "  ${BOLD}Container logs${RESET}\n"

  pick_container all || { pause; return; }

  echo
  read -rp "  $(echo -e "${CYAN}Tail lines${RESET} [100]: ")" lines
  [[ -z "$lines" ]] && lines=100
  if ! [[ "$lines" =~ ^[0-9]+$ ]] || (( lines < 1 )); then
    echo -e "  ${RED}Invalid number${RESET}"
    pause
    return
  fi

  echo
  if confirm "Follow log stream (Ctrl+C to stop)?"; then
    echo -e "  ${DIM}▸ docker logs -f --tail $lines $SELECTED_NAME${RESET}\n"
    docker logs -f --tail "$lines" "$SELECTED_NAME"
  else
    echo -e "  ${DIM}▸ docker logs --tail $lines $SELECTED_NAME${RESET}\n"
    docker logs --tail "$lines" "$SELECTED_NAME" 2>&1 | sed 's/^/    /'
    pause
  fi
}

# ────────────────────────────────────────────────────────
#  LIFECYCLE
# ────────────────────────────────────────────────────────

lifecycle_menu() {
  while true; do
    print_header
    echo -e "  ${BOLD}Start / Stop / Restart${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
    echo
    echo -e "  ${CYAN}[1]${RESET}  Start container   ${DIM}(stopped)${RESET}"
    echo -e "  ${CYAN}[2]${RESET}  Stop container    ${DIM}(running)${RESET}"
    echo -e "  ${CYAN}[3]${RESET}  Restart container"
    echo -e "  ${DIM}[b]${RESET}  Back"
    echo
    read -rp "  Choose: " opt
    case "$opt" in
      1)
        print_header
        echo -e "  ${BOLD}Start container${RESET}\n"
        pick_container all || { pause; continue; }
        echo
        echo -e "  ${DIM}▸ docker start $SELECTED_NAME${RESET}"
        if docker start "$SELECTED_NAME" 2>&1; then
          echo -e "  ${GREEN}✓ Started${RESET}"
        else
          echo -e "  ${RED}✗ Start failed${RESET}"
        fi
        pause
        ;;
      2)
        print_header
        echo -e "  ${BOLD}Stop container${RESET}\n"
        pick_container running || { pause; continue; }
        echo
        if confirm "Stop $SELECTED_NAME?"; then
          echo -e "  ${DIM}▸ docker stop $SELECTED_NAME${RESET}"
          if docker stop "$SELECTED_NAME" 2>&1; then
            echo -e "  ${GREEN}✓ Stopped${RESET}"
          else
            echo -e "  ${RED}✗ Stop failed${RESET}"
          fi
        fi
        pause
        ;;
      3)
        print_header
        echo -e "  ${BOLD}Restart container${RESET}\n"
        pick_container running || { pause; continue; }
        echo
        if confirm "Restart $SELECTED_NAME?"; then
          echo -e "  ${DIM}▸ docker restart $SELECTED_NAME${RESET}"
          if docker restart "$SELECTED_NAME" 2>&1; then
            echo -e "  ${GREEN}✓ Restarted${RESET}"
          else
            echo -e "  ${RED}✗ Restart failed${RESET}"
          fi
        fi
        pause
        ;;
      b|B) return ;;
      *) ;;
    esac
  done
}

# ────────────────────────────────────────────────────────
#  PORTS
# ────────────────────────────────────────────────────────

published_ports() {
  while true; do
    print_header
    echo -e "  ${BOLD}Published ports${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
    echo
    echo -e "  ${CYAN}[1]${RESET}  All running (summary)"
    echo -e "  ${CYAN}[2]${RESET}  One container (detail)"
    echo -e "  ${DIM}[b]${RESET}  Back"
    echo
    read -rp "  Choose: " opt
    case "$opt" in
      1)
        print_header
        echo -e "  ${BOLD}Port mappings (running)${RESET}\n"
        docker ps --format 'table {{.Names}}\t{{.Ports}}' 2>&1 | sed 's/^/    /'
        pause
        ;;
      2)
        print_header
        echo -e "  ${BOLD}Ports for one container${RESET}\n"
        pick_container all || { pause; continue; }
        echo
        echo -e "  ${DIM}▸ docker port $SELECTED_NAME${RESET} ${DIM}(needs running container)${RESET}\n"
        local pr
        pr=$(docker port "$SELECTED_NAME" 2>&1)
        if [[ -z "$pr" ]]; then
          echo -e "    ${DIM}(no rows — stopped container or no published ports)${RESET}"
        else
          echo "$pr" | sed 's/^/    /'
        fi
        echo
        echo -e "  ${DIM}From inspect (declared bindings):${RESET}\n"
        docker inspect "$SELECTED_NAME" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{$p}} -> {{.HostIp}}:{{.HostPort}}{{"\n"}}{{end}}{{end}}' 2>&1 | sed '/^$/d' | sed 's/^/    /'
        pause
        ;;
      b|B) return ;;
      *) ;;
    esac
  done
}

# ────────────────────────────────────────────────────────
#  INSPECT
# ────────────────────────────────────────────────────────

inspect_container() {
  print_header
  echo -e "  ${BOLD}Inspect container${RESET}\n"

  pick_container all || { pause; return; }

  local n="$SELECTED_NAME"
  echo
  echo -e "  ${BOLD}$n${RESET}\n"

  echo -e "  ${DIM}Image:${RESET}           $(docker inspect -f '{{.Config.Image}}' "$n" 2>/dev/null)"
  echo -e "  ${DIM}State:${RESET}           $(docker inspect -f '{{.State.Status}} (exit {{.State.ExitCode}})' "$n" 2>/dev/null)"
  echo -e "  ${DIM}Started at:${RESET}      $(docker inspect -f '{{.State.StartedAt}}' "$n" 2>/dev/null)"
  echo -e "  ${DIM}Cmd:${RESET}             $(docker inspect -f '{{json .Config.Cmd}}' "$n" 2>/dev/null)"
  echo -e "  ${DIM}Working dir:${RESET}     $(docker inspect -f '{{.Config.WorkingDir}}' "$n" 2>/dev/null)"
  echo -e "  ${DIM}Restart policy:${RESET}  $(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$n" 2>/dev/null)"

  echo
  echo -e "  ${DIM}Mounts:${RESET}"
  local ms
  ms=$(docker inspect -f '{{range .Mounts}}{{.Type}}  {{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' "$n" 2>/dev/null)
  if [[ -z "${ms//[$'\t\n\r ']/}" ]]; then
    echo -e "    ${DIM}(none)${RESET}"
  else
    echo "$ms" | sed 's/^/    /'
  fi

  echo
  echo -e "  ${DIM}Networks:${RESET}"
  local ns
  ns=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}  IP: {{$v.IPAddress}}{{"\n"}}{{end}}' "$n" 2>/dev/null)
  if [[ -z "${ns//[$'\t\n\r ']/}" ]]; then
    echo -e "    ${DIM}(none)${RESET}"
  else
    echo "$ns" | sed 's/^/    /'
  fi

  pause
}

# ────────────────────────────────────────────────────────
#  EXEC SHELL (docker exec)
# ────────────────────────────────────────────────────────

exec_into_container() {
  print_header
  echo -e "  ${BOLD}Shell inside container${RESET}  ${DIM}(docker exec -it)${RESET}"
  echo -e "  ${DIM}Только запущенные контейнеры · сначала пробуем bash, иначе sh${RESET}"
  echo -e "  ${YELLOW}Выйти из контейнера:${RESET} ${BOLD}exit${RESET} или Ctrl+D\n"

  pick_container running || { pause; return; }

  local c="$SELECTED_NAME"
  echo
  if docker exec "$c" bash -c 'true' 2>/dev/null; then
    echo -e "  ${DIM}▸ docker exec -it $c bash${RESET}\n"
    docker exec -it "$c" bash
  elif docker exec "$c" /bin/bash -c 'true' 2>/dev/null; then
    echo -e "  ${DIM}▸ docker exec -it $c /bin/bash${RESET}\n"
    docker exec -it "$c" /bin/bash
  elif docker exec "$c" sh -c 'true' 2>/dev/null; then
    echo -e "  ${DIM}▸ docker exec -it $c sh${RESET}\n"
    docker exec -it "$c" sh
  elif docker exec "$c" /bin/sh -c 'true' 2>/dev/null; then
    echo -e "  ${DIM}▸ docker exec -it $c /bin/sh${RESET}\n"
    docker exec -it "$c" /bin/sh
  else
    echo -e "  ${RED}✗ Не удалось запустить shell (нет bash/sh в контейнере или контейнер не running)${RESET}"
  fi

  echo
  pause
}

# ────────────────────────────────────────────────────────
#  IMAGES
# ────────────────────────────────────────────────────────

list_images() {
  print_header
  echo -e "  ${BOLD}Images${RESET}"
  echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
  echo
  docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}' 2>&1 | sed 's/^/    /'
  pause
}

# ────────────────────────────────────────────────────────
#  NETWORKS
# ────────────────────────────────────────────────────────

list_networks() {
  print_header
  echo -e "  ${BOLD}Networks${RESET}"
  echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
  echo
  docker network ls 2>&1 | sed 's/^/    /'
  pause
}

list_volumes() {
  print_header
  echo -e "  ${BOLD}Volumes${RESET}"
  echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
  echo
  docker volume ls 2>&1 | sed 's/^/    /'
  pause
}

storage_menu() {
  while true; do
    print_header
    echo -e "  ${BOLD}Networks & volumes${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
    echo
    echo -e "  ${CYAN}[1]${RESET}  Networks"
    echo -e "  ${CYAN}[2]${RESET}  Volumes"
    echo -e "  ${DIM}[b]${RESET}  Back"
    echo
    read -rp "  Choose: " opt
    case "$opt" in
      1) list_networks ;;
      2) list_volumes ;;
      b|B) return ;;
      *) ;;
    esac
  done
}

# ────────────────────────────────────────────────────────
#  SYSTEM
# ────────────────────────────────────────────────────────

system_summary() {
  print_header
  echo -e "  ${BOLD}Docker system${RESET}"
  echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
  echo
  echo -e "  ${DIM}▸ docker version (client)${RESET}\n"
  docker version --format '{{.Client.Version}}' 2>&1 | sed 's/^/    Client: /'
  echo
  echo -e "  ${DIM}▸ docker info (short)${RESET}\n"
  docker info --format '    Server version: {{.ServerVersion}}
    Containers: {{.Containers}} (running {{.ContainersRunning}}, paused {{.ContainersPaused}}, stopped {{.ContainersStopped}})
    Images: {{.Images}}
    CPUs: {{.NCPU}}  Memory: {{.MemTotal}}' 2>&1

  echo
  echo -e "  ${DIM}▸ docker system df${RESET}\n"
  docker system df 2>&1 | sed 's/^/    /'

  echo
  echo -e "  ${BOLD}Resource usage (running containers)${RESET}"
  echo -e "  ${DIM}▸ docker stats --no-stream${RESET} — ${DIM}CPU %, MEM usage/limit, MEM %, NET I/O, BLOCK I/O, PIDs (стандартная таблица Docker)${RESET}\n"
  docker stats --no-stream 2>&1 | sed 's/^/    /'

  echo
  if confirm "Живые обновляющиеся stats (как docker stats, Ctrl+C — стоп)?"; then
    clear
    echo -e "  ${YELLOW}Ctrl+C${RESET} ${DIM}— выйти из live stats и вернуться${RESET}\n"
    docker stats
  fi

  pause
}

# ────────────────────────────────────────────────────────
#  PRUNE
# ────────────────────────────────────────────────────────

prune_menu() {
  while true; do
    print_header
    echo -e "  ${BOLD}Prune unused data${RESET}"
    echo -e "  ${YELLOW}  Destructive — frees disk space${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"
    echo
    echo -e "  ${CYAN}[1]${RESET}  docker system prune  ${DIM}(stopped containers, unused networks, dangling images)${RESET}"
    echo -e "  ${CYAN}[2]${RESET}  docker image prune   ${DIM}(dangling images only)${RESET}"
    echo -e "  ${CYAN}[3]${RESET}  docker volume prune  ${DIM}(unused local volumes)${RESET}"
    echo -e "  ${DIM}[b]${RESET}  Back"
    echo
    read -rp "  Choose: " opt
    case "$opt" in
      1)
        if confirm "Run system prune?"; then
          echo
          docker system prune -f 2>&1 | sed 's/^/    /'
          echo -e "\n  ${GREEN}✓ Done${RESET}"
        fi
        pause
        ;;
      2)
        if confirm "Prune dangling images?"; then
          echo
          docker image prune -f 2>&1 | sed 's/^/    /'
          echo -e "\n  ${GREEN}✓ Done${RESET}"
        fi
        pause
        ;;
      3)
        if confirm "Prune unused volumes? (data loss if no container uses them)"; then
          echo
          docker volume prune -f 2>&1 | sed 's/^/    /'
          echo -e "\n  ${GREEN}✓ Done${RESET}"
        fi
        pause
        ;;
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
    echo -e "  ${CYAN}[1]${RESET}  All containers   ${DIM}(status, image, ports)${RESET}"
    echo -e "  ${CYAN}[2]${RESET}  Running only"
    echo -e "  ${CYAN}[3]${RESET}  Logs"
    echo -e "  ${CYAN}[4]${RESET}  Start / Stop / Restart"
    echo -e "  ${CYAN}[5]${RESET}  Published ports"
    echo -e "  ${CYAN}[6]${RESET}  Inspect container"
    echo -e "  ${CYAN}[7]${RESET}  Images"
    echo -e "  ${CYAN}[8]${RESET}  Networks & volumes"
    echo -e "  ${CYAN}[9]${RESET}  System usage  ${DIM}(df, version, stats)${RESET}"
    echo -e "  ${CYAN}[0]${RESET}  Prune unused  ${DIM}(careful)${RESET}"
    echo -e "  ${CYAN}[e]${RESET}  Shell in container  ${DIM}(docker exec bash/sh)${RESET}"
    echo
    echo -e "  ${DIM}[q]${RESET}  Quit"
    echo

    read -rp "  $(echo -e "${BOLD}Choose:${RESET} ")" opt
    case "$opt" in
      1) containers_overview ;;
      2) containers_running_only ;;
      3) container_logs ;;
      4) lifecycle_menu ;;
      5) published_ports ;;
      6) inspect_container ;;
      7) list_images ;;
      8) storage_menu ;;
      9) system_summary ;;
      0) prune_menu ;;
      e|E) exec_into_container ;;
      q|Q) echo -e "\n  ${DIM}Bye!${RESET}\n"; exit 0 ;;
      *) echo -e "  ${RED}Unknown option${RESET}"; sleep 1 ;;
    esac
  done
}

if [[ "${1:-}" == "update" ]]; then
  self_update || exit 1
  exit 0
fi

require_docker
main_menu
