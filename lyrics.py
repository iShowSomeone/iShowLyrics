#!/usr/bin/env python3
"""
lyrics.py - background helper for the iShowLyrics desktop widget.
Author: iShowSomeone    Version: 1.0.1

What it does:
  1. Finds the music player that is playing right now (through playerctl / MPRIS).
  2. Downloads time-synced lyrics (.lrc) from LRCLIB (https://lrclib.net) and caches them.
  3. Writes the player position, song title and artist into a small "state" file,
     twice a second. lyrics.lua reads that file and does all the drawing.

Usage:
  python3 lyrics.py --daemon   run the helper (normally started by `ishowlyrics start`)
  python3 lyrics.py --once     print what the daemon currently sees (for debugging)
  python3 lyrics.py --probe [seconds]
                               measure how accurately the playing player reports the
                               song position (also: `ishowlyrics probe`)
"""
__author__ = "iShowSomeone"
__version__ = "1.0.1"

import fcntl, hashlib, json, os, re, shutil, statistics, subprocess, sys, time
from collections import deque
import urllib.error, urllib.parse, urllib.request
from pathlib import Path

# ============================================================================
#  SETTINGS - edit this block to customise behaviour
#  (PREFER_PLAYERS / IGNORE_PLAYERS are also set by `ishowlyrics config`)
# ============================================================================

# How often (seconds) the state file is refreshed. The Lua script smooths
# motion between refreshes, so 0.5 is plenty. Lower = faster reaction to seeks.
POLL_INTERVAL = 0.5

# Player names are matched as case-insensitive substrings of the MPRIS name.
# Run `playerctl -l` to see yours (e.g. "spotify", "org.gnome.Music", "brave.instance2").
PREFER_PLAYERS = []      # checked first when several players are active, e.g. ["spotify"]
IGNORE_PLAYERS = []      # never used at all, e.g. ["firefox"] to ignore browser videos

# Strip noise such as "(Official Video)" and " - Topic" before searching lyrics.
CLEAN_TITLES = True

# Songs LRCLIB has no lyrics for are re-checked after this many hours.
RETRY_MISSING_HOURS = 24

# After a network failure, wait this many seconds before trying again.
RETRY_NETWORK_SECONDS = 30

# Network timeout (seconds) for each request to LRCLIB.
FETCH_TIMEOUT = 8

# Sent to LRCLIB so it can identify this application.
USER_AGENT = "iShowLyrics/1.0.1"

# Where files live. Defaults follow the XDG standard; normally no need to change.
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "ishowlyrics"
RUN_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "ishowlyrics"

# ============================================================================
#  END OF SETTINGS - code below normally doesn't need editing
# ============================================================================

CACHE_DIR.mkdir(parents=True, exist_ok=True)
RUN_DIR.mkdir(parents=True, exist_ok=True)

SEP = "\t"
# One playerctl call returns everything we need (fields separated by a tab).
FMT = SEP.join(["{{status}}", "{{position}}", "{{artist}}", "{{title}}", "{{album}}", "{{mpris:length}}"])


def pc(*args, player=None):
    """Run playerctl and return its output ('' on any error)."""
    cmd = ["playerctl"] + (["-p", player] if player else []) + list(args)
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=2).strip("\n")
    except Exception:
        return ""


def num(s):
    try:
        return float(s)
    except ValueError:
        return 0.0


def uptime():
    """System uptime in seconds. Shared clock between this script and lyrics.lua."""
    with open("/proc/uptime") as f:
        return float(f.read().split()[0])


def clean(s):
    """Remove '(Official Video)'-style noise from a title."""
    return re.sub(r"\s*[\(\[][^)\]]*(official|video|audio|lyrics|visualizer|hd|4k)[^)\]]*[\)\]]",
                  "", s, flags=re.I).strip()


def one_line(s):
    """The state file is tab-separated, one line: strip tabs and newlines."""
    return re.sub(r"[\t\r\n]+", " ", s).strip()


def matches(name, patterns):
    return any(p.lower() in name.lower() for p in patterns)


def info(player):
    """Read one player's state. Returns None for players without artist+title
    (e.g. a paused video on a web page), so they are ignored."""
    t0 = uptime()
    out = pc("metadata", "--format", FMT, player=player)
    t1 = uptime()                      # the player answered somewhere between t0 and t1
    parts = out.split(SEP)
    parts += [""] * (6 - len(parts))
    status, pos, artist, title, album, length = parts[:6]
    if not artist or not title:
        return None
    if CLEAN_TITLES:
        artist = re.sub(r"\s*-\s*Topic$", "", clean(artist))
        title = clean(title)
    return {"player": player, "status": status, "title": title, "artist": artist,
            "album": album, "pos": num(pos) / 1e6, "dur": num(length) / 1e6,
            "t0": t0, "t1": t1, "stamp": t1}


def pick(players):
    """Choose which player to show: a Playing one wins, otherwise a Paused one."""
    players = [p for p in players if not matches(p, IGNORE_PLAYERS)]
    players.sort(key=lambda p: 0 if matches(p, PREFER_PLAYERS) else 1)   # preferred first
    paused = None
    for p in players:
        i = info(p)
        if not i:
            continue
        if i["status"] == "Playing":
            return i
        if i["status"] == "Paused" and paused is None:
            paused = i
    return paused


# ------------------------------------------------------- playback timing --

class PlaybackClock:
    """Works out where the song really is, even when the player's answers are poor.

    Players report the position very differently. Spotify answers instantly and
    exactly. A browser (Firefox playing YouTube, for example) may answer slowly,
    in whole seconds, or only update the value now and then. Following every
    answer blindly makes the lyrics jump back and forth, so each answer is
    treated as a hint: "around time T the song was around position P".

    We keep ONE offset (song time minus system uptime) and move it carefully:
      * the moment of the answer is taken as the middle of the request,
      * repeated values (whole-second or stale positions) are ignored,
      * the offset follows the best recent estimate in small steps,
      * a big sudden change that repeats on the next answer is a seek: snap.
    """
    HISTORY = 4.0      # seconds of answers that are considered
    SEEK_JUMP = 1.0    # a sudden change bigger than this, seen twice, is a seek
    SLEW_FAST = 0.25   # largest offset change per answer while locking on
    SLEW_SLOW = 0.04   # ... and afterwards (keeps the motion smooth)
    MAX_RTT = 0.5      # answers slower than this say little about "now"

    def __init__(self):
        self.key = None
        self.reset()

    def reset(self):
        self.off = None            # song time minus uptime
        self.hist = deque()        # (time, offset) of recent answers
        self.last_pos = None
        self.pending = None        # a possible seek waiting for confirmation
        self.n = 0

    def feed(self, key, pos, t0, t1):
        if key != self.key:        # different song: start over
            self.key = key
            self.reset()
        t = (t0 + t1) / 2
        o = pos - t
        if self.off is None:
            self.off, self.last_pos, self.n = o, pos, 1
            self.hist.append((t, o))
            return self.off
        if t1 - t0 > self.MAX_RTT:
            return self.off
        if abs(pos - self.last_pos) < 1e-3:
            return self.off        # same value again: whole-second or stale position
        self.last_pos = pos
        if abs(o - self.off) > self.SEEK_JUMP:
            if self.pending is not None and abs(o - self.pending) < 0.4:   # confirmed: it is a seek
                self.off, self.pending, self.n = o, None, 1
                self.hist.clear(); self.hist.append((t, o))
            else:
                self.pending = o
            return self.off
        self.pending = None
        self.hist.append((t, o))
        while self.hist and t - self.hist[0][0] > self.HISTORY:
            self.hist.popleft()
        vals = sorted(v for _, v in self.hist)
        # whole-second and slow answers can only UNDER-estimate the offset, so we
        # take a high value (second largest, which ignores one stray high answer)
        best = vals[-2] if len(vals) >= 4 else vals[-1]
        slew = self.SLEW_FAST if self.n < 8 else self.SLEW_SLOW
        self.off += max(-slew, min(slew, best - self.off))
        self.n += 1
        return self.off


class TrackGate:
    """Browsers briefly flip their metadata (ads, page changes). A different song
    is only accepted when it is seen on two polls in a row."""

    def __init__(self):
        self.shown = None
        self.pending = None

    @staticmethod
    def key(i):
        return (i["player"], i["title"], i["artist"])

    def filter(self, i):
        """-> (info to show, fresh). fresh=False: keep showing the previous song for now."""
        k = self.key(i)
        if self.shown is None or k == self.key(self.shown) or k == self.pending:
            self.shown, self.pending = i, None
            return i, True
        self.pending = k
        return self.shown, False

    def clear(self):
        self.shown = self.pending = None


CLOCK = PlaybackClock()
GATE = TrackGate()


# ---------------------------------------------------------------- lyrics --

def cache_path(artist, title):
    return CACHE_DIR / (hashlib.md5(f"{artist}|{title}".encode()).hexdigest() + ".lrc")


def lrclib(endpoint, params):
    url = f"https://lrclib.net/api/{endpoint}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as r:
        return json.load(r)


def find_lyrics(artist, title, album, dur):
    """Return synced lyrics text ('' if LRCLIB has none). Raises on network errors."""
    params = {"artist_name": artist, "track_name": title}
    if album:
        params["album_name"] = album
    if dur > 0:
        params["duration"] = int(dur)
    try:                                           # 1) exact match
        data = lrclib("get", params)
        if data.get("syncedLyrics"):
            return data["syncedLyrics"]
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
    # 2) fuzzy search: take the version whose length is closest to ours
    best = None
    for r in lrclib("search", {"artist_name": artist, "track_name": title}):
        if not r.get("syncedLyrics"):
            continue
        diff = abs((r.get("duration") or 0) - dur) if dur > 0 else 0
        if dur > 0 and diff > 5:                   # >5 s apart = a different version
            continue
        if best is None or diff < best[0]:
            best = (diff, r["syncedLyrics"])
    return best[1] if best else ""


def fetch_to_cache(artist, title, album, dur):
    """Runs as a detached subprocess so the daemon never waits on the network."""
    f = cache_path(artist, title)
    pending = f.with_suffix(".pending")
    pending.touch()
    try:
        lrc = find_lyrics(artist, title, album, float(dur))
    except Exception:
        return                       # network problem: keep the marker, retry later
    f.write_text(lrc)                # '' means "LRCLIB has no lyrics for this song"
    pending.unlink(missing_ok=True)


def lyrics_path_for(i):
    """Path of the cached .lrc for a track ('' if not available yet)."""
    f = cache_path(i["artist"], i["title"])
    pending = f.with_suffix(".pending")
    need_fetch = False
    if f.exists():
        if f.stat().st_size > 0:
            return str(f)
        need_fetch = time.time() - f.stat().st_mtime > RETRY_MISSING_HOURS * 3600
    else:
        need_fetch = True
    busy = pending.exists() and time.time() - pending.stat().st_mtime < RETRY_NETWORK_SECONDS
    if need_fetch and not busy:
        subprocess.Popen([sys.executable, __file__, "--fetch", i["artist"], i["title"],
                          i["album"], str(i["dur"])], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return ""


# ----------------------------------------------------------------- probe --

def probe(seconds=15):
    """Ask the playing player for its position ten times a second and report how
    trustworthy the answers are. Useful when the lyrics jump around: it shows whether
    the player's data is the cause (browsers often are)."""
    i0 = pick(pc("-l").splitlines())
    if not i0:
        print("No playing player with an artist and title found. Start a song and run this again.")
        return 1
    p = i0["player"]
    print(f"Probing '{p}' ({i0['title']} | {i0['artist']}) for {seconds:.0f} s.")
    print("Keep the song PLAYING and do not seek or switch tabs...")
    samples = []
    end = uptime() + seconds
    while uptime() < end:
        t0 = uptime()
        parts = pc("metadata", "--format", FMT, player=p).split(SEP) + [""] * 6
        t1 = uptime()
        samples.append((t0, t1, parts[0], num(parts[1]) / 1e6))
        time.sleep(0.1)
    return analyze_probe([x for x in samples if x[2] == "Playing"], seconds)


def analyze_probe(play, seconds):
    if len(play) < 20:
        print(f"Only {len(play)} usable answers: the player was not 'Playing' for most of the test.")
        return 1
    rtt = sorted((b - a) * 1000 for a, b, _, _ in play)
    med, p95, worst = rtt[len(rtt) // 2], rtt[int(len(rtt) * 0.95)], rtt[-1]
    t = [(a + b) / 2 for a, b, _, _ in play]
    pos = [x[3] for x in play]
    n = len(play)

    same = sum(1 for x, y in zip(pos, pos[1:]) if abs(y - x) < 1e-3) / (n - 1)
    coarse = same >= 0.3                         # many repeated values: whole seconds or stale
    ch = [i for i in range(1, n) if abs(pos[i] - pos[i - 1]) >= 1e-3]
    changes = [t[i] for i in ch]
    period = statistics.median([y - x for x, y in zip(changes, changes[1:])]) if len(changes) > 2 else None
    steps = [pos[i] - pos[i - 1] for i in ch]

    def fit(ts, ps):
        """least-squares line pos = a + slope * t  ->  (slope, residual rms)"""
        m = len(ts)
        mt_, mp_ = sum(ts) / m, sum(ps) / m
        v = sum((x - mt_) ** 2 for x in ts) or 1e-9
        sl = sum((x - mt_) * (y - mp_) for x, y in zip(ts, ps)) / v
        res = [y - (mp_ + sl * (x - mt_)) for x, y in zip(ts, ps)]
        return sl, (sum(r * r for r in res) / m) ** 0.5

    slope = noise = None
    if not coarse:
        slope, noise = fit(t, pos)
    elif len(ch) >= 3:                           # judge the speed from the moments the value changed
        slope, _ = fit([t[i] for i in ch], [pos[i] for i in ch])
    allowed = (period or 0) + 1.5                # a forward step this big is normal for a coarse player
    jumps = sum(1 for i in range(1, n)
                if pos[i] - pos[i - 1] < -0.3 or pos[i] - pos[i - 1] > (t[i] - t[i - 1]) + allowed)

    print(f"\nResults ({n} answers in {seconds:.0f} s)")
    print(f"  Reply time      : median {med:.0f} ms, 95% under {p95:.0f} ms, slowest {worst:.0f} ms")
    if not coarse:
        print("  Position updates: continuously (every answer is different)")
    elif period and 0.8 <= period <= 1.3 and steps and abs(statistics.median(steps) - 1.0) < 0.25:
        print("  Position updates: once per second, in WHOLE SECONDS")
    else:
        print(f"  Position updates: only about every {period:.1f} s; between updates the value stands still"
              if period else "  Position updates: rarely (the value mostly stands still); run the probe longer")
    print(f"  Clock speed     : {slope:.3f}x   (1.000 is real time)" if slope is not None
          else "  Clock speed     : not enough updates to tell")
    print(f"  Jitter          : about {noise * 1000:.0f} ms" if noise is not None
          else "  Jitter          : n/a (the value only moves in steps)")
    print(f"  Jumps           : {jumps}")

    print("\nWhat this means")
    problems = 0
    if p95 > 150:
        problems += 1
        print("  - The player answers slowly when busy. iShowLyrics times each answer by the middle of the")
        print("    request and ignores very slow ones, but expect small timing wobble.")
    if same >= 0.3:
        problems += 1
        print("  - The position is coarse or stale (typical for browsers). iShowLyrics ignores repeated values and")
        print("    keeps its own clock between updates, so lyrics stay smooth but may sit up to ~0.3 s off.")
    if noise is not None and noise > 0.1:
        problems += 1
        print(f"  - The position is noisy (about {noise * 1000:.0f} ms). iShowLyrics averages it, but expect small wobble.")
    if jumps:
        problems += 1
        print(f"  - The position jumped {jumps} time(s): ads, buffering or seeking. iShowLyrics treats a jump that")
        print("    repeats as a seek and re-syncs within about a second.")
    if slope is not None and abs(slope - 1) > 0.05:
        problems += 1
        print(f"  - The clock runs at {slope:.2f}x (playback speed changed?). Lyrics drift at other speeds.")
    if not problems:
        print("  - This player reports its position accurately. If the animation still looks glitchy, the cause is")
        print("    rendering (the widget starved of CPU): run `ishowlyrics doctor` and look at the 'Frame rate' check.")
    return 0


# ---------------------------------------------------------------- daemon --

def build_state(players):
    """One line, tab separated:
         status  position  uptime-stamp  lrc-path  title  artist
    `position` is the best estimate of where the song is AT `uptime-stamp`."""
    i = pick(players)
    if not i:
        GATE.clear()
        CLOCK.reset(); CLOCK.key = None
        return SEP.join(["Stopped", "0", f"{uptime():.3f}", "", "", ""]), None
    i, fresh = GATE.filter(i)
    if i["status"] == "Playing":
        if fresh:
            CLOCK.feed(GATE.key(i), i["pos"], i["t0"], i["t1"])
        stamp = uptime()
        pos = CLOCK.off + stamp if CLOCK.off is not None else i["pos"]
    else:                                   # paused: the reported position is exact
        CLOCK.reset()
        pos, stamp = i["pos"], i["stamp"]
    return SEP.join([i["status"], f"{pos:.3f}", f"{stamp:.3f}", lyrics_path_for(i),
                     one_line(i["title"]), one_line(i["artist"])]), i


def daemon():
    lock = open(RUN_DIR / "daemon.lock", "w")      # keep a reference: lock lives as long as we do
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit("lyrics.py: daemon is already running")
    state, tmp = RUN_DIR / "state", RUN_DIR / "state.tmp"
    players, players_t = [], 0.0
    while True:
        if time.time() - players_t > 2:            # re-scan the player list every 2 s
            players, players_t = pc("-l").splitlines(), time.time()
        line, _ = build_state(players)
        tmp.write_text(line + "\n")
        os.replace(tmp, state)                     # atomic: Lua never sees half a file
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    if not shutil.which("playerctl"):
        sys.exit("lyrics.py: playerctl not found (install it with your package manager)")
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "--fetch":
        fetch_to_cache(*sys.argv[2:6])
    elif mode == "--daemon":
        daemon()
    elif mode == "--probe":
        sys.exit(probe(float(sys.argv[2]) if len(sys.argv) > 2 else 15.0))
    elif mode == "--once":
        line, i = build_state(pc("-l").splitlines())
        print("player:", i["player"] if i else "(none)")
        if i:
            print("track :", f"{i['title']} | {i['artist']}")
        print("state :", line.replace(SEP, " | "))
    else:
        print(__doc__)
