#!/bin/bash
set -Eeuo pipefail

trap 'echo "[!] Error en la línea $LINENO. Revisa el paso anterior."' ERR

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Este script debe ejecutarse como root."
    exit 1
fi

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
    echo "Ejecuta el script con sudo desde tu usuario normal."
    exit 1
fi

USER_NAME="$SUDO_USER"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
DOWNLOADS_DIR="$USER_HOME/Descargas"
PARROT_ENTORNO="$USER_HOME/ParrotEntorno"

log() {
    echo
    echo "[*] $1"
}

require_dir() {
    local dir="$1"
    local desc="$2"
    if [[ ! -d "$dir" ]]; then
        echo "[!] No existe $desc: $dir"
        exit 1
    fi
}

clone_or_update() {
    local repo_url="$1"
    local dest_dir="$2"

    if [[ -d "$dest_dir/.git" ]]; then
        log "Actualizando repositorio $(basename "$dest_dir")..."
        sudo -u "$USER_NAME" git -C "$dest_dir" pull --ff-only || true
    else
        log "Clonando $(basename "$dest_dir")..."
        sudo -u "$USER_NAME" git clone "$repo_url" "$dest_dir"
    fi
}

install_packages() {
    local packages=("$@")
    DEBIAN_FRONTEND=noninteractive apt install -y "${packages[@]}"
}

mkdir -p "$DOWNLOADS_DIR"

log "Respaldando y configurando repositorio oficial de Parrot..."
cp -n /etc/apt/sources.list /etc/apt/sources.list.bak

cat > /etc/apt/sources.list << 'EOF'
deb https://deb.parrot.sh/parrot rolling main contrib non-free non-free-firmware
EOF

log "Actualizando el sistema..."
apt clean
apt update
DEBIAN_FRONTEND=noninteractive parrot-upgrade -y || DEBIAN_FRONTEND=noninteractive apt full-upgrade -y

log "Instalando dependencias base..."
install_packages \
  build-essential git vim pkg-config \
  libxcb1-dev libxcb-util0-dev libxcb-ewmh-dev libxcb-randr0-dev \
  libxcb-icccm4-dev libxcb-keysyms1-dev libxcb-xinerama0-dev \
  libxcb-xtest0-dev libxcb-shape0-dev \
  libxkbcommon-dev libxkbcommon-x11-dev libxcb-xkb-dev \
  libasound2-dev meson ninja-build \
  libxinerama1 libxinerama-dev \
  kitty rofi bspwm zsh zsh-autosuggestions zsh-syntax-highlighting \
  feh imagemagick scrub neofetch npm flameshot i3lock \
  cmake cmake-data python3-sphinx libcairo2-dev libxcb-composite0-dev \
  python3-xcbgen xcb-proto libxcb-image0-dev libxcb-xrm-dev \
  libxcb-cursor-dev libpulse-dev libjsoncpp-dev libmpdclient-dev \
  libuv1-dev libnl-genl-3-dev \
  libxext-dev libxcb-damage0-dev libxcb-xfixes0-dev \
  libxcb-render-util0-dev libxcb-render0-dev libxcb-present-dev \
  libpixman-1-dev libdbus-1-dev libconfig-dev libgl1-mesa-dev \
  libpcre2-dev libevdev-dev uthash-dev libev-dev libx11-xcb-dev \
  libxcb-glx0-dev libpcre3 libpcre3-dev

log "Verificando repositorio local ParrotEntorno..."
require_dir "$PARROT_ENTORNO" "el repositorio ParrotEntorno"

log "Clonando/actualizando bspwm y sxhkd..."
clone_or_update "https://github.com/baskerville/bspwm.git" "$USER_HOME/bspwm"
clone_or_update "https://github.com/baskerville/sxhkd.git" "$USER_HOME/sxhkd"

log "Compilando bspwm..."
cd "$USER_HOME/bspwm"
sudo -u "$USER_NAME" make
make install

log "Compilando sxhkd..."
cd "$USER_HOME/sxhkd"
sudo -u "$USER_NAME" make
make install

log "Preparando directorios de configuración..."
sudo -u "$USER_NAME" mkdir -p \
  "$USER_HOME/.config/bspwm" \
  "$USER_HOME/.config/sxhkd" \
  "$USER_HOME/.config/bspwm/scripts" \
  "$USER_HOME/.config/polybar" \
  "$USER_HOME/.config/picom" \
  "$USER_HOME/.config/kitty" \
  "$USER_HOME/.config/bin" \
  "$USER_HOME/fondos"

if compgen -G "$PARROT_ENTORNO/fondos/*" > /dev/null; then
    sudo -u "$USER_NAME" cp -a "$PARROT_ENTORNO/fondos/." "$USER_HOME/fondos/"
fi

log "Copiando configuración de bspwm y sxhkd..."
sudo -u "$USER_NAME" cp "$PARROT_ENTORNO/Config/bspwm/bspwmrc" "$USER_HOME/.config/bspwm/"
sudo -u "$USER_NAME" cp "$PARROT_ENTORNO/Config/sxhkd/sxhkdrc" "$USER_HOME/.config/sxhkd/"
sudo -u "$USER_NAME" cp "$PARROT_ENTORNO/Config/bspwm/scripts/bspwm_resize" "$USER_HOME/.config/bspwm/scripts/"
chmod +x "$USER_HOME/.config/bspwm/bspwmrc" "$USER_HOME/.config/bspwm/scripts/bspwm_resize"

log "Compilando e instalando Polybar..."
clone_or_update "https://github.com/polybar/polybar" "$DOWNLOADS_DIR/polybar"
cd "$DOWNLOADS_DIR/polybar"
sudo -u "$USER_NAME" git submodule update --init --recursive
mkdir -p build
cd build
sudo -u "$USER_NAME" cmake ..
sudo -u "$USER_NAME" make -j"$(nproc)"
make install

log "Compilando e instalando Picom..."
clone_or_update "https://github.com/ibhagwan/picom.git" "$DOWNLOADS_DIR/picom"
cd "$DOWNLOADS_DIR/picom"
sudo -u "$USER_NAME" git submodule update --init --recursive
sudo -u "$USER_NAME" meson setup --buildtype=release build || sudo -u "$USER_NAME" meson setup --reconfigure --buildtype=release build
sudo -u "$USER_NAME" ninja -C build
ninja -C build install

log "Copiando fuentes personalizadas..."
if compgen -G "$PARROT_ENTORNO/fonts/*" > /dev/null; then
    cp -a "$PARROT_ENTORNO/fonts/." /usr/local/share/fonts/
fi
if compgen -G "$PARROT_ENTORNO/Config/polybar/fonts/*" > /dev/null; then
    cp -a "$PARROT_ENTORNO/Config/polybar/fonts/." /usr/share/fonts/truetype/
fi
fc-cache -f -v

log "Copiando configuración de Kitty..."
sudo -u "$USER_NAME" cp -a "$PARROT_ENTORNO/Config/kitty/." "$USER_HOME/.config/kitty/"
mkdir -p /root/.config/kitty
cp -a "$USER_HOME/.config/kitty/." /root/.config/kitty/

log "Copiando configuración de Polybar y Picom..."
sudo -u "$USER_NAME" cp -a "$PARROT_ENTORNO/Config/polybar/." "$USER_HOME/.config/polybar/"
sudo -u "$USER_NAME" cp "$PARROT_ENTORNO/Config/picom/picom.conf" "$USER_HOME/.config/picom/picom.conf"

log "Clonando blue-sky..."
clone_or_update "https://github.com/VaughnValle/blue-sky" "$DOWNLOADS_DIR/blue-sky"

log "Configurando powerlevel10k..."
clone_or_update "https://github.com/romkatv/powerlevel10k.git" "$USER_HOME/powerlevel10k"
clone_or_update "https://github.com/romkatv/powerlevel10k.git" "/root/powerlevel10k"

log "Copiando .zshrc y .p10k.zsh..."
cp "$PARROT_ENTORNO/Config/zshrc/user/.zshrc" "$USER_HOME/.zshrc"
chown "$USER_NAME:$USER_NAME" "$USER_HOME/.zshrc"
chmod 644 "$USER_HOME/.zshrc"

cp "$PARROT_ENTORNO/Config/zshrc/root/.zshrc" /root/.zshrc
chown root:root /root/.zshrc
chmod 644 /root/.zshrc

sudo -u "$USER_NAME" cp "$PARROT_ENTORNO/Config/Power10kNormal/.p10k.zsh" "$USER_HOME/.p10k.zsh"
cp "$PARROT_ENTORNO/Config/Power10kRoot/.p10k.zsh" /root/.p10k.zsh

log "Copiando binarios y scripts auxiliares..."
if compgen -G "$PARROT_ENTORNO/bin/*" > /dev/null; then
    sudo -u "$USER_NAME" cp -a "$PARROT_ENTORNO/bin/." "$USER_HOME/.config/bin/"
fi
chmod +x \
  "$USER_HOME/.config/bin/ethernet_status.sh" \
  "$USER_HOME/.config/bin/hackthebox_status.sh" \
  "$USER_HOME/.config/bin/target_to_hack.sh" || true

log "Configurando plugin sudo para zsh..."
mkdir -p /usr/share/zsh-sudo-plugin
cp "$PARROT_ENTORNO/sudoPlugin/sudo.plugin.zsh" /usr/share/zsh-sudo-plugin/
chmod 755 /usr/share/zsh-sudo-plugin/sudo.plugin.zsh

log "Copiando paquetes .deb de lsd/bat..."
if [[ -d "$PARROT_ENTORNO/lsd" ]]; then
    cp -a "$PARROT_ENTORNO/lsd/." "$DOWNLOADS_DIR/"
fi

if [[ -f "$DOWNLOADS_DIR/bat_0.24.0_amd64.deb" ]]; then
    dpkg -i "$DOWNLOADS_DIR/bat_0.24.0_amd64.deb" || apt -f install -y
fi
if [[ -f "$DOWNLOADS_DIR/lsd_1.1.2_amd64.deb" ]]; then
    dpkg -i "$DOWNLOADS_DIR/lsd_1.1.2_amd64.deb" || apt -f install -y
fi

log "Clonando e instalando i3lock-fancy..."
clone_or_update "https://github.com/meskarune/i3lock-fancy.git" "$DOWNLOADS_DIR/i3lock-fancy"
cd "$DOWNLOADS_DIR/i3lock-fancy"
make install

log "Cambiando shell por defecto a zsh..."
chsh -s "$(command -v zsh)" root
chsh -s "$(command -v zsh)" "$USER_NAME"

export TERM=xterm-256color

log "Instalación completada."
echo "[*] Recomendado: cierra sesión o reinicia el sistema para aplicar todos los cambios."
