#!/bin/bash

# Instalador resiliente para Parrot
# - Usa ~/Downloads
# - Instala fastfetch desde GitHub
# - No detiene toda la instalación si algo falla
# - Genera resumen final de fallos

set -u
export DEBIAN_FRONTEND=noninteractive

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Este script debe ejecutarse como root o con sudo."
    exit 1
fi

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    nombre_usuario="$SUDO_USER"
else
    nombre_usuario="$(logname 2>/dev/null || true)"
    if [[ -z "$nombre_usuario" || "$nombre_usuario" == "root" ]]; then
        echo "No pude detectar el usuario real. Ejecuta con: sudo ./script.sh"
        exit 1
    fi
fi

user_home="$(getent passwd "$nombre_usuario" | cut -d: -f6)"
DOWNLOADS_DIR="$user_home/Downloads"
REPO_LOCAL="$user_home/ParrotEntorno"
LOG_DIR="$user_home/install_logs"
LOG_FILE="$LOG_DIR/parrot_install.log"
FAIL_FILE="$LOG_DIR/parrot_failed_steps.log"

mkdir -p "$DOWNLOADS_DIR" "$LOG_DIR"
: > "$LOG_FILE"
: > "$FAIL_FILE"

FAILED_STEPS=()
FAILED_DOWNLOADS=()
FAILED_PACKAGES=()

log() { echo -e "\n[*] $1" | tee -a "$LOG_FILE"; }
ok() { echo "[OK] $1" | tee -a "$LOG_FILE"; }
warn() { echo "[WARN] $1" | tee -a "$LOG_FILE"; }

record_fail() {
    local kind="$1"
    local item="$2"
    local detail="$3"
    echo "[$kind] $item :: $detail" | tee -a "$FAIL_FILE"
    case "$kind" in
        STEP) FAILED_STEPS+=("$item :: $detail") ;;
        DOWNLOAD) FAILED_DOWNLOADS+=("$item :: $detail") ;;
        PACKAGE) FAILED_PACKAGES+=("$item :: $detail") ;;
    esac
}

run_step() {
    local name="$1"
    shift
    log "$name"
    if "$@" >>"$LOG_FILE" 2>&1; then
        ok "$name"
        return 0
    else
        warn "$name falló"
        record_fail "STEP" "$name" "Comando: $*"
        return 1
    fi
}

install_package() {
    local pkg="$1"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        ok "Paquete ya instalado: $pkg"
        return 0
    fi
    if apt install -y "$pkg" >>"$LOG_FILE" 2>&1; then
        ok "Paquete instalado: $pkg"
    else
        warn "No se pudo instalar el paquete: $pkg"
        record_fail "PACKAGE" "$pkg" "apt install -y $pkg"
    fi
}

clone_or_update_repo() {
    local url="$1"
    local dest="$2"
    local label="$3"
    if [[ -d "$dest/.git" ]]; then
        log "Actualizando repositorio: $label"
        if sudo -u "$nombre_usuario" git -C "$dest" pull --ff-only >>"$LOG_FILE" 2>&1; then
            ok "Repositorio actualizado: $label"
        else
            warn "No se pudo actualizar $label"
            record_fail "DOWNLOAD" "$label" "git pull falló en $dest"
        fi
    else
        log "Clonando repositorio: $label"
        if sudo -u "$nombre_usuario" git clone "$url" "$dest" >>"$LOG_FILE" 2>&1; then
            ok "Repositorio clonado: $label"
        else
            warn "No se pudo clonar $label"
            record_fail "DOWNLOAD" "$label" "git clone $url"
        fi
    fi
}

sudo_user_cp_dir() {
    local src="$1"
    local dst="$2"
    local label="$3"
    if [[ -d "$src" ]]; then
        sudo -u "$nombre_usuario" mkdir -p "$dst"
        if sudo -u "$nombre_usuario" cp -r "$src"/. "$dst"/ >>"$LOG_FILE" 2>&1; then
            ok "$label"
        else
            warn "No se pudo copiar: $label"
            record_fail "STEP" "$label" "cp -r $src/. $dst/"
        fi
    else
        warn "No existe el directorio: $src"
        record_fail "STEP" "$label" "No existe $src"
    fi
}

log "Inicio de instalación para el usuario: $nombre_usuario"
log "Logs: $LOG_FILE"
log "Registro de fallos: $FAIL_FILE"

cat > /etc/apt/sources.list << 'EOF'
deb https://deb.parrot.sh/parrot echo main contrib non-free non-free-firmware
deb https://deb.parrot.sh/direct/parrot echo-security main contrib non-free non-free-firmware
deb https://deb.parrot.sh/parrot echo-backports main contrib non-free non-free-firmware
EOF

run_step "Limpiar caché APT" apt clean
run_step "Actualizar repositorios" apt update
run_step "Actualizar sistema" parrot-upgrade -y

PACKAGES=(
git vim pkg-config build-essential cmake cmake-data meson ninja-build
kitty rofi bspwm zsh zsh-autosuggestions zsh-syntax-highlighting
feh imagemagick scrub flameshot i3lock npm
libxcb1-dev libxcb-util0-dev libxcb-ewmh-dev libxcb-randr0-dev
libxcb-icccm4-dev libxcb-keysyms1-dev libxcb-xinerama0-dev
libxcb-xtest0-dev libxcb-shape0-dev libxcb-xkb-dev
libxkbcommon-dev libxkbcommon-x11-dev
libasound2-dev libxinerama1 libxinerama-dev
python3-sphinx libcairo2-dev libxcb-composite0-dev
python3-xcbgen xcb-proto libxcb-image0-dev libxcb-xrm-dev
libxcb-cursor-dev libpulse-dev libjsoncpp-dev libmpdclient-dev
libuv1-dev libnl-genl-3-dev
libxext-dev libxcb-damage0-dev libxcb-xfixes0-dev
libxcb-render-util0-dev libxcb-render0-dev libxcb-present-dev
libpixman-1-dev libdbus-1-dev libconfig-dev libgl1-mesa-dev
libpcre2-dev libevdev-dev uthash-dev libev-dev libx11-xcb-dev
libxcb-glx0-dev libpcre3 libpcre3-dev
)

log "Instalando paquetes uno por uno"
for pkg in "${PACKAGES[@]}"; do
    install_package "$pkg"
done

FASTFETCH_DIR="$DOWNLOADS_DIR/fastfetch"
clone_or_update_repo "https://github.com/fastfetch-cli/fastfetch.git" "$FASTFETCH_DIR" "fastfetch"

if [[ -d "$FASTFETCH_DIR" ]]; then
    log "Compilando e instalando fastfetch"
    cd "$FASTFETCH_DIR" || true
    rm -rf build >>"$LOG_FILE" 2>&1
    if sudo -u "$nombre_usuario" cmake -S . -B build >>"$LOG_FILE" 2>&1 &&        sudo -u "$nombre_usuario" cmake --build build -j"$(nproc)" >>"$LOG_FILE" 2>&1 &&        cmake --install build >>"$LOG_FILE" 2>&1; then
        ok "fastfetch instalado correctamente"
    else
        warn "No se pudo compilar/instalar fastfetch"
        record_fail "STEP" "fastfetch" "Compilación o instalación fallida"
    fi
else
    record_fail "DOWNLOAD" "fastfetch" "No se pudo obtener el repositorio"
fi

if command -v fastfetch >/dev/null 2>&1; then
    run_step "Ejecutar fastfetch" fastfetch
else
    warn "fastfetch no quedó instalado; continuando"
    record_fail "STEP" "fastfetch" "Comando no disponible tras instalación"
fi

clone_or_update_repo "https://github.com/baskerville/bspwm.git" "$user_home/bspwm" "bspwm"
clone_or_update_repo "https://github.com/baskerville/sxhkd.git" "$user_home/sxhkd" "sxhkd"
clone_or_update_repo "https://github.com/polybar/polybar" "$DOWNLOADS_DIR/polybar" "polybar"
clone_or_update_repo "https://github.com/ibhagwan/picom.git" "$DOWNLOADS_DIR/picom" "picom"
clone_or_update_repo "https://github.com/VaughnValle/blue-sky" "$DOWNLOADS_DIR/blue-sky" "blue-sky"
clone_or_update_repo "https://github.com/romkatv/powerlevel10k.git" "$user_home/powerlevel10k" "powerlevel10k usuario"
clone_or_update_repo "https://github.com/romkatv/powerlevel10k.git" "/root/powerlevel10k" "powerlevel10k root"
clone_or_update_repo "https://github.com/meskarune/i3lock-fancy.git" "$DOWNLOADS_DIR/i3lock-fancy" "i3lock-fancy"

if [[ -d "$user_home/bspwm" ]]; then
    cd "$user_home/bspwm" || true
    sudo -u "$nombre_usuario" make >>"$LOG_FILE" 2>&1 && make install >>"$LOG_FILE" 2>&1 || record_fail "STEP" "bspwm" "Falló make / make install"
fi

if [[ -d "$user_home/sxhkd" ]]; then
    cd "$user_home/sxhkd" || true
    sudo -u "$nombre_usuario" make >>"$LOG_FILE" 2>&1 && make install >>"$LOG_FILE" 2>&1 || record_fail "STEP" "sxhkd" "Falló make / make install"
fi

if [[ -d "$DOWNLOADS_DIR/polybar" ]]; then
    cd "$DOWNLOADS_DIR/polybar" || true
    sudo -u "$nombre_usuario" git submodule update --init --recursive >>"$LOG_FILE" 2>&1 || record_fail "STEP" "polybar submodules" "git submodule update"
    mkdir -p build
    cd build || true
    sudo -u "$nombre_usuario" cmake .. >>"$LOG_FILE" 2>&1 &&     sudo -u "$nombre_usuario" make -j"$(nproc)" >>"$LOG_FILE" 2>&1 &&     make install >>"$LOG_FILE" 2>&1 || record_fail "STEP" "polybar" "Falló compilación/instalación"
fi

if [[ -d "$DOWNLOADS_DIR/picom" ]]; then
    cd "$DOWNLOADS_DIR/picom" || true
    sudo -u "$nombre_usuario" git submodule update --init --recursive >>"$LOG_FILE" 2>&1 || record_fail "STEP" "picom submodules" "git submodule update"
    (sudo -u "$nombre_usuario" meson setup --buildtype=release build >>"$LOG_FILE" 2>&1 ||      sudo -u "$nombre_usuario" meson setup --reconfigure --buildtype=release build >>"$LOG_FILE" 2>&1) &&     sudo -u "$nombre_usuario" ninja -C build >>"$LOG_FILE" 2>&1 &&     ninja -C build install >>"$LOG_FILE" 2>&1 || record_fail "STEP" "picom" "Falló compilación/instalación"
fi

sudo -u "$nombre_usuario" mkdir -p "$user_home/.config/bspwm" "$user_home/.config/sxhkd" "$user_home/.config/bspwm/scripts" "$user_home/.config/polybar" "$user_home/.config/picom" "$user_home/.config/kitty" "$user_home/.config/bin" "$user_home/fondos" >>"$LOG_FILE" 2>&1

if [[ -d "$REPO_LOCAL" ]]; then
    sudo_user_cp_dir "$REPO_LOCAL/fondos" "$user_home/fondos" "Copiar fondos"

    [[ -f "$REPO_LOCAL/Config/bspwm/bspwmrc" ]] && sudo -u "$nombre_usuario" cp "$REPO_LOCAL/Config/bspwm/bspwmrc" "$user_home/.config/bspwm/" >>"$LOG_FILE" 2>&1 || record_fail "STEP" "bspwmrc" "No existe o no se pudo copiar"
    [[ -f "$REPO_LOCAL/Config/sxhkd/sxhkdrc" ]] && sudo -u "$nombre_usuario" cp "$REPO_LOCAL/Config/sxhkd/sxhkdrc" "$user_home/.config/sxhkd/" >>"$LOG_FILE" 2>&1 || record_fail "STEP" "sxhkdrc" "No existe o no se pudo copiar"
    [[ -f "$REPO_LOCAL/Config/bspwm/scripts/bspwm_resize" ]] && sudo -u "$nombre_usuario" cp "$REPO_LOCAL/Config/bspwm/scripts/bspwm_resize" "$user_home/.config/bspwm/scripts/" >>"$LOG_FILE" 2>&1 || record_fail "STEP" "bspwm_resize" "No existe o no se pudo copiar"

    chmod +x "$user_home/.config/bspwm/bspwmrc" "$user_home/.config/bspwm/scripts/bspwm_resize" >>"$LOG_FILE" 2>&1 || true

    sudo_user_cp_dir "$REPO_LOCAL/Config/kitty" "$user_home/.config/kitty" "Copiar config Kitty"
    mkdir -p /root/.config/kitty
    cp -r "$user_home/.config/kitty/." /root/.config/kitty/ >>"$LOG_FILE" 2>&1 || record_fail "STEP" "Kitty root" "No se pudo copiar"

    sudo_user_cp_dir "$REPO_LOCAL/Config/polybar" "$user_home/.config/polybar" "Copiar config Polybar"
    [[ -f "$REPO_LOCAL/Config/picom/picom.conf" ]] && sudo -u "$nombre_usuario" cp "$REPO_LOCAL/Config/picom/picom.conf" "$user_home/.config/picom/picom.conf" >>"$LOG_FILE" 2>&1 || record_fail "STEP" "picom.conf" "No existe o no se pudo copiar"

    if compgen -G "$REPO_LOCAL/fonts/*" > /dev/null; then
        cp -r "$REPO_LOCAL/fonts/." /usr/local/share/fonts/ >>"$LOG_FILE" 2>&1 || record_fail "STEP" "fonts locales" "No se pudieron copiar"
    fi
    if compgen -G "$REPO_LOCAL/Config/polybar/fonts/*" > /dev/null; then
        cp -r "$REPO_LOCAL/Config/polybar/fonts/." /usr/share/fonts/truetype/ >>"$LOG_FILE" 2>&1 || record_fail "STEP" "fonts polybar" "No se pudieron copiar"
    fi
    fc-cache -f -v >>"$LOG_FILE" 2>&1 || record_fail "STEP" "fc-cache" "No se pudo actualizar caché de fuentes"

    [[ -f "$REPO_LOCAL/Config/zshrc/user/.zshrc" ]] && cp "$REPO_LOCAL/Config/zshrc/user/.zshrc" "$user_home/.zshrc" >>"$LOG_FILE" 2>&1 || true
    [[ -f "$REPO_LOCAL/Config/zshrc/root/.zshrc" ]] && cp "$REPO_LOCAL/Config/zshrc/root/.zshrc" /root/.zshrc >>"$LOG_FILE" 2>&1 || true
    [[ -f "$REPO_LOCAL/Config/Power10kNormal/.p10k.zsh" ]] && sudo -u "$nombre_usuario" cp "$REPO_LOCAL/Config/Power10kNormal/.p10k.zsh" "$user_home/.p10k.zsh" >>"$LOG_FILE" 2>&1 || true
    [[ -f "$REPO_LOCAL/Config/Power10kRoot/.p10k.zsh" ]] && cp "$REPO_LOCAL/Config/Power10kRoot/.p10k.zsh" /root/.p10k.zsh >>"$LOG_FILE" 2>&1 || true

    if [[ -d "$REPO_LOCAL/bin" ]]; then
        sudo_user_cp_dir "$REPO_LOCAL/bin" "$user_home/.config/bin" "Copiar bin"
        chmod +x "$user_home/.config/bin/ethernet_status.sh" "$user_home/.config/bin/hackthebox_status.sh" "$user_home/.config/bin/target_to_hack.sh" >>"$LOG_FILE" 2>&1 || true
    fi

    mkdir -p /usr/share/zsh-sudo-plugin
    [[ -f "$REPO_LOCAL/sudoPlugin/sudo.plugin.zsh" ]] && cp "$REPO_LOCAL/sudoPlugin/sudo.plugin.zsh" /usr/share/zsh-sudo-plugin/ >>"$LOG_FILE" 2>&1 || record_fail "STEP" "sudo.plugin.zsh" "No existe o no se pudo copiar"

    if [[ -d "$REPO_LOCAL/lsd" ]]; then
        cp -r "$REPO_LOCAL/lsd/." "$DOWNLOADS_DIR/" >>"$LOG_FILE" 2>&1 || record_fail "STEP" "Copiar .deb lsd/bat" "No se pudo copiar"
    fi
else
    record_fail "STEP" "ParrotEntorno" "No existe el directorio $REPO_LOCAL"
fi

[[ -f "$DOWNLOADS_DIR/bat_0.24.0_amd64.deb" ]] && dpkg -i "$DOWNLOADS_DIR/bat_0.24.0_amd64.deb" >>"$LOG_FILE" 2>&1 || true
[[ -f "$DOWNLOADS_DIR/lsd_1.1.2_amd64.deb" ]] && dpkg -i "$DOWNLOADS_DIR/lsd_1.1.2_amd64.deb" >>"$LOG_FILE" 2>&1 || true

if [[ -d "$DOWNLOADS_DIR/i3lock-fancy" ]]; then
    cd "$DOWNLOADS_DIR/i3lock-fancy" || true
    make install >>"$LOG_FILE" 2>&1 || record_fail "STEP" "i3lock-fancy" "make install falló"
fi

chsh -s "$(command -v zsh)" root >>"$LOG_FILE" 2>&1 || record_fail "STEP" "chsh root" "No se pudo cambiar shell"
chsh -s "$(command -v zsh)" "$nombre_usuario" >>"$LOG_FILE" 2>&1 || record_fail "STEP" "chsh usuario" "No se pudo cambiar shell"

echo
echo "================ RESUMEN DE INSTALACIÓN ================"
echo "Log completo: $LOG_FILE"
echo "Registro de fallos: $FAIL_FILE"
echo

if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
    echo "Paquetes que fallaron:"
    for item in "${FAILED_PACKAGES[@]}"; do echo " - $item"; done
    echo
fi

if [[ ${#FAILED_DOWNLOADS[@]} -gt 0 ]]; then
    echo "Descargas / clones que fallaron:"
    for item in "${FAILED_DOWNLOADS[@]}"; do echo " - $item"; done
    echo
fi

if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
    echo "Pasos que fallaron:"
    for item in "${FAILED_STEPS[@]}"; do echo " - $item"; done
    echo
fi

if [[ ${#FAILED_PACKAGES[@]} -eq 0 && ${#FAILED_DOWNLOADS[@]} -eq 0 && ${#FAILED_STEPS[@]} -eq 0 ]]; then
    echo "Todo terminó sin errores detectados."
else
    echo "La instalación terminó con errores parciales, pero no se detuvo."
    echo "Revisa el archivo: $FAIL_FILE"
fi

echo
echo "Recomendado: cerrar sesión o reiniciar al finalizar."
