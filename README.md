# sound-cast Plasma widget

A KDE Plasma 6 widget for [sound-cast](https://github.com/iupsilon/sound-cast), which streams
PipeWire audio to Chromecast devices.

- Turns the `sound-cast` user service on and off, and sets it to start at login.
- Shows every room that plays: each step of the connection with its timer, the
  Chromecast volume, buffering, and whether the Chromecast fetches the audio.
- Lists the outputs (this computer and every Chromecast) with their state; one click
  moves the audio there.
- Takes a Chromecast back when another app (for example YouTube) took it.
- Keeps a log of recent events (devices lost and found, restarts, errors).

The widget reads sound-cast's state from its D-Bus object (`org.soundcast.Daemon` on the
session bus, interface `org.soundcast.Daemon1`), the service state from systemd and the
default output from the Plasma audio module, all through change signals: nothing is polled. Shell commands (`systemctl --user`, `sound-cast-move`) run only
when you start or stop the service or move the audio.

## Requirements

- [sound-cast](https://github.com/iupsilon/sound-cast) with its `sound-cast.service` user unit
- Plasma 6 with `plasma-pa` and `plasma5support`
- `pactl` (libpulse) and systemd user services

## Install

Arch Linux: build the package in `packaging/arch`:

```sh
cd packaging/arch && makepkg -si
```

Elsewhere:

```sh
sudo make install            # PREFIX=/usr by default
```

For development, install for the current user only and run it in a window:

```sh
make test-install
plasmawindowed org.soundcast.status
make test-uninstall          # the user copy overrides the system one: remove it after
```

Then add "sound-cast" to a panel or the system tray.

## Settings

Right-click the widget, Configure:

- **Service**: the systemd user unit (`sound-cast`).

The Chromecasts fetch the audio from the sound-cast port (3000 by default), so it must be
reachable from the network (for example `sudo ufw allow 3000/tcp`). The widget warns when
a Chromecast does not fetch it.

## `sound-cast-move`

Command-line helper the widget uses to move the audio:

```sh
sound-cast-move sound-cast.sala     # default output + move every stream there
sound-cast-move --local             # move the streams on Chromecasts back to a local sink
```

## Translations

Strings are in `po/`. After changing the UI, run `make merge`, then translate the new
entries in `po/<lang>.po`. Add a language by copying the `.pot` file to `po/<lang>.po`.

## License

GPL-3.0-or-later. See `LICENSE`.
