#!/usr/bin/env bash
# =============================================================================
#  verify.sh - check that the iShowLyrics installation is intact, then offer
#  Author: iShowSomeone    Version: 1.0.1
#              to change your settings.
#
#    ishowlyrics verify               full check, then asks if you want changes
#    ishowlyrics verify --check-only  only check (exit code 1 if something failed)
#    ishowlyrics config               skip the check, go straight to the questions
#
#  When you change settings, your new answers are written into the files AND
#  saved in settings.env, so they are the defaults from now on.
# =============================================================================
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ISL_HOME="$(dirname "$SELF")"
export ISL_HOME
# shellcheck source=lib.sh
source "$ISL_HOME/lib.sh" || { echo "verify.sh: cannot load $ISL_HOME/lib.sh" >&2; exit 1; }

DRIFT=0

usage() {
  cat <<EOF
Usage: ishowlyrics verify [--check-only]
       ishowlyrics config
EOF
}

# compare the value in a file with what settings.env says it should be
expect() {   # expect <label> <actual> <expected>
  local a="${2//[[:space:]]/}" e="${3//[[:space:]]/}"
  if [[ $a == "$e" ]]; then return 0; fi
  chk_warn "$1 is '$2' but your saved setting says '$3'"
  DRIFT=1
}

check_files() {
  step "Files"
  local f
  for f in "${ISL_ALL_FILES[@]}" settings.env; do
    if [[ ! -s $ISL_HOME/$f ]]; then
      chk_fail "$f is missing or empty"
      fix "re-run ./install.sh from the iShowLyrics download folder"
    else
      chk_ok "$f"
    fi
  done
  for f in ishowlyrics lyrics.py clickthrough.py verify.sh doctor.sh; do
    if [[ -f $ISL_HOME/$f && ! -x $ISL_HOME/$f ]]; then
      chmod +x "$ISL_HOME/$f" && chk_warn "$f was not executable (repaired)"
    fi
  done
}

check_integrity() {
  step "Integrity"
  local f
  if [[ -f $ISL_HOME/.manifest ]] && have sha256sum; then
    if ( cd "$ISL_HOME" && sha256sum -c .manifest --quiet >/dev/null 2>&1 ); then
      chk_ok "scripts match the installed checksums"
    else
      chk_warn "a script differs from the installed version (edited by hand or damaged)"
      ( cd "$ISL_HOME" && sha256sum -c .manifest 2>&1 | grep -v ': OK$' | sed 's/^/        /' ) || true
      fix "re-run ./install.sh from the download folder to restore the original files"
    fi
  else
    chk_warn "no checksum list found (.manifest)"
  fi

  for f in ishowlyrics lib.sh verify.sh doctor.sh; do
    [[ -f $ISL_HOME/$f ]] || continue
    if bash -n "$ISL_HOME/$f" 2>/dev/null; then chk_ok "$f: shell syntax"; else chk_fail "$f has a syntax error"; fi
  done
  for f in lyrics.py clickthrough.py; do
    [[ -f $ISL_HOME/$f ]] || continue
    if python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$ISL_HOME/$f" 2>/dev/null
    then chk_ok "$f: Python syntax"; else chk_fail "$f has a syntax error"; fi
  done
  if [[ -f $ISL_HOME/lyrics.lua ]]; then
    local luac=""
    for f in luac luac5.4 luac5.3 luac5.2 luac5.1; do have "$f" && { luac=$f; break; }; done
    if [[ -n $luac ]]; then
      if "$luac" -p "$ISL_HOME/lyrics.lua" 2>/dev/null; then chk_ok "lyrics.lua: Lua syntax"; else chk_fail "lyrics.lua has a syntax error"; fi
    else
      note "(Lua syntax not checked: no 'luac' installed)"
    fi
  fi
}

check_settings() {
  step "Settings in the files"
  local missing=0 n k
  DRIFT=0
  for n in FONT SIZES ALPHAS ALIGN LINE_GAP COLOR_SUNG COLOR_UNSUNG KARAOKE SHOW_META LOOKAHEAD SHADOW GLOW; do
    if [[ -z "$(read_lua "$n")" ]]; then chk_fail "lyrics.lua: setting $n not found"; missing=1; fi
  done
  for n in PREFER_PLAYERS IGNORE_PLAYERS; do
    if [[ -z "$(read_py "$n")" ]]; then chk_fail "lyrics.py: setting $n not found"; missing=1; fi
  done
  for k in update_interval minimum_size maximum_width alignment gap_x gap_y lua_load own_window_type own_window_hints; do
    if [[ -z "$(read_conf "$k")" ]]; then chk_fail "lyrics.conf: setting $k not found"; missing=1; fi
  done
  if (( missing )); then
    fix "re-run ./install.sh from the download folder (the files look damaged or from an older version)"
    return 0
  fi
  chk_ok "all settings present"

  # lua_load must point at this install
  local lp; lp="$(read_conf lua_load)"; lp="${lp/#\~/$HOME}"
  if [[ $lp == "$ISL_HOME/lyrics.lua" && -f $lp ]]; then chk_ok "lua_load points to $lp"
  else chk_fail "lua_load is '$lp' (expected $ISL_HOME/lyrics.lua)"; fix "ishowlyrics config   (rewrites it)"; DRIFT=1; fi

  # SIZES and ALPHAS must have the same number of entries
  local ns na
  ns="$(read_lua SIZES | tr -cd ',' | wc -c)"; na="$(read_lua ALPHAS | tr -cd ',' | wc -c)"
  if [[ $ns == "$na" ]]; then chk_ok "SIZES and ALPHAS have the same length"
  else chk_fail "SIZES has $((ns + 1)) entries but ALPHAS has $((na + 1))"; fix "edit lyrics.lua so both lists have the same number of entries"; fi

  # compare with what settings.env says
  load_settings
  derive_settings
  expect "Font"            "$(read_lua FONT)"         "\"$FONT\""
  expect "Sizes"           "$(read_lua SIZES)"        "$SIZES"
  expect "Line gap"        "$(read_lua LINE_GAP)"     "$LINE_GAP"
  expect "Text alignment"  "$(read_lua ALIGN)"        "\"$TEXT_ALIGN\""
  expect "Main colour"     "$(read_lua COLOR_SUNG)"   "\"$SUNG\""
  expect "Dim colour"      "$(read_lua COLOR_UNSUNG)" "\"$UNSUNG\""
  expect "Karaoke"         "$(read_lua KARAOKE)"      "$KARAOKE"
  expect "Song title row"  "$(read_lua SHOW_META)"    "$SHOW_META"
  expect "Timing offset"   "$(read_lua LOOKAHEAD)"    "$LOOKAHEAD"
  expect "Shadow"          "$(read_lua SHADOW)"       "$SHADOW"
  expect "Glow"            "$(read_lua GLOW)"         "$GLOW"
  expect "Preferred players" "$(read_py PREFER_PLAYERS)" "$PREFER_LIST"
  expect "Ignored players"   "$(read_py IGNORE_PLAYERS)" "$IGNORE_LIST"
  expect "Frame interval"  "$(read_conf update_interval)" "$INTERVAL"
  expect "Window size"     "$(read_conf minimum_size)" "$WIDTH $HEIGHT"
  expect "Position"        "$(read_conf alignment)"   "$WIN_ALIGN"
  expect "gap_x"           "$(read_conf gap_x)"       "$GAP_X"
  expect "gap_y"           "$(read_conf gap_y)"       "$GAP_Y"

  layer_params
  expect "Window type"    "$(read_conf own_window_type)"  "$LAYER_TYPE"
  expect "Window hints"   "$(read_conf own_window_hints)" "$LAYER_HINTS"
  if (( DRIFT == 0 )); then chk_ok "files match your saved settings"; fi
}

check_system() {
  step "Dependencies and fonts"
  local m
  for m in python3 playerctl perl fc-list; do
    if have "$m"; then chk_ok "$m"; else chk_fail "$m is missing"; fix "$(install_cmd "$(pkg_for "${m/fc-list/fontconfig}")")"; fi
  done
  if conky_has_cairo; then chk_ok "conky with Lua + Cairo"
  else chk_fail "conky is missing or built without Cairo"; fix "$(install_cmd "$(pkg_for conky)")"; fi

  load_settings
  refresh_fonts
  if has_font "$FONT"; then chk_ok "font '$FONT' is installed"
  else chk_fail "font '$FONT' is not installed"; fix "ishowlyrics config   (offers to install it)"; fi
}

check_integration() {
  step "Command, autostart and processes"
  load_settings
  if [[ -L $ISL_BIN_LINK && "$(readlink -f "$ISL_BIN_LINK")" == "$ISL_HOME/ishowlyrics" ]]; then
    chk_ok "'ishowlyrics' command is linked"
  else
    chk_warn "the 'ishowlyrics' command link is missing or points elsewhere"
    fix "ln -sf $ISL_HOME/ishowlyrics ~/.local/bin/ishowlyrics"
  fi
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) chk_warn "~/.local/bin is not on your PATH (open a new terminal after install)" ;; esac

  if [[ $AUTOSTART == 1 ]]; then
    if [[ -f $ISL_AUTOSTART ]] && grep -q "Exec=$ISL_HOME/ishowlyrics start" "$ISL_AUTOSTART"; then chk_ok "autostart entry is in place"
    else chk_warn "autostart is on in your settings but the entry is missing or wrong"; fix "ishowlyrics autostart on"; fi
  else
    if [[ -f $ISL_AUTOSTART ]]; then chk_warn "autostart entry exists but autostart is off in your settings"; fix "ishowlyrics autostart off"
    else chk_ok "autostart is off"; fi
  fi

  if isl_conky_running;  then chk_ok "widget (conky) is running"; else chk_warn "widget is not running"; fix "ishowlyrics start"; fi
  if isl_daemon_running; then chk_ok "helper (lyrics.py) is running"; else chk_warn "helper is not running"; fix "ishowlyrics start"; fi
  if isl_conky_running && [[ -n $PIN_MODE || $CLICK_THROUGH == true ]]; then
    case "$(python3 "$ISL_HOME/clickthrough.py" check 2>&1; echo "rc=$?")" in
      *"rc=0"*) chk_ok "widget window lets mouse clicks pass through" ;;
      *"rc=1"*) chk_warn "the widget window still catches mouse clicks"; fix "ishowlyrics restart" ;;
      *)        chk_warn "could not find the widget window to check click-through (still starting?)" ;;
    esac
  fi
  local sf="$ISL_RUN/state"
  if [[ -f $sf ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$sf") ))
    if (( age <= 3 )); then chk_ok "state file is up to date"; else chk_warn "state file is ${age}s old (helper stuck?)"; fix "ishowlyrics restart"; fi
  fi
}

summary() {
  step "Result"
  printf '  %s%d ok%s, %s%d warning(s)%s, %s%d problem(s)%s\n' "$G" "$CHK_OK" "$N" "$Y" "$CHK_WARN" "$N" "$R" "$CHK_FAIL" "$N"
  if (( CHK_FAIL > 0 )); then
    say "  Something is broken. Run 'ishowlyrics doctor' for a deeper diagnosis."
  elif (( CHK_WARN > 0 )); then
    say "  Mostly fine. See the warnings above."
  else
    say "  Everything looks good."
  fi
}

reconfigure() {
  load_settings
  say "Your current answers are shown in [brackets]. Press Enter to keep each one."
  say "Settings you edited by hand in the files will be replaced by your answers."
  run_wizard
  step "Summary"
  print_summary
  yesno "Save these settings and apply them?" y || { say "No changes were made."; return 0; }
  apply_settings
  save_settings
  sync_autostart
  ok "Settings applied and saved: they are your defaults from now on."
  if isl_conky_running; then
    if yesno "Restart the widget now to see the changes?" y; then isl_start; ok "Restarted"; fi
  else
    if yesno "The widget is not running. Start it now?" y; then isl_start; ok "Started"; fi
  fi
}

reapply_saved() {
  load_settings
  apply_settings
  sync_autostart
  ok "Your saved settings were written back into the files."
  if isl_conky_running && yesno "Restart the widget to apply them?" y; then isl_start; fi
}

main() {
  local mode=full a
  for a in "$@"; do
    case "$a" in
      --check-only) mode=check ;;
      --configure)  mode=config ;;
      -h|--help)    usage; exit 0 ;;
      *)            echo "Unknown option: $a" >&2; usage; exit 1 ;;
    esac
  done
  [[ -f $ISL_HOME/lyrics.conf ]] || die "iShowLyrics is not installed in $ISL_HOME"
  if [[ $mode != check ]]; then init_tty; fi

  printf '%siShowLyrics %s - verify%s\n' "$B" "$ISL_VERSION" "$N"
  if [[ $mode != config ]]; then
    check_files
    check_integrity
    check_settings
    check_system
    check_integration
    summary
    if [[ $mode == check ]]; then exit $(( CHK_FAIL > 0 ? 1 : 0 )); fi
    echo
    if yesno "Do you want to change your settings?" n; then
      reconfigure
    elif (( DRIFT )) && yesno "The files differ from your saved settings. Write the saved settings back?" y; then
      reapply_saved
    fi
  else
    reconfigure
  fi
}

main "$@"
