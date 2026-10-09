#!/usr/bin/env bash
# =============================================================================
#  lib.sh - shared helpers for the iShowLyrics scripts
#  Author: iShowSomeone    Version: 1.0.1
#
#  Sourced by install.sh, ishowlyrics, verify.sh and doctor.sh.
#  Not meant to be run directly.
#
#  Contents:
#    1. paths and constants          5. fonts (detect + install)
#    2. output helpers               6. settings (defaults, wizard, apply)
#    3. prompt helpers               7. widget control (start/stop/autostart)
#    4. packages and dependencies    8. integrity manifest + uninstall
# =============================================================================

# ------------------------------------------------------------ 1. constants --

ISL_VERSION="1.0.1"
ISL_AUTHOR="iShowSomeone"
ISL_HOME="${ISL_HOME:-$HOME/iShowLyrics}"          # fixed install location
ISL_SETTINGS="$ISL_HOME/settings.env"              # your saved answers (the defaults)
ISL_BIN_LINK="$HOME/.local/bin/ishowlyrics"        # makes `ishowlyrics` a command
ISL_AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/ishowlyrics.desktop"
ISL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ishowlyrics"
ISL_RUN="${XDG_RUNTIME_DIR:-/tmp}/ishowlyrics"
ISL_FONT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/ishowlyrics"

ISL_CODE_FILES=(lib.sh ishowlyrics verify.sh doctor.sh clickthrough.py)   # never edited by the installer
ISL_ALL_FILES=(lyrics.py lyrics.lua lyrics.conf "${ISL_CODE_FILES[@]}")

ASSUME_DEFAULTS="${ASSUME_DEFAULTS:-0}"

# ------------------------------------------------------------- 2. output ----

if [[ -t 1 ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[36m'; N=$'\e[0m'
else
  B=""; G=""; Y=""; R=""; D=""; N=""
fi
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Check results used by verify.sh and doctor.sh (they keep counters).
CHK_OK=0; CHK_WARN=0; CHK_FAIL=0
chk_ok()   { CHK_OK=$((CHK_OK + 1));     printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
chk_warn() { CHK_WARN=$((CHK_WARN + 1)); printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
chk_fail() { CHK_FAIL=$((CHK_FAIL + 1)); printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
fix()      { printf '      %sFix:%s %s\n' "$D" "$N" "$*"; }
note()     { printf '      %s%s%s\n' "$D" "$*" "$N"; }

# ------------------------------------------------------------ 3. prompts ----

# Without a terminal (or with --defaults) nothing is asked: defaults are used.
init_tty() {
  if (( ! ASSUME_DEFAULTS )) && ! ( exec 0</dev/tty ) 2>/dev/null; then
    warn "No terminal available for questions; using the default answers."
    ASSUME_DEFAULTS=1
  fi
}

# Show a prompt and read one line into REPLY (trimmed). Empty in --defaults mode.
read_tty() {
  if (( ASSUME_DEFAULTS )); then REPLY=""; return 0; fi
  printf '%s' "$1" > /dev/tty
  IFS= read -r REPLY < /dev/tty || REPLY=""
  REPLY="${REPLY#"${REPLY%%[![:space:]]*}"}"
  REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
}

# ask VAR "Question" "default"
ask() {
  local __var=$1 q=$2 def=$3
  read_tty "$q [${def:-none}]: "
  printf -v "$__var" '%s' "${REPLY:-$def}"
}

# ask_int VAR "Question" default
ask_int() {
  local __var=$1 q=$2 def=$3 v
  while true; do
    read_tty "$q [$def]: "; v="${REPLY:-$def}"
    [[ $v =~ ^-?[0-9]+$ ]] && break
    warn "Please enter a whole number."
  done
  printf -v "$__var" '%s' "$v"
}

# ask_num VAR "Question" default   (decimal such as 0.20)
ask_num() {
  local __var=$1 q=$2 def=$3 v
  while true; do
    read_tty "$q [$def]: "; v="${REPLY:-$def}"
    [[ $v =~ ^-?[0-9]*\.?[0-9]+$ ]] && break
    warn "Please enter a number such as 0.20"
  done
  printf -v "$__var" '%s' "$v"
}

# ask_hex VAR "Question" default   (6 hex digits, no #)
ask_hex() {
  local __var=$1 q=$2 def=$3 v
  while true; do
    read_tty "$q [$def]: "; v="${REPLY:-$def}"; v="${v#\#}"
    [[ $v =~ ^[0-9A-Fa-f]{6}$ ]] && break
    warn "Enter 6 hex digits, e.g. FF1A1A"
  done
  printf -v "$__var" '%s' "${v^^}"
}

# yesno "Question" y|n   -> success for yes; re-asks on unclear answers
yesno() {
  local def=$2 hint="[y/N]" a
  [[ $def == y ]] && hint="[Y/n]"
  while true; do
    read_tty "$1 $hint: "
    a="${REPLY:-$def}"
    case "${a,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
    warn "Please answer y or n."
  done
}

# choose VAR "Question" default_number "option 1" "option 2" ...
choose() {
  local __var=$1 q=$2 def=$3 c i
  shift 3
  local opts=("$@")
  say "$q"
  for i in "${!opts[@]}"; do printf '  %d) %s\n' $((i + 1)) "${opts[$i]}"; done
  while true; do
    read_tty "Choose [$def]: "; c="${REPLY:-$def}"
    if [[ $c =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#opts[@]} )); then break; fi
    warn "Enter a number between 1 and ${#opts[@]}."
  done
  printf -v "$__var" '%s' "$c"
}

# "a, b" -> ["a", "b"]   (for the Python settings)
to_py_list() {
  local item out="" parts=()
  IFS=',' read -ra parts <<<"$1"
  for item in "${parts[@]}"; do
    item="${item//[\"\\]/}"
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -z $item || ${item,,} == none ]] && continue
    out+="${out:+, }\"$item\""
  done
  printf '[%s]' "$out"
}

# ------------------------------------------------- 4. packages / dependencies

detect_pm() {
  local c
  for c in apt-get dnf pacman zypper; do
    if have "$c"; then echo "$c"; return 0; fi
  done
  return 0
}

pm_install() {
  case "$(detect_pm)" in
    apt-get) sudo apt-get install -y "$@" ;;
    dnf)     sudo dnf install -y "$@" ;;
    pacman)  sudo pacman -S --needed --noconfirm "$@" ;;
    zypper)  sudo zypper install -y "$@" ;;
    *)       return 1 ;;
  esac
}

# Human-readable install command for hints ("Fix: ...")
install_cmd() {
  case "$(detect_pm)" in
    apt-get) echo "sudo apt install $*" ;;
    dnf)     echo "sudo dnf install $*" ;;
    pacman)  echo "sudo pacman -S $*" ;;
    zypper)  echo "sudo zypper install $*" ;;
    *)       echo "(install with your package manager: $*)" ;;
  esac
}

# generic dependency name -> package name on this distro
pkg_for() {
  case "$(detect_pm):$1" in
    pacman:python3) echo python ;;
    apt-get:conky)  echo conky-all ;;
    *)              echo "$1" ;;
  esac
}

conky_has_cairo() { have conky && [[ "$(conky -v 2>&1)" == *[Cc]airo* ]]; }

# Prints the generic names of missing dependencies, one per line.
missing_deps() {
  have python3   || echo python3
  have playerctl || echo playerctl
  have perl      || echo perl
  have fc-list   || echo fontconfig
  conky_has_cairo || echo conky
  return 0
}

ensure_deps() {
  step "Checking dependencies"
  local pkgs=() m
  while IFS= read -r m; do
    if [[ -n $m ]]; then pkgs+=("$(pkg_for "$m")"); fi
  done < <(missing_deps)

  if (( ${#pkgs[@]} )); then
    say "Missing packages: ${pkgs[*]}"
    [[ -n "$(detect_pm)" ]] || die "No supported package manager found. Install manually: ${pkgs[*]}"
    yesno "Install them now (needs sudo)?" y || die "Cannot continue without: ${pkgs[*]}"
    pm_install "${pkgs[@]}" || die "Package installation failed."
  fi

  have conky || die "Conky is still missing."
  conky_has_cairo || die "Conky has no Cairo support. On Debian/Ubuntu install 'conky-all'; elsewhere look for a Cairo-enabled build."
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' || die "Python 3.8 or newer is required."
  refresh_fonts
  ok "conky (Lua + Cairo), playerctl, python3, perl and fontconfig are available"
}

check_session() {
  local s="${XDG_SESSION_TYPE:-unknown}"
  ok "Session: $s (${XDG_CURRENT_DESKTOP:-unknown desktop})"
  if [[ $s == wayland ]] && ! have Xwayland; then
    warn "Conky draws through XWayland, which was not found. The widget may not appear."
  fi
}

# ------------------------------------------------------------- 5. fonts -----

FONT_LIST=""
refresh_fonts() { FONT_LIST="$(fc-list : family 2>/dev/null | tr ',' '\n' | sort -u)"; }
has_font() {
  [[ -n $FONT_LIST ]] || refresh_fonts
  grep -qixF -- "$1" <<<"$FONT_LIST"
}

# Open-source fonts that can be downloaded automatically (SIL Open Font License).
# Format: family|file name|download URL
FREE_FONTS=(
  "Anton|Anton-Regular.ttf|https://raw.githubusercontent.com/google/fonts/main/ofl/anton/Anton-Regular.ttf"
  "Bebas Neue|BebasNeue-Regular.ttf|https://raw.githubusercontent.com/google/fonts/main/ofl/bebasneue/BebasNeue-Regular.ttf"
  "Archivo Black|ArchivoBlack-Regular.ttf|https://raw.githubusercontent.com/google/fonts/main/ofl/archivoblack/ArchivoBlack-Regular.ttf"
)
FONT_CHOICES=("Impact" "Anton" "Bebas Neue" "Archivo Black" "DejaVu Sans")

font_blurb() {
  case "$1" in
    Impact)          echo "bold, matches heavy clock widgets" ;;
    Anton)           echo "free look-alike of Impact" ;;
    "Bebas Neue")    echo "free, tall and condensed" ;;
    "Archivo Black") echo "free, wide and bold" ;;
    "DejaVu Sans")   echo "clean, wide Unicode coverage" ;;
  esac
}

font_status() {
  if has_font "$1"; then echo "installed"; return 0; fi
  case "$1" in
    Impact)        [[ "$(detect_pm)" == apt-get ]] && echo "will be installed (Microsoft fonts)" || echo "can't be auto-installed here" ;;
    "DejaVu Sans") echo "will be installed" ;;
    *)             echo "free, will be downloaded" ;;
  esac
}

# download URL DEST   (curl, wget or python; result must look like a real file)
download() {
  if have curl;   then curl -fsSL --max-time 60 -o "$2" "$1" || return 1
  elif have wget; then wget -q -T 60 -O "$2" "$1" || return 1
  else python3 -c 'import sys,urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])' "$1" "$2" || return 1
  fi
  [[ -s $2 && $(stat -c %s "$2") -gt 10000 ]]
}

install_free_font() {
  local name=$1 entry n file url found=""
  for entry in "${FREE_FONTS[@]}"; do
    IFS='|' read -r n file url <<<"$entry"
    if [[ ${n,,} == "${name,,}" ]]; then found=1; break; fi
  done
  [[ -n $found ]] || return 1
  mkdir -p "$ISL_FONT_DIR"
  say "Downloading $n (open-source font)..."
  if ! download "$url" "$ISL_FONT_DIR/$file"; then
    rm -f "$ISL_FONT_DIR/$file"
    warn "Download failed. Check your internet connection."
    return 1
  fi
  fc-cache -f "$ISL_FONT_DIR" >/dev/null 2>&1 || true
  refresh_fonts
  has_font "$n"
}

install_impact() {
  if [[ "$(detect_pm)" != apt-get ]]; then
    warn "Impact (a Microsoft font) can only be installed automatically on Debian/Ubuntu."
    return 1
  fi
  say "Impact comes in the 'ttf-mscorefonts-installer' package. It downloads Microsoft's"
  say "web fonts and requires accepting their license (EULA)."
  yesno "Accept the Microsoft fonts license and install?" n || return 1
  echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" \
    | sudo debconf-set-selections || return 1
  if ! sudo apt-get install -y ttf-mscorefonts-installer; then
    warn "Install failed. On Ubuntu the 'multiverse' repository must be enabled."
    return 1
  fi
  fc-cache -f >/dev/null 2>&1 || true
  refresh_fonts
  has_font Impact
}

install_dejavu() {
  local pkg
  case "$(detect_pm)" in
    apt-get) pkg=fonts-dejavu-core ;;
    dnf)     pkg=dejavu-sans-fonts ;;
    pacman)  pkg=ttf-dejavu ;;
    zypper)  pkg=dejavu-fonts ;;
    *)       return 1 ;;
  esac
  pm_install "$pkg" || return 1
  refresh_fonts
  has_font "DejaVu Sans"
}

install_font() {
  case "${1,,}" in
    impact)        install_impact ;;
    "dejavu sans") install_dejavu ;;
    *)             install_free_font "$1" ;;
  esac
}

# Make sure the font in $1 exists. Installs it, or falls back (and updates FONT).
ensure_font() {
  local name=$1 fb fallbacks=("DejaVu Sans")
  has_font "$name" && return 0
  say "Font '$name' is not installed."

  local listed=0 c
  for c in "${FONT_CHOICES[@]}"; do [[ $c == "$name" ]] && listed=1; done
  if (( ! listed )); then
    warn "'$name' is not one of the fonts iShowLyrics can install for you."
    yesno "Use it anyway (Cairo substitutes a default font if it is missing)?" n && return 0
  elif install_font "$name"; then
    ok "Installed font '$name'"; return 0
  else
    warn "Could not install '$name'."
  fi

  [[ $name == Impact ]] && fallbacks=(Anton "DejaVu Sans")
  for fb in "${fallbacks[@]}"; do
    if has_font "$fb" || install_font "$fb"; then
      warn "Using '$fb' instead."; FONT="$fb"; return 0
    fi
  done
  warn "No fallback font could be installed; Cairo will pick a default font."
  return 0
}

pick_font() {
  local opts=() i f def=0 fc
  for i in "${!FONT_CHOICES[@]}"; do
    f="${FONT_CHOICES[$i]}"
    opts+=("$f - $(font_blurb "$f") [$(font_status "$f")]")
    [[ $f == "$FONT" ]] && def=$((i + 1))
  done
  opts+=("Other (type a font family name)")
  (( def )) || def=$(( ${#FONT_CHOICES[@]} + 1 ))
  choose fc "Font" "$def" "${opts[@]}"
  if (( fc <= ${#FONT_CHOICES[@]} )); then
    FONT="${FONT_CHOICES[$((fc - 1))]}"
  else
    ask FONT "Font family (list them with: fc-list : family)" "$FONT"
  fi
  ensure_font "$FONT"
}

# ----------------------------------------------------------- 6. settings ----
# Your answers live in $ISL_SETTINGS and become the defaults the next time you
# run install.sh, `ishowlyrics config` or `ishowlyrics verify`.

SETTING_KEYS=(POS_IDX GAP_X GAP_Y TA_IDX FONT SZ_IDX WIDTH KARAOKE SHOW_META
              CC_IDX SUNG UNSUNG FP_IDX PREFER IGNORE LOOKAHEAD SHADOW GLOW
              PIN_MODE LAYER CLICK_THROUGH AUTOSTART)

default_ta_idx() {                       # natural text alignment for a position
  case "$1" in 1|4|6) echo 1 ;; 2|5|7) echo 2 ;; *) echo 3 ;; esac
}

# Sets SIZES, LINE_GAP, MAXSZ and W_DEF for a size preset (1 compact, 2 medium, 3 large)
preset_vals() {
  case "$1" in
    1) SIZES="{24, 16, 12, 10, 8}";  LINE_GAP=28; MAXSZ=24; W_DEF=520 ;;
    3) SIZES="{38, 26, 19, 15, 12}"; LINE_GAP=44; MAXSZ=38; W_DEF=760 ;;
    *) SIZES="{30, 20, 15, 12, 10}"; LINE_GAP=35; MAXSZ=30; W_DEF=620 ;;
  esac
}

set_defaults() {
  POS_IDX=1; GAP_X=60; GAP_Y=0; TA_IDX=""
  FONT="Impact"; SZ_IDX=2; WIDTH=""
  KARAOKE=false; SHOW_META=true
  CC_IDX=1; SUNG=FF1A1A; UNSUNG=991212
  FP_IDX=1; PREFER=""; IGNORE=""
  LOOKAHEAD=0.20; SHADOW=true; GLOW=true
  PIN_MODE=""; LAYER=auto; CLICK_THROUGH=true; AUTOSTART=1
}

fill_defaults() {
  [[ -n $TA_IDX ]] || TA_IDX="$(default_ta_idx "$POS_IDX")"
  if [[ -z $WIDTH ]]; then preset_vals "$SZ_IDX"; WIDTH=$W_DEF; fi
}

load_settings() {
  set_defaults
  # shellcheck disable=SC1090
  if [[ -f $ISL_SETTINGS ]]; then source "$ISL_SETTINGS"; fi
  fill_defaults
}

save_settings() {
  local k
  {
    echo "# iShowLyrics settings - written by install.sh / 'ishowlyrics config'."
    echo "# These are the defaults offered the next time you change your configuration."
    for k in "${SETTING_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k}"; done
  } > "$ISL_SETTINGS"
}

# Turns the saved answers into the values written into the files.
derive_settings() {
  local codes=(mr ml mm tr tl br bl tm bm) tas=(right left center) fps=(0.016 0.025 0.033)
  fill_defaults
  WIN_ALIGN="${codes[$((POS_IDX - 1))]}"
  TEXT_ALIGN="${tas[$((TA_IDX - 1))]}"
  INTERVAL="${fps[$((FP_IDX - 1))]}"
  preset_vals "$SZ_IDX"
  # window height: room for the visible lines on both sides + the title row + margin
  HEIGHT=$(( 2 * 4 * LINE_GAP + MAXSZ + 40 ))
  PREFER_LIST="$(to_py_list "$PREFER")"
  IGNORE_LIST="$(to_py_list "$IGNORE")"
}

# The interactive questions. Current values are the defaults.
run_wizard() {
  local def_yn

  step "Position on screen"
  choose POS_IDX "Where should the lyrics appear?" "$POS_IDX" \
    "Middle right" "Middle left" "Center" "Top right" "Top left" \
    "Bottom right" "Bottom left" "Top middle" "Bottom middle"
  ask_int GAP_X "Distance from the left/right screen edge in px" "$GAP_X"
  ask_int GAP_Y "Distance from the top/bottom screen edge in px" "$GAP_Y"
  [[ -n $TA_IDX ]] || TA_IDX="$(default_ta_idx "$POS_IDX")"
  choose TA_IDX "Text alignment inside the widget" "$TA_IDX" "Right" "Left" "Center"

  step "Look"
  pick_font
  choose SZ_IDX "Text size" "$SZ_IDX" "Compact" "Medium (recommended)" "Large"
  preset_vals "$SZ_IDX"
  [[ -n $WIDTH ]] || WIDTH=$W_DEF
  ask_int WIDTH "Widget width in px (longer lines shrink to fit)" "$WIDTH"

  def_yn=n; [[ $SHOW_META == true ]] && def_yn=y
  if yesno "Show 'song | artist' under the lyrics?" "$def_yn"; then SHOW_META=true; else SHOW_META=false; fi

  def_yn=n; [[ $KARAOKE == true ]] && def_yn=y
  if yesno "Karaoke sweep (colour fills the current line as it is sung)?" "$def_yn"; then KARAOKE=true; else KARAOKE=false; fi

  choose CC_IDX "Colour theme" "$CC_IDX" \
    "Red" "Ember orange" "Ice blue" "White" "Custom hex colours"
  case $CC_IDX in
    1) SUNG=FF1A1A; UNSUNG=991212 ;;
    2) SUNG=FF7A1A; UNSUNG=99480F ;;
    3) SUNG=4FC3FF; UNSUNG=2A6F99 ;;
    4) SUNG=FFFFFF; UNSUNG=8A8A8A ;;
    5) ask_hex SUNG "Main colour (hex)" "$SUNG"
       ask_hex UNSUNG "Dim colour for not-yet-sung text and the song title (hex)" "$UNSUNG" ;;
  esac

  choose FP_IDX "Animation smoothness" "$FP_IDX" \
    "60 fps (smoothest)" "40 fps" "30 fps (lightest on CPU)"

  step "Music players"
  say "Detected right now: $( { playerctl -l 2>/dev/null || true; } | tr '\n' ' ')"
  say "Names are matched as substrings, e.g. spotify, brave, org.gnome.Music"
  ask PREFER "Preferred players, comma separated (blank = automatic)" "$PREFER"
  ask IGNORE "Players to ignore, comma separated (blank = none)" "$IGNORE"
  [[ ${PREFER,,} == none ]] && PREFER=""
  [[ ${IGNORE,,} == none ]] && IGNORE=""

  if yesno "Show advanced options?" n; then
    ask_num LOOKAHEAD "Timing offset in seconds (raise if lines feel late)" "$LOOKAHEAD"
    def_yn=n; [[ $SHADOW == true ]] && def_yn=y
    if yesno "Dark text shadow?" "$def_yn"; then SHADOW=true; else SHADOW=false; fi
    def_yn=n; [[ $GLOW == true ]] && def_yn=y
    if yesno "Soft glow around the current line?" "$def_yn"; then GLOW=true; else GLOW=false; fi
    def_yn=n; [[ $CLICK_THROUGH == true ]] && def_yn=y
    if yesno "Let mouse clicks pass through the widget (always on while pinned)?" "$def_yn"; then CLICK_THROUGH=true; else CLICK_THROUGH=false; fi
  fi

  step "Window behaviour"
  local ldef=1 lidx
  case "$LAYER" in desktop) ldef=2 ;; below) ldef=3 ;; override) ldef=4 ;; esac
  detect_env
  choose lidx "Window layer (how the widget stacks with other windows)" "$ldef" \
    "Auto - recommended for this session ($ENV_FAMILY on $ENV_SESSION -> $(LAYER=auto resolve_layer))" \
    "Desktop layer - classic Conky, behind everything" \
    "Normal window kept below others - reliable on GNOME/KDE Wayland" \
    "Unmanaged overlay - for Sway and tiling window managers (Hyprland: unoptimized)"
  case $lidx in 1) LAYER=auto ;; 2) LAYER=desktop ;; 3) LAYER=below ;; 4) LAYER=override ;; esac
  def_yn=n; [[ -n $PIN_MODE ]] && def_yn=y
  if yesno "Pin on top (keep the widget above other windows)? Change later with 'ishowlyrics pin' / 'unpin'" "$def_yn"; then
    [[ -n $PIN_MODE ]] || PIN_MODE=normal
  else
    PIN_MODE=""
  fi
  def_yn=n; [[ $AUTOSTART == 1 ]] && def_yn=y
  if yesno "Start the widget automatically at login?" "$def_yn"; then AUTOSTART=1; else AUTOSTART=0; fi
}

print_summary() {
  derive_settings
  cat <<EOF
  Install directory : $ISL_HOME
  Position          : $WIN_ALIGN  (gap_x $GAP_X, gap_y $GAP_Y), text aligned $TEXT_ALIGN
  Window size       : ${WIDTH}x${HEIGHT}
  Font / sizes      : $FONT  $SIZES  (line gap $LINE_GAP)
  Colours           : $SUNG / $UNSUNG   karaoke: $KARAOKE   song title row: $SHOW_META
  Frame interval    : ${INTERVAL}s
  Players           : prefer $PREFER_LIST, ignore $IGNORE_LIST
  Timing offset     : ${LOOKAHEAD}s   shadow: $SHADOW   glow: $GLOW
  Window layer      : ${LAYER} -> $(resolve_layer)   pin on top: ${PIN_MODE:-off}   click-through: $CLICK_THROUGH
  Autostart         : $([[ $AUTOSTART == 1 ]] && echo yes || echo no)
EOF
}

# --- reading and patching the setting lines in the files (comments are kept) --

read_lua()  { NAME="$1" perl -ne 'if (/^local \Q$ENV{NAME}\E\s*=\s*(\{[^}]*\}|"[^"]*"|\S+)/) { print $1; exit }' "$ISL_HOME/lyrics.lua" 2>/dev/null; }
read_py()   { NAME="$1" perl -ne 'if (/^\Q$ENV{NAME}\E\s*=\s*(\[[^\]]*\]|\S+)/) { print $1; exit }' "$ISL_HOME/lyrics.py" 2>/dev/null; }
read_conf() { KEY="$1"  perl -ne 'if (/^\Q$ENV{KEY}\E\s+(\d+\s+\d+|\S+)/) { print $1; exit }' "$ISL_HOME/lyrics.conf" 2>/dev/null; }

patch_lua() {
  local name=$1 value=$2 file="$ISL_HOME/lyrics.lua"
  if ! grep -qE "^local ${name}[[:space:]]*=" "$file"; then
    warn "Setting $name not found in lyrics.lua (skipped)"; return 0
  fi
  NAME="$name" VAL="$value" perl -pi -e \
    's/^(local \Q$ENV{NAME}\E\s*=\s*)(\{[^}]*\}|"[^"]*"|\S+)/$1$ENV{VAL}/' "$file"
}

patch_py() {
  local name=$1 value=$2 file="$ISL_HOME/lyrics.py"
  if ! grep -qE "^${name}[[:space:]]*=" "$file"; then
    warn "Setting $name not found in lyrics.py (skipped)"; return 0
  fi
  NAME="$name" VAL="$value" perl -pi -e \
    's/^(\Q$ENV{NAME}\E\s*=\s*)(\[[^\]]*\]|\S+)/$1$ENV{VAL}/' "$file"
}

patch_conf() {
  local key=$1 value=$2 file="$ISL_HOME/lyrics.conf"
  if ! grep -qE "^${key}[[:space:]]" "$file"; then
    warn "Setting $key not found in lyrics.conf (skipped)"; return 0
  fi
  KEY="$key" VAL="$value" perl -pi -e \
    's/^(\Q$ENV{KEY}\E\s+)(?:\d+\s+\d+|\S+)/$1$ENV{VAL}/' "$file"
}

# Writes every saved answer into the files.
apply_settings() {
  derive_settings
  patch_lua FONT         "\"$FONT\""
  patch_lua SIZES        "$SIZES"
  patch_lua LINE_GAP     "$LINE_GAP"
  patch_lua ALIGN        "\"$TEXT_ALIGN\""
  patch_lua COLOR_SUNG   "\"$SUNG\""
  patch_lua COLOR_UNSUNG "\"$UNSUNG\""
  patch_lua KARAOKE      "$KARAOKE"
  patch_lua SHOW_META    "$SHOW_META"
  patch_lua LOOKAHEAD    "$LOOKAHEAD"
  patch_lua SHADOW       "$SHADOW"
  patch_lua GLOW         "$GLOW"

  patch_py PREFER_PLAYERS "$PREFER_LIST"
  patch_py IGNORE_PLAYERS "$IGNORE_LIST"

  patch_conf update_interval "$INTERVAL"
  patch_conf minimum_size    "$WIDTH $HEIGHT"
  patch_conf maximum_width   "$WIDTH"
  patch_conf alignment       "$WIN_ALIGN"
  patch_conf gap_x           "$GAP_X"
  patch_conf gap_y           "$GAP_Y"
  patch_conf lua_load        "$ISL_HOME/lyrics.lua"
  apply_layer
}

# ------------------------------------------- desktop environment / layers ----
# Conky draws through X11 (on Wayland desktops: through XWayland). How the window
# should be stacked differs per desktop, so the default ("auto") is chosen from
# what we detect. GNOME and KDE are tested. Hyprland works but is unoptimized and
# not recommended. The other desktops follow how Conky is known to behave there
# and are untested.

detect_env() {
  ENV_SESSION="${XDG_SESSION_TYPE:-unknown}"
  if [[ $ENV_SESSION == unknown && -n ${WAYLAND_DISPLAY:-} ]]; then ENV_SESSION=wayland; fi
  if [[ $ENV_SESSION == unknown && -n ${DISPLAY:-} ]]; then ENV_SESSION=x11; fi
  local de="${XDG_CURRENT_DESKTOP:-}:${DESKTOP_SESSION:-}"
  de="${de,,}"
  ENV_FAMILY=other
  if   [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} || $de == *hyprland* ]]; then ENV_FAMILY=hyprland
  elif [[ -n ${SWAYSOCK:-} || $de == *sway* ]]; then ENV_FAMILY=sway
  elif [[ $de == *gnome* || $de == *ubuntu* || $de == *unity* || $de == *budgie* ]]; then ENV_FAMILY=gnome
  elif [[ $de == *kde* || $de == *plasma* ]]; then ENV_FAMILY=kde
  elif [[ $de == *xfce* || $de == *cinnamon* || $de == *mate* || $de == *lxqt* || $de == *lxde* || $de == *pantheon* || $de == *deepin* ]]; then ENV_FAMILY=x11-desktop
  elif [[ $de == *i3* || $de == *bspwm* || $de == *awesome* || $de == *openbox* || $de == *dwm* || $de == *qtile* || $de == *herbstluftwm* || $de == *xmonad* || $de == *leftwm* ]]; then ENV_FAMILY=tiling
  elif [[ $de == *river* || $de == *wayfire* || $de == *labwc* || $de == *niri* || $de == *cosmic* ]]; then ENV_FAMILY=wlroots
  fi
}

# Prints the base layer for $LAYER: desktop | below | override   (auto => by environment)
resolve_layer() {
  case "${LAYER:-auto}" in desktop|below|override) echo "$LAYER"; return 0 ;; esac
  detect_env
  case "$ENV_FAMILY:$ENV_SESSION" in
    gnome:wayland|kde:wayland)                 echo below ;;     # normal window kept below other windows
    hyprland:*|sway:*|wlroots:*|tiling:*)      echo override ;;  # unmanaged overlay window
    *:wayland)                                 echo override ;;
    *)                                         echo desktop ;;   # classic Conky desktop layer
  esac
}

# Sets LAYER_TYPE and LAYER_HINTS (what lyrics.conf should contain right now)
layer_params() {
  if [[ -n $PIN_MODE ]]; then
    LAYER_HINTS="undecorated,above,sticky,skip_taskbar,skip_pager"
    if [[ $PIN_MODE == override ]]; then LAYER_TYPE=override; else LAYER_TYPE=normal; fi
  else
    LAYER_HINTS="undecorated,below,sticky,skip_taskbar,skip_pager"
    case "$(resolve_layer)" in below) LAYER_TYPE=normal ;; override) LAYER_TYPE=override ;; *) LAYER_TYPE=desktop ;; esac
  fi
}

# Writes the window type/hints for the current pin state and layer into lyrics.conf.
apply_layer() {
  layer_params
  patch_conf own_window_type  "$LAYER_TYPE"
  patch_conf own_window_hints "$LAYER_HINTS"
}

env_tips() {
  detect_env
  say "  Desktop  : ${XDG_CURRENT_DESKTOP:-unknown} ($ENV_SESSION), treated as '$ENV_FAMILY'"
  say "  Layer    : $(resolve_layer)  (setting: ${LAYER:-auto}${PIN_MODE:+, pinned on top})"
  case "$ENV_FAMILY:$ENV_SESSION" in
    gnome:wayland)
      note "GNOME on Wayland: Conky runs through XWayland. The widget is a normal window kept below your apps,"
      note "which is more reliable here than the classic desktop layer. If it ever vanishes: ishowlyrics reset" ;;
    gnome:*)
      note "GNOME on X11: the classic desktop layer works well. If the widget ever vanishes: ishowlyrics reset" ;;
    kde:*)
      note "KDE Plasma: if the widget appears above your windows or in the task bar, add a"
      note "KWin rule: System Settings > Window Management > Window Rules > Window class 'iShowLyrics' >"
      note "'Keep below' = Force and 'Skip taskbar' = Force." ;;
    hyprland:*)
      note "Hyprland (works, but unoptimized and not recommended): Conky runs through XWayland as an unmanaged overlay window, which"
      note "tiling rules normally leave alone. If it gets tiled or gets a border, add window rules for the class"
      note "'iShowLyrics' (float, no border, no shadow, no focus). The rule syntax differs between Hyprland versions:"
      note "see the 'Window Rules' page of the Hyprland wiki." ;;
    sway:*)
      note "Sway (untested): add to your config:"
      note "  for_window [class=\"iShowLyrics\"] floating enable, sticky enable, border none" ;;
    tiling:*)
      note "Tiling window manager (untested): the widget is an unmanaged overlay window. If your WM"
      note "still tiles it, make windows of class 'iShowLyrics' floating (i3: for_window [class=\"iShowLyrics\"] floating enable, border none)." ;;
    x11-desktop:*)
      note "Classic X11 desktop (untested): the desktop layer is used. If the widget hides behind your"
      note "wallpaper or icons try: ishowlyrics reset below" ;;
    *)
      note "Unrecognised desktop: a safe default was chosen. If the widget is invisible try, one at a time:"
      note "  ishowlyrics reset desktop   |   ishowlyrics reset below   |   ishowlyrics reset override" ;;
  esac
}

# ------------------------------------------------------ 7. widget control ----

isl_installed()        { [[ -f $ISL_HOME/lyrics.conf && -f $ISL_HOME/lyrics.lua && -f $ISL_HOME/lyrics.py ]]; }
isl_conky_running()    { pgrep -f "conky -c $ISL_HOME/lyrics.conf" >/dev/null 2>&1; }
isl_daemon_running()   { pgrep -f "lyrics.py --daemon" >/dev/null 2>&1; }

isl_stop() {
  pkill -f "lyrics.py --daemon" 2>/dev/null || true
  pkill -f "conky -c $ISL_HOME/lyrics.conf" 2>/dev/null || true
}

isl_start() {
  isl_stop
  sleep 0.3
  rm -f "$ISL_RUN/state" "$ISL_RUN/perf"          # no stale data from the previous run
  load_settings
  setsid python3 "$ISL_HOME/lyrics.py" --daemon >/dev/null 2>&1 &
  sleep 0.5
  setsid conky -c "$ISL_HOME/lyrics.conf" >/dev/null 2>&1 &
  # let mouse clicks fall through the widget. Always when pinned (otherwise it would
  # cover what is underneath), otherwise when CLICK_THROUGH is on.
  if [[ -n $PIN_MODE || $CLICK_THROUGH == true ]]; then
    setsid python3 "$ISL_HOME/clickthrough.py" apply --wait 20 >/dev/null 2>&1 &
  fi
  sleep 0.5
}

# For autostart: wait (up to ~45 s) until the desktop is really up, then a few more
# seconds. Starting too early can leave the widget stuck behind the desktop.
wait_session_ready() {
  local i
  for ((i = 0; i < 45; i++)); do
    if [[ -n ${DISPLAY:-} ]] && python3 "$ISL_HOME/clickthrough.py" ready >/dev/null 2>&1; then
      if pgrep -x "gnome-shell|plasmashell|kwin_wayland|kwin_x11|Hyprland|sway|xfwm4|xfdesktop|muffin|marco|openbox|i3|bspwm|cosmic-comp|labwc|wayfire|river|niri" >/dev/null 2>&1 \
         || (( i >= 12 )); then
        break
      fi
    fi
    sleep 1
  done
  sleep 3
}

write_autostart() {
  mkdir -p "$(dirname "$ISL_AUTOSTART")"
  cat > "$ISL_AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=iShowLyrics
Comment=Synced lyrics desktop widget
Exec=$ISL_HOME/ishowlyrics start --autostart
StartupWMClass=iShowLyrics
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
EOF
}

sync_autostart() {
  rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/conky-lyrics.desktop"   # older name
  if [[ $AUTOSTART == 1 ]]; then write_autostart; else rm -f "$ISL_AUTOSTART"; fi
}

# Creates ~/.local/bin/ishowlyrics. Returns 1 if that folder is not on PATH.
install_cli_link() {
  mkdir -p "$(dirname "$ISL_BIN_LINK")"
  ln -sf "$ISL_HOME/ishowlyrics" "$ISL_BIN_LINK"
  case ":$PATH:" in *":$(dirname "$ISL_BIN_LINK"):"*) return 0 ;; esac
  return 1
}

add_to_path_rc() {
  local rc line='export PATH="$HOME/.local/bin:$PATH"  # added by iShowLyrics'
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f $rc ]] || continue
    grep -qF "# added by iShowLyrics" "$rc" || printf '\n%s\n' "$line" >> "$rc"
  done
}

# ----------------------------------------------- 8. manifest and uninstall ----

write_manifest() {
  ( cd "$ISL_HOME" && sha256sum "${ISL_CODE_FILES[@]}" > .manifest ) 2>/dev/null || true
}

do_uninstall() {
  step "Uninstalling iShowLyrics"
  isl_stop
  rm -f "$ISL_AUTOSTART" "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/conky-lyrics.desktop"
  if [[ -L $ISL_BIN_LINK ]]; then rm -f "$ISL_BIN_LINK"; fi
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f $rc ]]; then sed -i '/# added by iShowLyrics/d' "$rc"; fi
  done
  ok "Stopped the widget, removed autostart and the 'ishowlyrics' command"

  case "$ISL_HOME" in ""|"/"|"$HOME") die "Refusing to delete $ISL_HOME" ;; esac
  if [[ -d $ISL_HOME ]] && yesno "Delete $ISL_HOME (widget files, saved settings and backups)?" y; then
    rm -rf "$ISL_HOME"; ok "Removed $ISL_HOME"
  fi
  if [[ -d $ISL_CACHE ]] && yesno "Delete the lyrics cache ($ISL_CACHE)?" y; then rm -rf "$ISL_CACHE"; fi
  if [[ -d $ISL_FONT_DIR ]] && yesno "Remove fonts downloaded by iShowLyrics?" n; then
    rm -rf "$ISL_FONT_DIR"; fc-cache -f >/dev/null 2>&1 || true
  fi
  rm -rf "$ISL_RUN"
  say "Dependencies (conky, playerctl, ...) were left installed."
}
