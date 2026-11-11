# Changelog

All notable changes to the sound-cast Plasma widget. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-11-11

### Added

- A volume slider and a mute button on the card of every room that plays.
- The card shows the track that plays and the room's delay.
- An "Apps" section: each app's stream can play on its own output, one app in a
  room and the others here. `sound-cast-move --stream INDEX SINK|--local` does it
  from the command line.
- Notifications when another app takes a Chromecast (with a "Take back" button), when
  a room fails, and when a Chromecast does not fetch the audio. At most one for each
  room and kind every 5 minutes; they can be turned off in the settings.
- "Look for Chromecasts again" in the menu.

### Changed

- Moving the default output leaves alone the streams sent to another room.
- The event log explains the new events: pause, play and stop on the Chromecast,
  and rescans.

The volume and mute, the rescan, the track and the delay need sound-cast 0.2.0
or later; with an older one these controls stay hidden or greyed out.

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

[Unreleased]: https://github.com/iupsilon/plasma-applet-sound-cast/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/iupsilon/plasma-applet-sound-cast/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/iupsilon/plasma-applet-sound-cast/releases/tag/v0.1.1
[0.1.0]: https://github.com/iupsilon/plasma-applet-sound-cast/releases/tag/v0.1.0
