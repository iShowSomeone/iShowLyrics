# iShowLyrics

<img width="1837" height="1028" alt="Screenshot From 2026-10-09 15-52-04" src="https://github.com/user-attachments/assets/1c7403bf-3071-4c86-abda-8c8f9d8a74f1" />
iShowLyrics in CachyOS (KDE)


Synced, animated lyrics on your Linux desktop. iShowLyrics is a [Conky](https://github.com/brndnmtthws/conky) widget that follows whatever you are playing (Spotify, GNOME Music, a browser tab, VLC, ...) and shows the current lyric line with smooth scrolling, the song title and artist underneath, and an optional karaoke sweep.

- Works with any player that supports MPRIS (anything `playerctl` can see)
- Time-synced lyrics from [LRCLIB](https://lrclib.net), cached locally
- Looks the way you want: font, size, colours, position, frame rate
- Pin on top, with mouse clicks passing through the widget
- Guided installer, integrity check and a built-in problem finder

Version 1.0.1 · Author: iShowSomeone · License: MIT

## Tested desktops

| Desktop | Status |
|---|---|
| GNOME (Wayland and X11) | Tested |
| KDE Plasma | Tested |
| Hyprland | Works, but unoptimized and not recommended |
| Sway, i3 and other tiling window managers, XFCE, Cinnamon, MATE | Untested (sensible defaults are chosen automatically) |

Conky draws through X11. On Wayland it runs through XWayland.

## Requirements

- Conky **with Lua and Cairo support** (on Debian/Ubuntu: `conky-all`)
- `playerctl`, Python 3.8 or newer, `perl`, `fontconfig`

The installer checks all of these and offers to install what is missing (apt, dnf, pacman and zypper are supported; only apt has been exercised much).

## Install

```bash
git clone https://github.com/iShowSomeone/iShowLyrics.git iShowLyrics-src
cd iShowLyrics-src
bash install.sh
```

The name at the end of the clone command keeps the download in `iShowLyrics-src`, separate from `~/iShowLyrics`, where the widget is installed. Afterwards you can delete `iShowLyrics-src`, or keep it to update later:

```bash
cd iShowLyrics-src && git pull && bash install.sh
```

The installer asks where the widget should appear, which font, size and colours to use, and so on. Press Enter to accept the answer shown in brackets. Everything is installed into `~/iShowLyrics` and a command called `ishowlyrics` is added. If `~/.local/bin` is not on your PATH yet, the installer offers to add it; open a new terminal afterwards.

Then play a song. Lyrics fade in after a moment.

`bash install.sh --defaults` installs without asking anything.

## Commands

| Command | What it does |
|---|---|
| `ishowlyrics start` / `stop` / `restart` | Control the widget |
| `ishowlyrics status` | What is running and what is playing |
| `ishowlyrics pin` / `unpin` | Keep the widget above other windows (off by default) |
| `ishowlyrics reset [layer]` | Widget invisible? Clean restart on the base layer |
| `ishowlyrics config` | Change your settings; your answers become the new defaults |
| `ishowlyrics verify` | Check that the installation is intact |
| `ishowlyrics doctor` | Find out why something doesn't work, with suggested fixes |
| `ishowlyrics probe` | Measure how accurately your player reports the song position |
| `ishowlyrics env` | Detected desktop and the window layer in use |
| `ishowlyrics autostart on\|off` | Start at login |
| `ishowlyrics uninstall` | Remove iShowLyrics |

## Customising

Run `ishowlyrics config` for the guided questions. For finer control, edit the commented files in `~/iShowLyrics`, then run `ishowlyrics restart`:

- `lyrics.lua`: look and animation (fonts, sizes, colours, effects, karaoke, song title row)
- `lyrics.conf`: the Conky window (position, size, frame rate)
- `lyrics.py`: player handling (preferred and ignored players, lookup behaviour)

## Troubleshooting

- **Nothing appears:** play a song with an artist and title, then run `ishowlyrics doctor`.
- **Widget invisible although everything looks fine:** `ishowlyrics reset`. If it stays invisible, try `ishowlyrics reset desktop`, `reset below` or `reset override`.
- **Clicks don't reach the window under the widget:** `ishowlyrics restart`, then `ishowlyrics doctor`.
- **Lyrics jump around in a browser:** browsers report the song position less accurately than music apps. Run `ishowlyrics probe` while a video plays to see how yours behaves.
- **Impact font missing:** on Debian/Ubuntu the installer can install it (Microsoft's fonts licence applies). Otherwise it offers free look-alikes (Anton, Bebas Neue, Archivo Black).

When reporting a bug, attach `~/iShowLyrics/doctor-report.txt`, which `ishowlyrics doctor` writes.

## Network use and privacy

- The artist, title, album and length of the playing song are sent to `lrclib.net` to find lyrics.
- Free fonts, if you choose them, are downloaded from the Google Fonts repository on GitHub.
- Nothing else leaves your machine.

## Credits

Conky, playerctl, LRCLIB (lyrics database) and the open-source fonts Anton, Bebas Neue and Archivo Black (SIL Open Font License).

## License

MIT, see [LICENSE](LICENSE).
