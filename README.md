# sound-cast Plasma widget

A KDE Plasma 6 widget for [sound-cast](https://github.com/iupsilon/sound-cast), which streams
PipeWire audio to Chromecast devices.

- Turns the `sound-cast` user service on and off, and sets it to start at login.
- Shows the stream: which Chromecast plays, the app the audio comes from, each step of
  the connection with its timer, buffering, and how fresh the served segments are.
- Lists the outputs (this computer and every Chromecast) with their state; one click
  moves the audio there.
- Keeps a log of recent events (devices lost and found, restarts, errors).

> **Status:** sound-cast does not have this status API yet. Until it does, the widget
> can start and stop the service and move the audio to a `sound-cast.*` sink, but
> shows no devices or stream state. The API will be replaced by a D-Bus interface.

The widget talks to sound-cast over its status API (`GET /status` and the `/events`
WebSocket, on the sound-cast port, 3000 by default). It reads the service state from systemd
over D-Bus and the default output from the Plasma audio module, both through change
signals: nothing is polled. Shell commands (`systemctl --user`, `sound-cast-move`) run only
when you start or stop the service or move the audio.

## Requirements

- sound-cast with the status API
- Plasma 6 with `plasma-pa` and `plasma5support`, Qt 6 WebSockets (`qt6-websockets` on Arch)
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

- **Port**: the sound-cast port (`--port`, 3000 by default). The Chromecasts fetch the
  stream from this port, so it must be reachable from the network (for example
  `sudo ufw allow 3000/tcp`).
- **Service**: the systemd user unit (`sound-cast`).

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
