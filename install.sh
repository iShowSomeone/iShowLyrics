#!/usr/bin/env bash
# =============================================================================
#  install.sh - installer for iShowLyrics (synced lyrics desktop widget)
#  Author: iShowSomeone    Version: 1.0.1
#
#  What it does:
#    1. checks (and optionally installs) dependencies and fonts
#    2. asks how the widget should look and where it should sit
#    3. installs everything into ~/iShowLyrics and adds the `ishowlyrics` command
#    4. optionally sets up autostart and starts the widget
#
#    ./install.sh               interactive install
#    ./install.sh --defaults    no questions, recommended settings
#    ./install.sh --uninstall   remove iShowLyrics
#
#  Your answers are saved to ~/iShowLyrics/settings.env and become the defaults
#  the next time you run this script or `ishowlyrics config`.
# =============================================================================
set -eo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SRC_DIR/lib.sh"

usage() {
  cat <<EOF
Usage: ./install.sh [options]
  -y, --defaults    ask nothing, use the saved / recommended settings
      --uninstall   stop the widget and remove iShowLyrics
  -h, --help        show this help
EOF
}

check_sources() {
  local f
  for f in "${ISL_ALL_FILES[@]}"; do
    [[ -f $SRC_DIR/$f ]] || die "Missing $f next to install.sh (expected in $SRC_DIR)"
  done
}

# A lyrics widget from another setup (for example an older Conky config in
# ~/.conkyrc) would draw on top of this one; offer to stop it.
stop_legacy() {
  local legacy
  legacy="$(pgrep -af "conky -c .*lyrics" 2>/dev/null | grep -v "$ISL_HOME" || true)"
  if [[ -n $legacy ]]; then
    warn "Another lyrics widget is running:"
    printf '    %s\n' "$legacy"
    if yesno "Stop it?" y; then
      pkill -f "conky -c .*lyrics" 2>/dev/null || true
      sleep 0.3
    fi
  fi
}

backup_existing() {
  local ts bdir f made=0
  ts="$(date +%Y%m%d-%H%M%S)"; bdir="$ISL_HOME/backup-$ts"
  for f in "${ISL_ALL_FILES[@]}" settings.env; do
    if [[ -f $ISL_HOME/$f ]]; then mkdir -p "$bdir"; cp -p "$ISL_HOME/$f" "$bdir/"; made=1; fi
  done
  if (( made )); then ok "Backed up the previous files to $bdir"; fi
}

do_install() {
  step "Installing"
  mkdir -p "$ISL_HOME"
  backup_existing

  if [[ "$(cd "$ISL_HOME" && pwd)" != "$SRC_DIR" ]]; then
    local f
    for f in "${ISL_ALL_FILES[@]}"; do cp "$SRC_DIR/$f" "$ISL_HOME/$f"; done
  else
    say "  (installing in place: the files in $ISL_HOME are edited directly)"
  fi
  chmod +x "$ISL_HOME/ishowlyrics" "$ISL_HOME/lyrics.py" "$ISL_HOME/verify.sh" "$ISL_HOME/doctor.sh" "$ISL_HOME/clickthrough.py"

  apply_settings
  save_settings
  write_manifest
  sync_autostart
  ok "Files installed in $ISL_HOME"
  if (( AUTOSTART == 1 )); then ok "Autostart entry created"; fi

  if install_cli_link; then
    ok "Command installed: ishowlyrics"
  else
    ok "Command installed: ~/.local/bin/ishowlyrics"
    warn "~/.local/bin is not on your PATH yet."
    if yesno "Add it to your shell startup file (~/.bashrc / ~/.zshrc)?" y; then
      add_to_path_rc
      say "  Open a new terminal (or run: source ~/.bashrc) to use the 'ishowlyrics' command."
    else
      say "  Until then run it with: $ISL_HOME/ishowlyrics"
    fi
  fi

  if yesno "Start the widget now?" y; then
    isl_start
    if isl_conky_running; then
      ok "Widget started"
    else
      warn "Conky did not start. Diagnose it with:  $ISL_HOME/ishowlyrics doctor"
    fi
  fi

  step "Done"
  cat <<EOF
  Play a song (GNOME Music, Spotify, a browser...) and the lyrics will fade in.

  ishowlyrics start | stop | restart | status
  ishowlyrics pin / unpin      keep the widget above other windows (off by default)
  ishowlyrics reset            widget invisible? clean restart on the base layer
  ishowlyrics config           change your settings
  ishowlyrics verify           check the installation
  ishowlyrics doctor           diagnose problems

  Files: $ISL_HOME   (lyrics.lua = look, lyrics.conf = window, lyrics.py = players)
  You can delete the folder you ran this installer from.
EOF
}

main() {
  local uninstall=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--defaults) ASSUME_DEFAULTS=1 ;;
      --uninstall)   uninstall=1 ;;
      -h|--help)     usage; exit 0 ;;
      *)             echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
  done
  init_tty

  if (( uninstall )); then do_uninstall; exit 0; fi

  printf '%siShowLyrics %s - installer%s\n' "$B" "$ISL_VERSION" "$N"
  if (( ! ASSUME_DEFAULTS )); then say "Press Enter to accept the answer shown in [brackets]."; fi
  check_sources
  ensure_deps
  check_session
  load_settings
  if [[ -f $ISL_SETTINGS ]]; then say "Existing installation found: your saved settings are used as the defaults."; fi

  run_wizard
  step "Summary"
  print_summary
  yesno "Install with these settings?" y || { say "Cancelled. Nothing was changed."; exit 0; }

  stop_legacy
  do_install
}

# Only run when executed directly (lets the functions be sourced for testing).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
