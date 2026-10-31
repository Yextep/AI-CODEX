#!/usr/bin/env bash
set -Eeuo pipefail

REPO="openai/codex"
NPM_PACKAGE="@openai/codex"
OFFICIAL_INSTALL_URL="https://chatgpt.com/codex/install.sh"
DEFAULT_INSTALL_DIR="/usr/local/bin"
METHOD="auto"
FORCE=0
TARGET_VERSION=""
INSTALL_DIR="${CODEX_INSTALL_DIR:-}"
LOG_FILE="${LOG_FILE:-/tmp/codex-install-update.log}"
LOCK_DIR="/tmp/codex-install-update.lock"
CLEANUP_PATHS=()

info() { printf '\033[1;34m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'USAGE'
Instala o actualiza Codex CLI de forma robusta.

Uso:
  bash iou-codex.sh
  bash iou-codex.sh --version 0.160.0
  bash iou-codex.sh --method binary
  bash iou-codex.sh --install-dir "$HOME/.local/bin"

Opciones:
  --version VERSION      Instala una versión concreta. Por defecto usa la última release.
  --method auto         Usa el instalador oficial. Es el valor por defecto.
  --method official     Usa el instalador oficial de chatgpt.com.
  --method npm          Usa solo npm.
  --method binary       Usa solo el binario oficial de GitHub.
  --install-dir DIR     Carpeta de instalación (official/auto/binary).
  --force               Reinstala con npm/binary aunque la versión actual ya coincida.
  -h, --help            Muestra esta ayuda.

Variables:
  CODEX_INSTALL_DIR     Igual que --install-dir.
  LOG_FILE              Log de instalación. Por defecto: /tmp/codex-install-update.log
  IOU_CODEX_PROOT       1 o 0 fuerza o descarta la detección de PRoot. Por defecto: auto.

En Debian/Ubuntu instala las dependencias del sistema, incluido bubblewrap,
antes de instalar o actualizar. Usa root o sudo solo para los paquetes apt;
Codex se instala para el usuario que ejecuta este script.
El método official/auto vuelve a ejecutar siempre el instalador para reparar
la instalación, aunque la versión coincida. No requiere Node.js ni npm.

En PRoot (Termux/proot-distro) el servidor en segundo plano de Codex no puede
arrancar. Si falla, el script desactiva daemon_auto_start para que Codex use
su servidor integrado, detiene el daemon colgado y limpia el socket roto.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || { err "Falta valor para --version"; exit 2; }
        TARGET_VERSION="$2"
        shift 2
        ;;
      --method)
        [[ $# -ge 2 ]] || { err "Falta valor para --method"; exit 2; }
        METHOD="$2"
        case "$METHOD" in
          auto|official|npm|binary) ;;
          *) err "Método inválido: $METHOD"; exit 2 ;;
        esac
        shift 2
        ;;
      --install-dir)
        [[ $# -ge 2 ]] || { err "Falta valor para --install-dir"; exit 2; }
        INSTALL_DIR="$2"
        shift 2
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Opción desconocida: $1"
        usage
        exit 2
        ;;
    esac
  done
}

ensure_prerequisites() {
  local os package status
  local -a packages=(ca-certificates curl tar gzip coreutils bubblewrap)
  local -a missing=() elevate=()
  os="$(uname -s)"

  if [[ "$os" == Linux ]] && have apt-get && have dpkg-query; then
    if [[ "$METHOD" == npm ]] && { ! have node || ! have npm; }; then
      packages+=(nodejs npm)
    fi
    for package in "${packages[@]}"; do
      status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
      [[ "$status" == 'install ok installed' ]] || missing+=("$package")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
      if [[ "$EUID" -ne 0 ]]; then
        if ! have sudo; then
          err "Faltan paquetes: ${missing[*]}. Instala sudo o ejecuta como root para instalarlos."
          return 1
        fi
        elevate=(sudo)
      fi
      info "Instalando requisitos del sistema: ${missing[*]}"
      run_logged "${elevate[@]}" apt-get update
      run_logged "${elevate[@]}" apt-get install -y --no-install-recommends "${missing[@]}"
      hash -r
    fi
  fi

  if ! have curl && ! have wget; then
    err "Falta curl o wget; instálalo con el gestor de paquetes del sistema."
    return 1
  fi
  for package in tar gzip mktemp tee install; do
    if ! have "$package"; then
      err "Falta el comando requerido: $package. Instálalo con el gestor de paquetes del sistema."
      return 1
    fi
  done
  if [[ "$os" == Linux ]]; then
    if ! have bwrap; then
      err "Falta bubblewrap (comando bwrap en PATH). Instálalo con el gestor de paquetes del sistema."
      return 1
    fi
    if ! bwrap --version >>"$LOG_FILE" 2>&1; then
      err "bubblewrap está en PATH pero no se puede ejecutar. Revisa $LOG_FILE."
      return 1
    fi
    info "bubblewrap disponible: $(command -v bwrap)"
  fi
}

install_from_official() {
  local workdir executable
  workdir="$(mktemp -d)"
  CLEANUP_PATHS+=("$workdir")

  # Descargar primero evita ejecutar un script parcial si la red falla.
  info "Descargando el instalador oficial de Codex"
  download_to "$OFFICIAL_INSTALL_URL" "$workdir/install.sh" 2>&1 | tee -a "$LOG_FILE"
  sh -n "$workdir/install.sh"
  [[ -z "$INSTALL_DIR" ]] || INSTALL_DIR="$(mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR" && pwd)"
  executable="${INSTALL_DIR:-$HOME/.local/bin}/codex"

  info "Instalando/actualizando Codex con el instalador oficial"
  run_logged env CODEX_INSTALL_DIR="$(dirname "$executable")" CODEX_NON_INTERACTIVE=1 \
    sh "$workdir/install.sh" --release "${TARGET_VERSION:-latest}"

  if [[ ! -x "$executable" ]]; then
    err "El instalador no dejó un ejecutable en $executable"
    return 1
  fi
  if [[ -n "$TARGET_VERSION" ]]; then
    verify_codex_version "$executable" "$TARGET_VERSION"
  else
    "$executable" --version >>"$LOG_FILE" 2>&1
  fi
  check_daemon "$executable"
  info "Resultado final: $("$executable" --version) ($executable)"
  hash -r
  if [[ "$(command -v codex 2>/dev/null || true)" != "$executable" ]]; then
    warn "Para usar esta instalación en tu terminal: export PATH=\"$(dirname "$executable"):\$PATH\""
    if have codex; then
      warn "Ahora PATH selecciona otra instalación: $(command -v codex)"
    fi
  fi
}

check_daemon() {
  local executable="$1"
  # Las versiones antiguas no tienen daemon. start deja intacto uno ya activo.
  "$executable" app-server daemon start --help >/dev/null 2>&1 || return 0

  if is_proot; then
    check_daemon_in_proot "$executable"
    return
  fi

  info "Comprobando el arranque del servidor de Codex"
  if ! run_logged "$executable" app-server daemon start; then
    err "Codex se instaló, pero el servidor no arrancó. Revisa $LOG_FILE y ${CODEX_HOME:-$HOME/.codex}/app-server-daemon/daemon.stderr.log."
    err "Requisitos del sandbox: https://developers.openai.com/codex/concepts/sandboxing#prerequisites"
    err "Para usar Codex sin el servidor en segundo plano: codex --no-daemon"
    return 1
  fi
}

# Termux/proot-distro. IOU_CODEX_PROOT=1 o 0 fuerza la detección.
is_proot() {
  case "${IOU_CODEX_PROOT:-auto}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [[ "${container:-}" == proot* || -n "${PROOT_L2S_DIR:-}" ]] && return 0
  [[ "$(uname -r 2>/dev/null || true)" == *PRoot* ]] && return 0
  local tracer
  tracer="$(awk '/^TracerPid:/ {print $2}' /proc/self/status 2>/dev/null || true)"
  [[ -n "$tracer" && "$tracer" != 0 && "$(cat "/proc/$tracer/comm" 2>/dev/null || true)" == proot* ]]
}

# Estado de la feature daemon_auto_start: true, false o vacío si no existe.
daemon_auto_start_state() {
  local executable="$1" features line
  # Se captura la salida completa: con pipefail, grep -q cortaría la tubería.
  features="$("$executable" features list 2>/dev/null || true)"
  while IFS= read -r line; do
    if [[ "$line" =~ ^daemon_auto_start[[:space:]].*[[:space:]](true|false)[[:space:]]*$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return
    fi
  done <<<"$features"
}

# Desde Codex 0.166 el socket del daemon vive en /tmp/codex-daemon-<uid>/<hash>.
# En el host esa ruta supera los 108 bytes de sun_path; PRoot reubica el socket
# y el enlace app-server-control.sock queda roto, así que el daemon nunca está
# listo. Codex funciona igual con su servidor integrado (como --no-daemon).
check_daemon_in_proot() {
  local executable="$1" state
  state="$(daemon_auto_start_state "$executable")"

  if [[ "$state" == false ]]; then
    info "PRoot: daemon_auto_start ya está desactivado; Codex usa su servidor integrado"
    cleanup_proot_daemon
    return 0
  fi

  info "Comprobando el arranque del servidor de Codex (PRoot)"
  if "$executable" app-server daemon start >>"$LOG_FILE" 2>&1; then
    info "El servidor de Codex arrancó correctamente"
    return 0
  fi

  if [[ -z "$state" ]]; then
    err "El servidor de Codex no arrancó en PRoot y esta versión no permite desactivarlo. Revisa $LOG_FILE."
    err "Ejecuta Codex con: codex --no-daemon"
    return 1
  fi

  warn "El servidor en segundo plano de Codex no puede funcionar en PRoot (ruta de socket demasiado larga)."
  if ! run_logged "$executable" features disable daemon_auto_start; then
    err "No pude desactivar daemon_auto_start. Ejecuta Codex con: codex --no-daemon"
    return 1
  fi
  cleanup_proot_daemon
  info "Codex usará su servidor integrado; ya puedes ejecutar: codex"
  warn "En PRoot no funcionan 'codex agents' ni 'codex remote-control'. Para reactivar el daemon: codex features enable daemon_auto_start"
}

# Detiene los daemons inalcanzables y borra los enlaces de socket rotos.
cleanup_proot_daemon() {
  local codex_home="${CODEX_HOME:-$HOME/.codex}" pattern rootfs sock host attempt
  if have pkill; then
    pattern="$(printf '%s' "$codex_home" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
    pattern="$pattern/packages/app-server-daemon/releases/[^ ]*/bin/codex app-server"
    if pkill -f -- "$pattern" 2>/dev/null; then
      # Mientras el proceso vive, PRoot aún resuelve el socket y el enlace no
      # parece roto; hay que esperar a que termine antes de limpiarlo.
      for attempt in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f -- "$pattern" >/dev/null 2>&1 || break
        sleep 0.5
      done
      pkill -KILL -f -- "$pattern" 2>/dev/null || true
      info "Detenido el servidor en segundo plano inalcanzable de Codex"
    fi
  fi

  # Dentro de PRoot el enlace roto no se puede borrar por su ruta; desde la
  # ruta del host sí. proot-distro define PROOT_L2S_DIR=<rootfs del host>/.l2s.
  rootfs="${PROOT_L2S_DIR:-}"
  rootfs="${rootfs%/.l2s}"
  [[ -n "$rootfs" && "$rootfs" != "${PROOT_L2S_DIR:-}" && "$codex_home" == /* ]] || return 0
  for sock in app-server-control/app-server-control.sock app-server-daemon/daemon-updater.sock; do
    host="$rootfs$codex_home/$sock"
    if [[ -L "$host" && ! -e "$host" ]] && rm -f "$host"; then
      info "Eliminado enlace de socket roto: $codex_home/$sock"
    fi
  done
}

cleanup_lock() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

cleanup_all() {
  local path
  for path in "${CLEANUP_PATHS[@]}"; do
    [[ -n "$path" ]] && rm -rf "$path" 2>/dev/null || true
  done
  cleanup_lock
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local old_pid=""
    old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      err "Ya hay otra instalación/actualización de Codex en curso: $LOCK_DIR (pid $old_pid)"
      exit 1
    fi

    warn "Eliminando lock obsoleto: $LOCK_DIR"
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      err "No pude crear lock: $LOCK_DIR"
      exit 1
    fi
  fi
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  trap cleanup_all EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

run_logged() {
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

download_to() {
  local url="$1"
  local output="$2"

  if have curl; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$output" "$url"
  elif have wget; then
    wget -O "$output" "$url"
  else
    err "Necesito curl o wget para descargar $url"
    return 1
  fi
}

json_field() {
  local field="$1"
  local file="$2"

  if have python3; then
    python3 - "$field" "$file" <<'PY'
import json
import sys

field, path = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get(field, "")
print(value if value is not None else "")
PY
  else
    sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n1
  fi
}

normalize_version() {
  local version="$1"
  version="${version#rust-v}"
  version="${version#v}"
  printf '%s\n' "$version"
}

version_to_tag() {
  local version="$1"
  version="$(normalize_version "$version")"
  printf 'rust-v%s\n' "$version"
}

get_latest_release() {
  local tmp_json="$1"
  local latest_url="https://api.github.com/repos/$REPO/releases/latest"

  info "Consultando última release oficial"
  download_to "$latest_url" "$tmp_json" >>"$LOG_FILE" 2>&1

  local tag
  tag="$(json_field tag_name "$tmp_json")"
  if [[ -z "$tag" ]]; then
    err "No pude leer tag_name desde GitHub API"
    return 1
  fi

  normalize_version "$tag"
}

current_codex_version() {
  if ! have codex; then
    return 1
  fi

  codex --version 2>/dev/null | awk '{print $NF}' | head -n1
}

print_environment() {
  info "Sistema: $(uname -srm)"
  if have codex; then
    info "Codex actual: $(command -v codex) ($(codex --version 2>/dev/null || true))"
  else
    warn "Codex no está instalado en PATH"
  fi
  if have npm; then
    info "npm: $(command -v npm) ($(npm --version 2>/dev/null || true))"
  else
    info "npm no está disponible; el instalador oficial y el binario no lo requieren"
  fi
}

verify_codex_version() {
  local executable="$1"
  local expected="$2"
  local got

  got="$("$executable" --version 2>/dev/null | awk '{print $NF}' | head -n1 || true)"
  if [[ "$got" != "$expected" ]]; then
    err "Verificación fallida para $executable: esperaba $expected, obtuve ${got:-nada}"
    return 1
  fi
}

try_npm_install() {
  local version="$1"

  if ! have npm; then
    warn "npm no está instalado"
    return 1
  fi

  info "Intentando actualizar con npm: $NPM_PACKAGE@$version"
  set +e
  npm install -g --no-audit --no-fund "$NPM_PACKAGE@$version" 2>&1 | tee -a "$LOG_FILE"
  local status=${PIPESTATUS[0]}
  set -e

  if [[ "$status" -ne 0 ]]; then
    warn "npm falló con código $status; revisar $LOG_FILE"
    return 1
  fi

  hash -r 2>/dev/null || true
  if ! have codex; then
    warn "npm terminó sin dejar codex en PATH"
    return 1
  fi

  verify_codex_version "$(command -v codex)" "$version"
}

detect_asset_name() {
  local os arch libc
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$arch" in
    aarch64|arm64) arch="aarch64" ;;
    x86_64|amd64) arch="x86_64" ;;
    *)
      err "Arquitectura no soportada automáticamente: $arch"
      return 1
      ;;
  esac

  case "$os" in
    Linux)
      libc="musl"
      printf 'codex-%s-unknown-linux-%s.tar.gz\n' "$arch" "$libc"
      ;;
    Darwin)
      printf 'codex-%s-apple-darwin.tar.gz\n' "$arch"
      ;;
    *)
      err "Sistema no soportado por este script para método binary: $os"
      return 1
      ;;
  esac
}

select_install_target() {
  if [[ -n "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
    printf '%s/codex\n' "${INSTALL_DIR%/}"
    return
  fi

  local existing=""
  existing="$(command -v codex 2>/dev/null || true)"
  if [[ -n "$existing" && -f "$existing" && ! -L "$existing" && -w "$existing" ]]; then
    printf '%s\n' "$existing"
    return
  fi

  if [[ -d "$DEFAULT_INSTALL_DIR" && -w "$DEFAULT_INSTALL_DIR" ]]; then
    printf '%s/codex\n' "$DEFAULT_INSTALL_DIR"
    return
  fi

  mkdir -p "$HOME/.local/bin"
  printf '%s/.local/bin/codex\n' "$HOME"
}

install_binary_atomically() {
  local source_bin="$1"
  local target_bin="$2"
  local version="$3"
  local target_dir temp_target backup=""

  target_dir="$(dirname "$target_bin")"
  mkdir -p "$target_dir"

  if [[ ! -w "$target_dir" ]]; then
    err "No puedo escribir en $target_dir. Ejecuta como usuario con permisos o usa --install-dir."
    return 1
  fi

  if [[ -e "$target_bin" || -L "$target_bin" ]]; then
    backup="$target_bin.backup.$(date +%Y%m%d%H%M%S)"
    info "Creando backup: $backup"
    cp -a "$target_bin" "$backup"
  fi

  temp_target="$target_dir/.codex.tmp.$$"
  install -m 0755 "$source_bin" "$temp_target"

  if ! verify_codex_version "$temp_target" "$version"; then
    rm -f "$temp_target"
    return 1
  fi

  mv -f "$temp_target" "$target_bin"

  if ! verify_codex_version "$target_bin" "$version"; then
    err "El binario instalado no pasa verificación; restaurando backup"
    if [[ -n "$backup" ]]; then
      mv -f "$backup" "$target_bin"
    fi
    return 1
  fi

  info "Binario instalado en $target_bin"
  if [[ -n "$backup" ]]; then
    info "Backup disponible en $backup"
  fi
}

install_from_github_binary() {
  local version="$1"
  local tag asset url workdir archive extract_dir binary_name binary_path target_bin

  tag="$(version_to_tag "$version")"
  asset="$(detect_asset_name)"
  url="https://github.com/$REPO/releases/download/$tag/$asset"
  workdir="$(mktemp -d)"
  CLEANUP_PATHS+=("$workdir")
  archive="$workdir/$asset"
  extract_dir="$workdir/extract"

  info "Descargando binario oficial: $asset"
  download_to "$url" "$archive" 2>&1 | tee -a "$LOG_FILE"

  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir"

  binary_name="${asset%.tar.gz}"
  binary_path="$extract_dir/$binary_name"
  if [[ ! -x "$binary_path" ]]; then
    binary_path="$(find "$extract_dir" -type f -perm -u+x \( -name 'codex' -o -name 'codex-*' \) | sort | head -n1)"
  fi

  if [[ -z "${binary_path:-}" || ! -x "$binary_path" ]]; then
    err "No encontré un binario ejecutable dentro de $asset"
    return 1
  fi

  info "Verificando binario descargado"
  verify_codex_version "$binary_path" "$version"

  target_bin="$(select_install_target)"
  install_binary_atomically "$binary_path" "$target_bin" "$version"

  hash -r 2>/dev/null || true
  if ! have codex; then
    warn "Codex se instaló, pero la carpeta no está en PATH: $(dirname "$target_bin")"
    warn "Añade esto a tu shell: export PATH=\"$(dirname "$target_bin"):\$PATH\""
    return 0
  fi

  info "Codex activo: $(command -v codex) ($(codex --version 2>/dev/null || true))"
}

main() {
  parse_args "$@"
  if [[ -n "$TARGET_VERSION" ]]; then
    TARGET_VERSION="$(normalize_version "$TARGET_VERSION")"
    if [[ ! "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[[:alnum:].-]+)?$ ]]; then
      err "Versión inválida: $TARGET_VERSION"
      exit 2
    fi
  fi

  acquire_lock
  : >"$LOG_FILE"
  print_environment
  ensure_prerequisites

  if [[ "$METHOD" == auto || "$METHOD" == official ]]; then
    install_from_official
    info "Log: $LOG_FILE"
    warn "Si Codex estaba abierto mientras actualizabas, reinicia la sesión para cargar el binario nuevo."
    return
  fi

  local tmp_json current
  tmp_json="$(mktemp)"
  CLEANUP_PATHS+=("$tmp_json")

  if [[ -z "$TARGET_VERSION" ]]; then
    TARGET_VERSION="$(get_latest_release "$tmp_json")"
  else
    TARGET_VERSION="$(normalize_version "$TARGET_VERSION")"
  fi

  info "Versión objetivo: $TARGET_VERSION"
  current="$(current_codex_version || true)"
  if [[ "$FORCE" -eq 0 && -n "$current" && "$current" == "$TARGET_VERSION" ]]; then
    check_daemon "$(command -v codex)"
    info "Codex ya está en la versión $TARGET_VERSION. Usa --force para reinstalar."
    exit 0
  fi

  case "$METHOD" in
    npm)
      try_npm_install "$TARGET_VERSION"
      ;;
    binary)
      install_from_github_binary "$TARGET_VERSION"
      ;;
  esac

  hash -r 2>/dev/null || true
  if have codex; then
    check_daemon "$(command -v codex)"
    info "Resultado final: $(codex --version 2>/dev/null || true)"
  fi
  info "Log: $LOG_FILE"
  warn "Si Codex estaba abierto mientras actualizabas, reinicia la sesión para cargar el binario nuevo."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
