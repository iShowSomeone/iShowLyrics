#!/usr/bin/env bash
# =============================================================================
#  doctor.sh - find out why iShowLyrics doesn't work, and how to fix it
#  Author: iShowSomeone    Version: 1.0.1
#
#    ishowlyrics doctor            full diagnosis (includes a 4-second Conky test)
#    ishowlyrics doctor --quick    skip the Conky test and every question
#
#  It also checks the widget window (visible? on screen? click-through?), the desktop
#  you are running, and the frame rate.
#
#  Every finding is marked  ✓ fine,  ! worth a look,  ✗ problem  and problems
#  come with a "Fix:" line. The plain-text result is saved to doctor-report.txt
#  in the install folder: attach it when you report a bug.
# =============================================================================
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ISL_HOME="$(dirname "$SELF")"
export ISL_HOME
# shellcheck source=lib.sh
source "$ISL_HOME/lib.sh" || { echo "doctor.sh: cannot load $ISL_HOME/lib.sh" >&2; exit 1; }

REPORT="$ISL_HOME/doctor-report.txt"
QUICK=0
AUTOFIX=()        # safe fixes offered at the end

state_field() { cut -f"$1" "$ISL_RUN/state" 2>/dev/null | head -1; }

# ---------------------------------------------------------------- sections --

diag_system() {
  step "System"
  local os="unknown"
  if [[ -r /etc/os-release ]]; then os="$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"; fi
  say "  OS       : $os ($(uname -r))"
  say "  Session  : ${XDG_SESSION_TYPE:-unknown} / ${XDG_CURRENT_DESKTOP:-unknown}"
  have gnome-shell && say "  GNOME    : $(gnome-shell --version 2>/dev/null)"
  have conky       && say "  Conky    : $(conky -v 2>/dev/null | head -1)"
  say "  Python   : $(python3 --version 2>&1)"
  have playerctl   && say "  playerctl: $(playerctl --version 2>&1 | head -1)"

  if [[ -z ${DISPLAY:-} ]]; then
    chk_fail "DISPLAY is not set: Conky cannot open a window"
    fix "run this from a terminal inside your desktop session (or: export DISPLAY=:0)"
  else
    chk_ok "DISPLAY is $DISPLAY"
  fi
  if [[ ${XDG_SESSION_TYPE:-} == wayland ]]; then
    if have Xwayland; then chk_ok "Wayland session with XWayland available (Conky runs through it)"
    else chk_fail "Wayland session but XWayland was not found"; fix "$(install_cmd xorg-x11-server-Xwayland)   (package name varies by distro)"; fi
  fi
  if [[ -z ${XDG_RUNTIME_DIR:-} ]]; then
    chk_warn "XDG_RUNTIME_DIR is not set; /tmp is used for the state file"
  fi
}

diag_env() {
  step "Desktop and window layer"
  load_settings
  env_tips
  if [[ $ENV_SESSION == wayland && $ENV_FAMILY != gnome && $ENV_FAMILY != kde ]]; then
    chk_warn "this Wayland desktop is untested or not recommended (see the tips above): Conky works through XWayland here"
    note "If the widget is invisible or tiled, see the tips above and try: ishowlyrics reset override"
  fi
}

diag_deps() {
  step "Dependencies"
  local m
  for m in python3 playerctl perl fc-list; do
    if have "$m"; then chk_ok "$m found"
    else chk_fail "$m is missing"; fix "$(install_cmd "$(pkg_for "${m/fc-list/fontconfig}")")"; fi
  done
  if ! have conky; then
    chk_fail "conky is missing"; fix "$(install_cmd "$(pkg_for conky)")"
  elif conky_has_cairo; then
    chk_ok "conky has Lua + Cairo support"
  else
    chk_fail "conky was built without Cairo (the animated lyrics need it)"
    fix "$(install_cmd "$(pkg_for conky)")   (on Debian/Ubuntu the package is 'conky-all')"
  fi
  if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then chk_ok "Python is 3.8 or newer"
  else chk_fail "Python 3.8 or newer is required"; fi
}

diag_install() {
  step "Installation"
  local f
  for f in "${ISL_ALL_FILES[@]}"; do
    if [[ ! -s $ISL_HOME/$f ]]; then chk_fail "$f is missing"; fix "re-run ./install.sh from the download folder"; fi
  done
  local lp; lp="$(read_conf lua_load)"; lp="${lp/#\~/$HOME}"
  if [[ -f $lp ]]; then chk_ok "lua_load path exists ($lp)"
  else chk_fail "lua_load points to '$lp', which does not exist"; fix "ishowlyrics config   (rewrites the path)  or re-run ./install.sh"; fi
  if [[ -f $ISL_SETTINGS ]]; then chk_ok "settings.env present"; else chk_warn "settings.env missing (your answers are not saved)"; fix "ishowlyrics config"; fi

  local ns na
  ns="$(read_lua SIZES | tr -cd ',' | wc -c)"; na="$(read_lua ALPHAS | tr -cd ',' | wc -c)"
  if [[ $ns != "$na" ]]; then chk_fail "SIZES and ALPHAS in lyrics.lua have different lengths"; fix "edit lyrics.lua so both lists have the same number of entries"; fi
  [[ -x $ISL_HOME/lyrics.py ]] || { chmod +x "$ISL_HOME/lyrics.py" 2>/dev/null; }

  if [[ -L $ISL_BIN_LINK ]]; then chk_ok "'ishowlyrics' command is linked"
  else chk_warn "no 'ishowlyrics' command link"; fix "ln -sf $ISL_HOME/ishowlyrics ~/.local/bin/ishowlyrics"; fi
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) chk_warn "~/.local/bin is not on PATH"; fix "open a new terminal, or: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;; esac

  load_settings
  if [[ $AUTOSTART == 1 && ! -f $ISL_AUTOSTART ]]; then chk_warn "autostart is on in your settings but the entry is missing"; fix "ishowlyrics autostart on"; fi
}

diag_font() {
  step "Font"
  load_settings
  local cur; cur="$(read_lua FONT)"; cur="${cur//\"/}"
  refresh_fonts
  if has_font "$cur"; then chk_ok "font '$cur' is installed"
  else
    chk_fail "font '$cur' is not installed: Cairo will use a default font instead"
    fix "ishowlyrics config   (the font step can install Impact, Anton, Bebas Neue, Archivo Black or DejaVu Sans)"
  fi
}

# Starts Conky for a few seconds and reads its error messages.
diag_conky_test() {
  step "Conky start test"
  if (( QUICK )); then note "(skipped in --quick mode)"; return 0; fi
  have conky && [[ -f $ISL_HOME/lyrics.conf ]] || { note "(skipped: conky or lyrics.conf missing)"; return 0; }
  say "  A second copy of the widget will flash on screen for about 4 seconds."
  yesno "Run the test?" y || { note "(skipped)"; return 0; }

  local before=$CHK_FAIL
  local out; out="$(timeout 4 conky -c "$ISL_HOME/lyrics.conf" 2>&1 || true)"
  # drop Conky's routine messages (case-sensitive "FOUND:" so real "not found" errors stay)
  local errs; errs="$(grep -v 'FOUND: ' <<<"$out" \
    | grep -viE "old syntax|Syntax error|window type|desktop window|drawing to|terminate|received SIG|wayland session" || true)"

  if grep -qiE "specified script file .* doesn't exist" <<<"$out"; then
    chk_fail "Conky cannot find lyrics.lua (wrong lua_load path)"
    fix "ishowlyrics config   or re-run ./install.sh"
  fi
  if grep -qiE "can't open display|cannot open display|unable to open display" <<<"$out"; then
    chk_fail "Conky cannot open the display"
    fix "run from a terminal inside your desktop session; on Wayland make sure XWayland is installed"
  fi
  if grep -qiE "module 'cairo' not found|module 'cairo_xlib' not found|cairo.*not found" <<<"$out"; then
    chk_fail "Conky has no Cairo Lua bindings"
    fix "$(install_cmd "$(pkg_for conky)")"
  fi
  if grep -qiE "attempt to (index|call|compare|perform)|\[string|lyrics\.lua:[0-9]+" <<<"$out"; then
    chk_fail "lyrics.lua raised an error:"
    grep -iE "attempt to|lyrics\.lua|\[string" <<<"$out" | head -4 | sed 's/^/        /'
    fix "ishowlyrics verify   (checks the file); if you edited lyrics.lua, undo your change or re-run ./install.sh"
  fi
  if (( CHK_FAIL == before )); then       # none of the specific checks above fired
    if [[ -z $errs ]]; then
      chk_ok "Conky started without errors"
    else
      chk_warn "Conky printed messages:"
      printf '%s\n' "$errs" | head -6 | sed 's/^/        /'
    fi
  fi
}

diag_players() {
  step "Music players"
  if ! have playerctl; then note "(playerctl missing)"; return 0; fi
  local players; players="$(playerctl -l 2>/dev/null || true)"
  if [[ -z $players ]]; then
    chk_fail "No media player is visible to playerctl (no MPRIS player running)"
    fix "start a music player and press play (GNOME Music, Spotify, VLC, a browser tab with music, ...)"
    note "Browsers: Brave/Chrome need 'Hardware media key handling' enabled in chrome://flags"
    note "           Firefox needs media.hardwaremediakeys.enabled = true in about:config"
    note "mpv needs the mpv-mpris plugin; VLC: Tools > Preferences > enable the MPRIS2 interface"
    return 0
  fi
  chk_ok "players found: $(tr '\n' ' ' <<<"$players")"

  local p line status artist title playing=0 usable=0
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    line="$(playerctl -p "$p" metadata --format $'{{status}}\t{{artist}}\t{{title}}' 2>/dev/null || true)"
    status="$(cut -f1 <<<"$line")"; artist="$(cut -f2 <<<"$line")"; title="$(cut -f3 <<<"$line")"
    if [[ $status == Playing ]]; then playing=1; fi
    if [[ -z $artist || -z $title ]]; then
      note "$p: $status, no artist/title (probably a web video; ignored by iShowLyrics)"
    else
      note "$p: $status - $title | $artist"
      usable=1
    fi
  done <<<"$players"

  if (( ! usable )); then
    chk_warn "no player reports both an artist and a title"
    fix "play a song from a music app, or a track whose page sets proper media metadata"
  elif (( ! playing )); then
    chk_warn "nothing is playing right now (a paused song still keeps its lyrics on screen)"
    fix "press play"
  else
    chk_ok "a song is playing"
  fi
  if grep -qiE "firefox|chrom|brave|vivaldi|opera|edge" <<<"$players"; then
    note "Browsers report the song position less accurately than music apps (coarse or slow). iShowLyrics smooths"
    note "this. To see how YOUR browser behaves, play a video and run: ishowlyrics probe"
  fi
  local ig; ig="$(read_py IGNORE_PLAYERS)"
  if [[ -n $ig && $ig != "[]" ]]; then chk_warn "IGNORE_PLAYERS is $ig - make sure that is not hiding your player"; fix "ishowlyrics config"; fi
}

diag_helper() {
  step "Helper and state file"
  local n; n="$(pgrep -fc "lyrics.py --daemon" 2>/dev/null || true)"
  n="${n:-0}"
  if (( n == 0 )); then
    chk_fail "the helper (lyrics.py --daemon) is not running: no lyrics can appear"
    fix "ishowlyrics start"
    AUTOFIX+=(restart)
  elif (( n > 1 )); then
    chk_warn "$n helper processes are running (should be 1)"
    fix "ishowlyrics restart"
    AUTOFIX+=(restart)
  else
    chk_ok "helper is running"
  fi

  local sf="$ISL_RUN/state"
  if [[ ! -f $sf ]]; then
    chk_fail "no state file ($sf)"; fix "ishowlyrics restart"; return 0
  fi
  local age=$(( $(date +%s) - $(stat -c %Y "$sf") ))
  if (( age > 3 )); then chk_fail "state file is ${age}s old: the helper is stuck or stopped"; fix "ishowlyrics restart"; AUTOFIX+=(restart)
  else chk_ok "state file is fresh"; fi
  say "  State    : $(state_field 1) | position $(state_field 2) | $(state_field 5) | $(state_field 6)"
}

diag_lyrics() {
  step "Lyrics"
  say "  Checking LRCLIB (the lyrics source)..."
  local net
  net="$(python3 - <<'PY' 2>/dev/null
import urllib.request, urllib.error, socket
try:
    r = urllib.request.urlopen(urllib.request.Request("https://lrclib.net/api/search?q=test",
        headers={"User-Agent": "iShowLyrics-doctor"}), timeout=8)
    print("ok", r.status)
except urllib.error.HTTPError as e:
    print("http", e.code)
except socket.timeout:
    print("timeout")
except Exception as e:
    print("error", getattr(e, "reason", e))
PY
)"
  case "$net" in
    ok*)      chk_ok "lrclib.net is reachable" ;;
    http*)    chk_warn "lrclib.net answered with an error ($net): it may be down or rate-limiting you"; fix "try again in a few minutes" ;;
    timeout*) chk_fail "lrclib.net timed out"; fix "check your internet connection, firewall or proxy settings" ;;
    *)        chk_fail "cannot reach lrclib.net (${net:-no answer})"; fix "check your internet connection and DNS (try: ping lrclib.net)" ;;
  esac

  local path title artist
  path="$(state_field 4)"; title="$(state_field 5)"; artist="$(state_field 6)"
  if [[ -z $title ]]; then note "(no song detected, so no per-song lyrics check)"; return 0; fi

  if [[ -n $path && -f $path ]]; then
    local n; n="$(grep -cE '^\[[0-9]+:[0-9]+' "$path" 2>/dev/null || true)"
    if (( ${n:-0} > 0 )); then chk_ok "synced lyrics loaded for '$title' ($n lines)"
    else chk_fail "the cached file for '$title' has no timestamps (plain lyrics only)"; fix "delete it: rm '$path'  and let iShowLyrics look it up again"; fi
    return 0
  fi

  # No lyrics yet: find out why
  local pend lrc
  for lrc in "$ISL_CACHE"/*.pending; do
    [[ -e $lrc ]] || continue
    if (( $(date +%s) - $(stat -c %Y "$lrc") > 60 )); then
      chk_warn "a lyrics lookup has been stuck for over a minute ($(basename "$lrc"))"
      AUTOFIX+=(clear_pending); break
    fi
  done
  say "  Looking up '$title' by '$artist' on LRCLIB..."
  local res
  res="$(ISL_HOME="$ISL_HOME" python3 - <<'PY' 2>&1
import os, sys
sys.path.insert(0, os.environ["ISL_HOME"])
import lyrics
i = lyrics.pick(lyrics.pc("-l").splitlines())
if not i:
    print("noplayer"); sys.exit()
try:
    text = lyrics.find_lyrics(i["artist"], i["title"], i["album"], i["dur"])
    print("found" if text else "none")
except Exception as e:
    print("error", e)
PY
)"
  case "$res" in
    found*)   chk_warn "LRCLIB has lyrics for this song but they are not loaded yet"
              fix "wait a few seconds; if it stays like this: ishowlyrics restart"
              AUTOFIX+=(clear_empty) ;;
    none*)    chk_warn "LRCLIB has no synced lyrics for '$title' by '$artist'"
              note "Not every song has synced lyrics. If the title looks wrong (e.g. a YouTube video title),"
              note "play it from a music app, or fix the song's tags."
              AUTOFIX+=(clear_empty) ;;
    error*)   chk_fail "lookup failed: ${res#error }"; fix "check your internet connection; then: ishowlyrics restart" ;;
    noplayer*) note "(no usable player right now)" ;;
    *)        chk_warn "lookup returned: $res" ;;
  esac
}

diag_window() {
  step "Widget window"
  local n; n="$(pgrep -fc "conky -c $ISL_HOME/lyrics.conf" 2>/dev/null || true)"; n="${n:-0}"
  if (( n == 0 )); then chk_fail "the widget (conky) is not running"; fix "ishowlyrics start"; AUTOFIX+=(restart)
  elif (( n > 1 )); then chk_warn "$n copies of the widget are running (text will look doubled)"; fix "ishowlyrics restart"; AUTOFIX+=(restart)
  else chk_ok "widget is running"; fi

  local old; old="$(pgrep -af "conky -c .*lyrics" 2>/dev/null | grep -v "$ISL_HOME" | grep -v doctor || true)"
  if [[ -n $old ]]; then
    chk_warn "another lyrics widget is running and may be drawing over this one:"
    printf '        %s\n' "$old"
    fix "pkill -f 'conky -c .*lyrics'; then: ishowlyrics start"
  fi

  if (( n >= 1 )); then
    local pid cpu
    pid="$(pgrep -f "conky -c $ISL_HOME/lyrics.conf" | head -1)"
    cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ -n $cpu ]]; then
      if (( ${cpu%.*} >= 25 )); then chk_warn "the widget uses ${cpu}% CPU"; fix "ishowlyrics config   (choose 40 or 30 fps)"
      else chk_ok "CPU use is ${cpu}%"; fi
    fi
  fi

  load_settings
  layer_params
  local hints type; hints="$(read_conf own_window_hints)"; type="$(read_conf own_window_type)"
  if [[ $type == "$LAYER_TYPE" && $hints == "$LAYER_HINTS" ]]; then
    if [[ -n $PIN_MODE ]]; then chk_ok "pinned on top (type $type, mode $PIN_MODE)"
    else chk_ok "base layer: $(resolve_layer) (type $type)"; fi
  else
    chk_warn "lyrics.conf has window type '$type' / hints '$hints' but your settings expect '$LAYER_TYPE' / '$LAYER_HINTS'"
    fix "ishowlyrics config   (rewrites them)   or   ishowlyrics reset"
  fi
  if [[ -n $PIN_MODE ]]; then note "If it does not stay on top: ishowlyrics pin override.   To put it back: ishowlyrics unpin"; fi

  # is the window really there, on screen, and does it let clicks through?
  if (( n >= 1 )); then
    if have xwininfo; then
      local wid info mapstate ax ay ww wh sw sh
      wid="$(xwininfo -root -tree 2>/dev/null | awk '/"iShowLyrics"/ {print $1; exit}')"
      if [[ -z $wid ]]; then
        chk_fail "Conky is running but its window is not on the display (it may be on another display or failed to map)"
        fix "ishowlyrics reset"
      else
        info="$(xwininfo -id "$wid" 2>/dev/null)"
        mapstate="$(awk -F': ' '/Map State/ {print $2}' <<<"$info")"
        ax="$(awk '/Absolute upper-left X/ {print $4}' <<<"$info")"; ay="$(awk '/Absolute upper-left Y/ {print $4}' <<<"$info")"
        ww="$(awk '/Width:/ {print $2}' <<<"$info")"; wh="$(awk '/Height:/ {print $2}' <<<"$info")"
        read -r sw sh < <(xwininfo -root 2>/dev/null | awk '/Width:/ {w=$2} /Height:/ {h=$2} END {print w, h}')
        if [[ $mapstate == IsViewable ]]; then chk_ok "window $wid is mapped (visible to the display server), ${ww}x${wh} at +$ax+$ay"
        else chk_fail "window $wid is not viewable (state: ${mapstate:-unknown})"; fix "ishowlyrics reset"; fi
        if [[ -n $sw && $ax =~ ^-?[0-9]+$ && $ay =~ ^-?[0-9]+$ ]]; then
          if (( ax + ww <= 0 || ay + wh <= 0 || ax >= sw || ay >= sh )); then
            chk_fail "the window is completely outside the screen (${sw}x${sh})"; fix "ishowlyrics config   (change position and gaps)   or   ishowlyrics reset"
          elif (( ax < 0 || ay < 0 || ax + ww > sw || ay + wh > sh )); then
            chk_warn "part of the window is outside the screen (${sw}x${sh}); text near the edge may be cut off"; fix "ishowlyrics config   (smaller width or different gaps)"
          fi
        fi
        if have xprop; then
          local st; st="$(xprop -id "$wid" _NET_WM_STATE 2>/dev/null | sed 's/.*= *//')"
          note "window manager state: ${st:-none reported}"
        fi
      fi
    else
      note "(install x11-utils / xorg-xwininfo for window position checks)"
    fi
    if [[ -n $PIN_MODE || $CLICK_THROUGH == true ]]; then
      case "$(python3 "$ISL_HOME/clickthrough.py" check 2>&1; echo "rc=$?")" in
        *"rc=0"*) chk_ok "the widget window lets mouse clicks pass through" ;;
        *"rc=1"*) chk_fail "the widget window catches mouse clicks (what is underneath is unusable)"
                  fix "ishowlyrics restart   (re-applies click-through)"
                  note "Under Wayland the widget is an XWayland window; if this persists, report which desktop you use when you file an issue." ;;
        *)        chk_warn "could not check click-through (window not found)" ;;
      esac
    fi
    note "Widget invisible although everything above is fine? Run: ishowlyrics reset   (then reset below / reset override)"
  fi

  # does the window fit on the screen?
  local geo=""
  if have xdpyinfo; then geo="$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')"; fi
  if [[ $geo =~ ^([0-9]+)x([0-9]+)$ ]]; then
    local sw=${BASH_REMATCH[1]} ww gx
    ww="$(read_conf maximum_width)"; gx="$(read_conf gap_x)"
    if [[ $ww =~ ^[0-9]+$ && $gx =~ ^-?[0-9]+$ ]] && (( ww + gx > sw )); then
      chk_warn "widget width ($ww) + gap_x ($gx) is wider than the screen ($sw px)"; fix "ishowlyrics config"
    fi
  fi
}

# -------------------------------------------------------------- safe fixes --

apply_fixes() {
  local f seen=" "
  for f in "${AUTOFIX[@]}"; do
    [[ $seen == *" $f "* ]] && continue
    seen+="$f "
    case "$f" in
      restart)       isl_start; ok "Restarted the widget and the helper" ;;
      clear_pending) rm -f "$ISL_CACHE"/*.pending; ok "Removed stuck lookup markers" ;;
      clear_empty)   find "$ISL_CACHE" -name '*.lrc' -size 0 -delete 2>/dev/null; rm -f "$ISL_CACHE"/*.pending
                     ok "Cleared 'no lyrics' entries so every song is looked up again" ;;
    esac
  done
}

diag_perf() {
  step "Frame rate"
  local pf="$ISL_RUN/perf"
  if [[ ! -f $pf ]] || (( $(date +%s) - $(stat -c %Y "$pf") > 6 )); then
    note "(no recent frame timing: the widget is not running or has nothing to draw yet)"; return 0
  fi
  local frames late maxms target
  frames="$(cut -f1 "$pf")"; late="$(cut -f2 "$pf")"; maxms="$(cut -f3 "$pf")"; target="$(cut -f4 "$pf")"
  [[ $frames =~ ^[0-9]+$ && $late =~ ^[0-9]+$ && $frames -gt 0 ]] || return 0
  local fps=$(( frames / 2 )) pct=$(( late * 100 / frames ))
  note "last 2 s: $frames frames (~$fps fps, target interval ${target} ms), $late late, slowest ${maxms} ms"
  if (( pct >= 10 )); then
    chk_warn "$pct% of the frames were late: the widget is being starved of CPU (this is what stutter looks like)"
    note "Typical when a video (e.g. Firefox with YouTube) is decoding, or the machine is busy."
    fix "ishowlyrics config   -> choose 40 or 30 fps; Conky itself is single-threaded"
    fix "if only Firefox does this: check hardware video decoding is on (about:support) so the CPU stays free"
  else
    chk_ok "frames are on time ($pct% late)"
    note "If it still looks glitchy only in the browser, the cause is the player's timing data: run 'ishowlyrics probe'"
  fi
}

diagnose() {
  printf '%siShowLyrics %s - doctor%s   (%s)\n' "$B" "$ISL_VERSION" "$N" "$(date '+%F %T')"
  diag_system
  diag_env
  diag_deps
  diag_install
  diag_font
  diag_conky_test
  diag_players
  diag_helper
  diag_lyrics
  diag_window
  diag_perf

  step "Result"
  printf '  %s%d ok%s, %s%d warning(s)%s, %s%d problem(s)%s\n' "$G" "$CHK_OK" "$N" "$Y" "$CHK_WARN" "$N" "$R" "$CHK_FAIL" "$N"
  if (( CHK_FAIL + CHK_WARN == 0 )); then
    say "  Everything looks healthy. If the widget is still not visible, check the position"
    say "  and gap settings (ishowlyrics config) and that a song with synced lyrics is playing."
  else
    say "  Follow the 'Fix:' lines above, top to bottom: earlier problems often cause later ones."
  fi
  if (( ${#AUTOFIX[@]} > 0 && ! QUICK )); then
    echo
    if yesno "Apply the safe automatic fixes now (restart widget, clear stuck lookups)?" y; then apply_fixes; fi
  fi
}

main() {
  local a
  for a in "$@"; do
    case "$a" in
      --quick)   QUICK=1 ;;
      -h|--help) sed -n '2,12p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *)         echo "Unknown option: $a" >&2; exit 1 ;;
    esac
  done
  [[ -f $ISL_HOME/lyrics.conf ]] || die "iShowLyrics is not installed in $ISL_HOME"
  if (( QUICK )); then ASSUME_DEFAULTS=1; else init_tty; fi

  local tmp; tmp="$(mktemp)"
  diagnose 2>&1 | tee "$tmp"
  sed 's/\x1b\[[0-9;]*m//g' "$tmp" > "$REPORT"
  rm -f "$tmp"
  echo
  say "Plain-text report saved to: $REPORT"
}

main "$@"
