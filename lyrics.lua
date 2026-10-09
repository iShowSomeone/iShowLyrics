--[[
  lyrics.lua - draws the animated lyrics inside Conky (cairo).
  Author: iShowSomeone    Version: 1.0.1

  Reads the state file written by `lyrics.py --daemon`, keeps its own smooth
  clock, and draws a scrolling block of lyric lines with the song title and
  artist underneath.

  Most settings below can also be changed with `ishowlyrics config`, which
  rewrites the lines marked (wizard). Edit the file by hand for the rest, then
  run `ishowlyrics restart`.
]]

require 'cairo'
pcall(require, 'cairo_xlib')

-- ===========================================================================
--  SETTINGS
-- ===========================================================================

-- ---- Font (wizard) ---------------------------------------------------------
-- Any installed font family. Check with:  fc-list : family | sort -u
-- Note: this drawing method has no per-character fallback, so use a font with
-- wide coverage if you listen to songs in non-Latin scripts.
local FONT = "Impact"

-- ---- Size and fade by distance from the current line ----------------------
-- Entry 1 = current line, entry 2 = one line away, entry 3 = two away, ...
-- The number of entries decides how many lines are visible on each side.
-- SIZES and ALPHAS must have the same number of entries.
-- ALPHAS: 1 = fully opaque, 0 = invisible.
local SIZES  = {30, 20, 15, 12, 10}                -- (wizard)
local ALPHAS = {1.00, 0.62, 0.36, 0.16, 0.00}

-- ---- Layout ---------------------------------------------------------------
local ALIGN    = "right"   -- "right", "left" or "center"            (wizard)
local LINE_GAP = 35        -- pixels between line centres              (wizard)
local PAD_LEFT  = 14       -- inner margins inside the Conky window
local PAD_RIGHT = 14
local OFFSET_Y  = 0        -- shift the whole block: negative = up, positive = down

-- ---- Colours (hex, no #) --------------------------------------------------
local COLOR_SUNG   = "FF1A1A"  -- main colour / part of a line already sung (wizard)
local COLOR_UNSUNG = "991212"  -- dim: part of a line still to come         (wizard)

-- ---- Karaoke sweep --------------------------------------------------------
-- true  = the current line fills with COLOR_SUNG while it is sung, upcoming
--         lines are drawn in COLOR_UNSUNG.
-- false = every line uses COLOR_SUNG.                                  (wizard)
local KARAOKE = false
-- How the sweep is timed. A synced .lrc file only knows when a line STARTS, so
-- the sweep length is estimated:
--   SWEEP_FILL        share of the time until the next line used for the sweep
--                     (0.85 = it finishes just before the next line begins)
--   SECONDS_PER_CHAR  caps the sweep for lines followed by a long pause
local SWEEP_FILL       = 0.85
local SECONDS_PER_CHAR = 0.075
local SWEEP_SOFTNESS   = 0.06   -- width of the soft edge, as a share of the line

-- ---- Song title row -------------------------------------------------------
local SHOW_META      = true               -- show "title | artist" below the lyrics (wizard)
local META_SEPARATOR = " | "
local META_SIZE      = SIZES[#SIZES - 1]  -- same size as the second-to-last line
local META_ALPHA     = 0.70
local META_GAP       = 34                 -- pixels below the last visible lyric line
local META_COLOR     = COLOR_UNSUNG

-- ---- Effects --------------------------------------------------------------
local SHADOW        = true  -- dark shadow behind text for readability   (wizard)
local SHADOW_OFFSET = 1.5
local SHADOW_ALPHA  = 0.7

local GLOW        = true    -- soft glow around the current line         (wizard)
local GLOW_ALPHA  = 0.22
local GLOW_WIDTH  = 4

-- Shown for instrumental gaps (empty lyric lines). Use a symbol your FONT has;
-- Impact has no music note, so a plain dot sequence is the safe default.
local INSTRUMENTAL_MARK = "• • •"

-- ---- Timing / animation ---------------------------------------------------
-- Lines change this many seconds EARLIER than the timestamp. Raise it if lines
-- feel late, lower it (or go negative) if they feel early.        (wizard)
local LOOKAHEAD = 0.20

local SCROLL_SPEED = 9   -- how fast lines slide up (higher = snappier)
local FADE_SPEED   = 4   -- how fast the widget fades in/out when music starts/stops

-- ---- Advanced -------------------------------------------------------------
local STATE_FILE = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/ishowlyrics/state"
-- Every 2 seconds the frame timing is written here: `ishowlyrics doctor` reads it to
-- tell "bad data from the player" apart from "the widget is starved of CPU".
local PERF_FILE  = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/ishowlyrics/perf"

-- ===========================================================================
--  END OF SETTINGS - code below normally doesn't need editing
-- ===========================================================================

local function hex(h)
  h = h:gsub("#", "")
  return {tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255}
end
local SUNG, UNSUNG, METACOL = hex(COLOR_SUNG), hex(COLOR_UNSUNG), hex(META_COLOR)

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local SIDE = #SIZES - 1                       -- lines per side that have a size
local VIS = 0                                 -- lines per side that are actually visible
for i = 1, #ALPHAS do if ALPHAS[i] > 0 then VIS = i - 1 end end

local ext = cairo_text_extents_t:create()
tolua.takeownership(ext)

-- state read from the daemon
local lines, lrc_path = {}, ""                -- parsed lyrics: { {seconds, text}, ... }
local title, artist, track_key = "", "", ""
local status, base_pos, base_stamp = "Stopped", 0, 0
local off, last_sample, prev_status = nil, nil, ""   -- smoothed (media time - uptime)
local last_read, snap = -1, true
-- animation state
local s_anim, g_alpha, g_meta = 0, 0, 0       -- scroll position / lyrics fade / title fade
local tm, last_raw, dt_f = nil, nil, 0.016    -- smoothed clock
local kp_idx, kp_val = -1, 0                  -- karaoke progress of the current line
local perf_t, perf_frames, perf_late, perf_max = nil, 0, 0, 0

local function now()                          -- uptime: same clock lyrics.py stamps with
  local f = io.open("/proc/uptime", "r")
  if not f then return 0 end
  local v = f:read("*n")
  f:close()
  return v or 0
end

-- frames / late frames / slowest frame, written every 2 seconds
local function perf_tick(raw, dt_raw)
  perf_frames = perf_frames + 1
  local target = (conky_info and conky_info.update_interval) or 0.016
  if dt_raw > target * 2.5 + 0.01 then perf_late = perf_late + 1 end
  if dt_raw > perf_max then perf_max = dt_raw end
  if not perf_t then perf_t = raw; return end
  if raw - perf_t >= 2 then
    local f = io.open(PERF_FILE, "w")
    if f then
      f:write(string.format("%d\t%d\t%.0f\t%.1f\n", perf_frames, perf_late, perf_max * 1000, target * 1000))
      f:close()
    end
    perf_t, perf_frames, perf_late, perf_max = raw, 0, 0, 0
  end
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Parse an .lrc file: lines like "[01:23.45] some words"
local function load_lrc(path)
  local t = {}
  local f = io.open(path, "r")
  if not f then return t end
  for line in f:lines() do
    local m, s, txt = line:match("^%[(%d+):(%d+%.?%d*)%](.*)$")
    if m then t[#t + 1] = {tonumber(m) * 60 + tonumber(s), trim(txt)} end
  end
  f:close()
  return t
end

-- Read the state file (at most 5x per second)
local function read_state(t)
  if t - last_read < 0.2 then return end
  last_read = t
  local f = io.open(STATE_FILE, "r")
  if not f then status = "Stopped"; return end
  local l = f:read("*l")
  f:close()
  if not l then return end
  local st, pos, stamp, path, ttl, art =
    l:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?([^\t]*)")
  if not st then return end

  status = st
  base_pos = tonumber(pos) or 0
  local stamp_n = tonumber(stamp) or t
  base_stamp = stamp_n
  title, artist = ttl or "", art or ""

  local key = title .. "\1" .. artist
  local new_track = (key ~= track_key)
  track_key = key

  if path ~= lrc_path then                    -- new song: load its lyrics
    lrc_path = path
    lines = (path ~= "") and load_lrc(path) or {}
    snap = true
  end

  -- Playback clock. Each new sample says "at uptime X the song was at Y".
  -- lyrics.py has already filtered out the noise of slow or coarse players, so
  -- the samples are smooth; we still only nudge the offset. Big differences
  -- (seeks, new song, resume) snap immediately.
  if stamp_n ~= last_sample then
    last_sample = stamp_n
    if status == "Playing" then
      local o = base_pos - stamp_n
      if off == nil or new_track or prev_status ~= "Playing" or math.abs(o - off) > 0.5 then
        off = o
      else
        off = off + (o - off) * 0.5
      end
    end
    prev_status = status
  end
end

-- Index of the last lyric line whose timestamp <= pos (0 = before the first line)
local function find_idx(pos)
  local lo, hi, ans = 1, #lines, 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if lines[mid][1] <= pos then ans = mid; lo = mid + 1 else hi = mid - 1 end
  end
  return ans
end

-- Smoothly look up a value in SIZES/ALPHAS for a fractional distance a (in lines)
local function curve(tbl, a)
  local n = #tbl
  if a >= n - 1 then return tbl[n] end
  local i = math.floor(a)
  return tbl[i + 1] + (tbl[i + 2] - tbl[i + 1]) * (a - i)
end

-- Where the sweep should be (0..1) for line i at playback position pos.
local function sweep_target(i, pos)
  local l, nxt = lines[i], lines[i + 1]
  local gap = nxt and (nxt[1] - l[1]) or 6
  local cap = math.max(0.8, #l[2] * SECONDS_PER_CHAR * 1.6)
  local dur = math.max(0.3, math.min(gap * SWEEP_FILL, cap))
  return clamp((pos - l[1]) / dur, 0, 1)
end

-- Colour for a stretch of text: solid, or a gradient with a soft moving edge.
local function set_fill(cr, x, adv, alpha, p)
  if p <= 0.001 then
    cairo_set_source_rgba(cr, UNSUNG[1], UNSUNG[2], UNSUNG[3], alpha)
  elseif p >= 0.999 then
    cairo_set_source_rgba(cr, SUNG[1], SUNG[2], SUNG[3], alpha)
  else
    -- The edge travels from just left of the text (p = 0) to just right of it
    -- (p = 1), so it never jumps at the start or the end.
    local edge = p * (1 + 2 * SWEEP_SOFTNESS) - SWEEP_SOFTNESS
    local a = clamp(edge - SWEEP_SOFTNESS, 0, 1)
    local b = clamp(edge + SWEEP_SOFTNESS, 0, 1)
    local pat = cairo_pattern_create_linear(x, 0, x + adv, 0)
    cairo_pattern_add_color_stop_rgba(pat, 0, SUNG[1], SUNG[2], SUNG[3], alpha)
    cairo_pattern_add_color_stop_rgba(pat, a, SUNG[1], SUNG[2], SUNG[3], alpha)
    cairo_pattern_add_color_stop_rgba(pat, b, UNSUNG[1], UNSUNG[2], UNSUNG[3], alpha)
    cairo_pattern_add_color_stop_rgba(pat, 1, UNSUNG[1], UNSUNG[2], UNSUNG[3], alpha)
    cairo_set_source(cr, pat)
    cairo_pattern_destroy(pat)
  end
end

-- p: karaoke progress 0..1 (ignored when `solid` colour is given)
local function draw_text(cr, text, W, y, size, glow, alpha, maxw, p, solid)
  if alpha < 0.01 then return end
  cairo_select_font_face(cr, FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
  cairo_set_font_size(cr, size)
  cairo_text_extents(cr, text, ext)
  if ext.x_advance > maxw then                -- shrink long lines to fit the window
    size = size * maxw / ext.x_advance
    cairo_set_font_size(cr, size)
    cairo_text_extents(cr, text, ext)
  end
  local adv = ext.x_advance
  local x
  if ALIGN == "left" then x = PAD_LEFT
  elseif ALIGN == "center" then x = (W - adv) / 2
  else x = W - PAD_RIGHT - adv end

  if SHADOW then
    cairo_set_source_rgba(cr, 0, 0, 0, alpha * SHADOW_ALPHA)
    cairo_move_to(cr, x + SHADOW_OFFSET, y + SHADOW_OFFSET)
    cairo_show_text(cr, text)
  end

  if GLOW and glow > 0.05 then
    cairo_new_path(cr)
    cairo_move_to(cr, x, y)
    cairo_text_path(cr, text)
    cairo_set_source_rgba(cr, SUNG[1], SUNG[2], SUNG[3], GLOW_ALPHA * glow * alpha)
    cairo_set_line_width(cr, GLOW_WIDTH)
    cairo_stroke(cr)
  end

  if solid then
    cairo_set_source_rgba(cr, solid[1], solid[2], solid[3], alpha)
  else
    set_fill(cr, x, adv, alpha, p)
  end
  cairo_move_to(cr, x, y)
  cairo_show_text(cr, text)
end

local function meta_text()
  if artist ~= "" then return title .. META_SEPARATOR .. artist end
  return title
end

-- Called by Conky every frame (see lua_draw_hook_pre in lyrics.conf)
function conky_draw_lyrics()
  if conky_window == nil then return end

  -- Smoothed clock. /proc/uptime only ticks every 10 ms, which would cause
  -- micro-stutter at 60 fps, so we average the frame time and nudge toward it.
  local raw = now()
  if not tm or math.abs(raw - tm) > 0.5 then tm, last_raw = raw, raw end
  local dt_raw = math.min(raw - last_raw, 0.2)
  last_raw = raw
  perf_tick(raw, dt_raw)
  dt_f = dt_f + (dt_raw - dt_f) * 0.1
  tm = tm + dt_f
  tm = tm + (raw - tm) * 0.05

  read_state(raw)

  -- Fade the lyrics and the title row in/out depending on what there is to show
  local fresh = (tm - base_stamp) < 5
  local on_air = (status == "Playing" or status == "Paused") and fresh
  local lyrics_on = on_air and #lines > 0
  local meta_on = SHOW_META and on_air and title ~= ""
  local fade = 1 - math.exp(-FADE_SPEED * dt_f)
  g_alpha = g_alpha + ((lyrics_on and 1 or 0) - g_alpha) * fade
  g_meta  = g_meta  + ((meta_on and 1 or 0) - g_meta) * fade
  local show_lyrics, show_meta = g_alpha >= 0.01, g_meta >= 0.01
  if not show_lyrics and not show_meta then return end

  -- Current playback position, interpolated between daemon updates
  local pos = base_pos
  if status == "Playing" and off then pos = tm + off end
  pos = pos + LOOKAHEAD

  local idx = find_idx(pos)
  if snap or math.abs(idx - s_anim) > SIDE + 2 then
    s_anim, snap = idx, false
  else
    s_anim = s_anim + (idx - s_anim) * (1 - math.exp(-SCROLL_SPEED * dt_f))
  end

  -- Karaoke progress of the current line: follows the target quickly but
  -- smoothly, and never runs backwards unless you seek.
  if KARAOKE and idx > 0 and lines[idx] then
    local target = sweep_target(idx, pos)
    if kp_idx ~= idx then
      kp_idx, kp_val = idx, target
    elseif target > kp_val then
      kp_val = kp_val + (target - kp_val) * (1 - math.exp(-16 * dt_f))
    elseif kp_val - target > 0.25 then
      kp_val = target
    end
  end

  local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable,
                                       conky_window.visual, conky_window.width, conky_window.height)
  local cr = cairo_create(cs)
  local W, H = conky_window.width, conky_window.height
  local maxw, cy = W - PAD_LEFT - PAD_RIGHT, H / 2 + OFFSET_Y

  if show_lyrics then
    for i = math.floor(s_anim) - SIDE, math.ceil(s_anim) + SIDE do
      local l = lines[i]
      if l then
        local text = l[2]
        if text == "" and i == idx then text = INSTRUMENTAL_MARK end
        if text ~= "" then
          local d = i - s_anim                -- distance from the current line, in lines
          local a = math.abs(d)
          local size = curve(SIZES, a)
          local alpha = curve(ALPHAS, a) * g_alpha
          local glow = math.max(0, 1 - a)
          local p = 1                         -- lines already sung (or karaoke off)
          if KARAOKE then
            if i > idx then p = 0 elseif i == idx then p = kp_val end
          end
          draw_text(cr, text, W, cy + d * LINE_GAP + size * 0.35, size, glow, alpha, maxw, p, nil)
        end
      end
    end
  end

  if show_meta then
    -- sits below the last visible lyric line; glides to the middle when there are no lyrics
    local my = cy + (VIS * LINE_GAP + META_GAP) * g_alpha + META_SIZE * 0.35
    draw_text(cr, meta_text(), W, my, META_SIZE, 0, META_ALPHA * g_meta, maxw, 0, METACOL)
  end

  cairo_destroy(cr)
  cairo_surface_destroy(cs)
end
