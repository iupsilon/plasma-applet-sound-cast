# Changelog

All notable changes to the sound-cast Plasma widget. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-11-10

- "Add Widgets" shows the colour sound-cast logo; it needs sound-cast 0.1.1, which
  installs it. The panel and the system tray keep the symbolic icon.
- The README links the widget's KDE Store page.

## [0.1.0] - 2026-11-10

First public release.

- Plasma 6 widget for panels and the system tray.
- Turns the `sound-cast` user service on and off, and enables it at login.
- A card for every room that plays: connection steps with timers, Chromecast volume,
  buffering, and whether the Chromecast fetches the audio.
- Output list with one-click moves between this computer and every Chromecast.
- Countdown, resume and stop for a room the audio left.
- Takes back a Chromecast that another app took.
- Event log, folded into one line.
- State read over D-Bus from sound-cast: nothing is polled.
- `sound-cast-move` command-line helper.
- English and Italian.
- Packages for Arch Linux, Debian/Ubuntu and Fedora, built on every tag.

[0.1.1]: https://github.com/iupsilon/plasma-applet-sound-cast/releases/tag/v0.1.1
[0.1.0]: https://github.com/iupsilon/plasma-applet-sound-cast/releases/tag/v0.1.0
