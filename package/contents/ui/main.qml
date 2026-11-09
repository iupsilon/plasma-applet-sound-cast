/*
 * sound-cast status widget.
 *
 * Service state comes from systemd over D-Bus (property change signals), the default
 * output from the Plasma audio module, the rest from sound-cast's /events WebSocket:
 * device phases with their timers, the active stream and an event log.
 * Nothing is polled: shell commands run only for user actions.
 */
import QtCore
import QtQuick
import QtQuick.Layouts
import QtWebSockets
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.private.volume as PA
import org.kde.plasma.workspace.dbus as DBus
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // -- state -------------------------------------------------------------------------

    readonly property string unit: Plasmoid.configuration.unitName || "sound-cast"
    readonly property int port: Plasmoid.configuration.port || 3000

    readonly property string unitFile: unit.includes(".") ? unit : unit + ".service"
    // active, inactive, activating, deactivating, failed
    readonly property string unitActive: propString(unitProps.properties.ActiveState) || "unknown"
    // running, auto-restart, start, dead, failed, ...
    readonly property string unitSub: propString(unitProps.properties.SubState)
    readonly property int unitRestarts: parseInt(propString(serviceProps.properties.NRestarts)) || 0
    // enabled, disabled, ...
    readonly property string unitFileState: propString(unitProps.properties.UnitFileState)
    property string pendingAction: ""       // "start" / "stop" until systemd reports it
    // PulseAudio/PipeWire default output
    readonly property string defaultSink: PA.Server.defaultSink ? PA.Server.defaultSink.name : ""
    property string pendingSink: ""         // output chosen in the widget, until it is the default
    readonly property string castIcon: Qt.resolvedUrl("../icons/sound-cast-symbolic.svg")

    property var pstatus: null              // last "status" message from sound-cast
    property var events: []
    property real clockOffset: 0            // server time - local time
    property real now: Date.now() / 1000
    property bool showAllEvents: false
    property string confirmSink: ""         // busy device waiting for "interrupt?" confirmation
    readonly property int collapsedEvents: 3
    readonly property string logFile: `${StandardPaths.writableLocation(StandardPaths.GenericStateLocation)}/${unit}/sound-cast.log`.replace("file://", "")

    readonly property bool serviceOn: unitActive === "active" || unitActive === "activating" || unitActive === "reloading"
    readonly property bool autoRestarting: unitActive === "activating" && unitSub === "auto-restart"
    readonly property bool connected: socket.status === WebSocket.Open && pstatus !== null
    readonly property var devices: connected ? sortedDevices(pstatus.devices) : []
    readonly property var activeDevice: {
        if (!connected || !pstatus.stream.sink_name)
            return null;
        return devices.find(d => d.sink_name === pstatus.stream.sink_name) || null;
    }
    // A sound-cast device chosen as output (by the widget or the desktop mixer); it streams
    // only while something plays.
    readonly property var selectedDevice: defaultSink.startsWith("sound-cast.") ? (devices.find(d => d.sink_name === defaultSink) || null) : null
    readonly property bool busy: pendingAction !== "" || pendingSink !== "" || unitActive === "activating" || unitActive === "deactivating"
        || (activeDevice !== null && transitional(activeDevice.phase))

    // -- helpers -----------------------------------------------------------------------

    // D-Bus property values may come wrapped ({value: ...}) or plain.
    function propString(v) {
        if (v === undefined || v === null)
            return "";
        return String(v.value !== undefined ? v.value : v);
    }

    // systemd object path of a unit: every byte outside [A-Za-z0-9] becomes _xx.
    function unitPath(name) {
        let out = "";
        for (const ch of name)
            out += /[A-Za-z0-9]/.test(ch) ? ch : "_" + ch.charCodeAt(0).toString(16).padStart(2, "0");
        return "/org/freedesktop/systemd1/unit/" + out;
    }

    // Re-read the unit properties (signals cover changes; this is for unit file state).
    function refreshUnit() {
        unitProps.updateAll();
        serviceProps.updateAll();
    }

    function serverNow() {
        return now + clockOffset;
    }

    function transitional(phase) {
        return ["connecting", "encoder", "subscribing", "quitting_app", "busy", "loading", "buffering", "restarting", "lingering", "checking"].includes(phase);
    }

    function sortedDevices(list) {
        const rank = d => d.sink_name === (pstatus && pstatus.stream.sink_name) ? 0 : d.phase === "unavailable" ? 2 : 1;
        return list.slice().sort((a, b) => rank(a) - rank(b) || a.friendly_name.localeCompare(b.friendly_name));
    }

    function deviceName(sinkName) {
        if (!sinkName)
            return "";
        const d = pstatus ? pstatus.devices.find(x => x.sink_name === sinkName) : null;
        return d ? d.friendly_name : sinkName;
    }

    function secondsLeft(dev) {
        return dev.deadline ? Math.max(0, Math.ceil(dev.deadline - serverNow())) : 0;
    }

    function elapsed(since) {
        return Math.max(0, Math.floor(serverNow() - since));
    }

    function timerFraction(dev) {
        if (!dev.deadline || dev.deadline <= dev.since)
            return 0;
        return Math.min(1, Math.max(0, (dev.deadline - serverNow()) / (dev.deadline - dev.since)));
    }

    function reasonLabel(reason) {
        switch (reason) {
        case "activation failed": return i18n("the stream could not start");
        case "connection lost": return i18n("connection lost");
        case "encoder exited": return i18n("the encoder stopped");
        case "gone from mDNS":
        case "removed from mDNS": return i18n("no longer announced on the network");
        case "no audio": return i18n("no audio");
        case "not reachable": return i18n("not responding");
        case "health check failed": return i18n("not responding");
        default: return reason || "";
        }
    }

    function phaseLabel(phase) {
        switch (phase) {
        case "ready": return i18n("Ready");
        case "unavailable": return i18n("Not reachable");
        case "checking": return i18n("Checking");
        case "connecting": return i18n("Connecting");
        case "encoder": return i18n("Starting encoder");
        case "subscribing": return i18n("Preparing stream");
        case "quitting_app": return i18n("Closing other app");
        case "busy": return i18n("Waiting, in use");
        case "loading": return i18n("Loading on the Chromecast");
        case "playing": return i18n("Playing");
        case "paused": return i18n("Paused");
        case "idle": return i18n("Stopped on the Chromecast");
        case "buffering": return i18n("Buffering");
        case "restarting": return i18n("Restarting");
        case "lingering": return i18n("No audio");
        default: return phase;
        }
    }

    // One line telling what is happening and, when a timer runs, what happens when.
    function phaseDetail(dev) {
        const left = secondsLeft(dev);
        switch (dev.phase) {
        case "ready": return i18n("Ready");
        case "unavailable":
            if (dev.deadline && left > 0)
                return i18n("Not reachable: %1, retrying in %2 s", reasonLabel(dev.reason), left);
            return dev.reason ? i18n("Not reachable: %1", reasonLabel(dev.reason)) : i18n("Not reachable");
        case "checking":
            return dev.reason === "unavailable" ? i18n("Checking if it is back… %1 s", left) : i18n("Checking connection… %1 s", left);
        case "connecting": return i18n("Connecting… timeout in %1 s", left);
        case "encoder": return i18n("Starting encoder…");
        case "subscribing": return i18n("Preparing stream… %1 s", left);
        case "quitting_app":
            return dev.deadline ? i18n("Closing %1…", dev.reason || i18n("other app")) : i18n("Closing %1 on the Chromecast…", dev.reason || i18n("other app"));
        case "busy": return i18n("%1 is playing, starts when it ends", dev.reason || i18n("another app"));
        case "loading": return i18n("Loading on the Chromecast… %1 s", elapsed(dev.since));
        case "playing": return i18n("Playing");
        case "paused": return i18n("Paused on the Chromecast");
        case "idle": return i18n("Stopped on the Chromecast");
        case "buffering": return i18n("Buffering, restart in %1 s if it does not recover", left);
        case "restarting":
            return dev.deadline && left > 0 ? i18n("Restarting in %1 s (%2)", left, reasonLabel(dev.reason)) : i18n("Restarting…");
        case "lingering": return i18n("No audio, stops in %1 s", left);
        default: return phaseLabel(dev.phase);
        }
    }

    function phaseColor(phase) {
        switch (phase) {
        case "playing": return Kirigami.Theme.positiveTextColor;
        case "unavailable": return Kirigami.Theme.negativeTextColor;
        case "ready":
        case "paused":
        case "idle": return Kirigami.Theme.disabledTextColor;
        case "buffering":
        case "busy":
        case "restarting": return Kirigami.Theme.neutralTextColor;
        default: return Kirigami.Theme.highlightColor;
        }
    }

    function eventText(ev) {
        const a = ev.args || {};
        switch (ev.code) {
        case "started": return i18np("sound-cast started, %1 device found", "sound-cast started, %1 devices found", a.count || 0);
        case "activated": return a.app ? i18n("Audio from %1", a.app) : i18n("Audio arrived");
        case "switching": return i18n("Audio moved here from %1", deviceName(a.previous));
        case "connecting": return i18n("Connecting to the Chromecast");
        case "quitting_app": return i18n("Closing %1 on the Chromecast", a.app);
        case "loading": return i18n("Stream sent to the Chromecast");
        case "busy": return i18n("%1 is playing, waiting for it to end", a.app);
        case "busy_over": return i18n("The Chromecast is free, starting");
        case "took_over": return i18n("Replacing %1", a.app);
        case "buffering": return i18n("The Chromecast is buffering");
        case "buffering_restart": return i18n("Buffering for %1 s, restarting the stream", a.seconds);
        case "connection_lost": return i18n("Connection to the Chromecast lost");
        case "load_failed": return i18n("The Chromecast could not load the stream (error %1)", a.error);
        case "buffering_loop": return i18n("The Chromecast keeps buffering: unplug it and plug it back in");
        case "not_reachable": return i18n("The Chromecast did not respond within %1 s", a.seconds);
        case "gone": return i18n("Device disappeared from the network");
        case "ffmpeg_failed": return i18n("The encoder failed to start, sound-cast is shutting down");
        case "ffmpeg_exited": return i18n("The encoder stopped (code %1), restarting", a.exit_code);
        case "subscribe_failed": return i18n("Could not start the stream: %1", a.error);
        case "activation_failed": return i18n("Could not start the stream");
        case "stopped": return i18n("Stream stopped");
        case "moved_away": return i18n("Audio moved to another output");
        case "idle_stop": return i18n("No audio for %1 s, stream stopped", Math.round(a.seconds || 0));
        case "skip_unavailable": return i18n("Audio sent to a device that is not reachable");
        case "unavailable": return i18n("Device no longer available: %1", reasonLabel(a.reason));
        case "address_changed": return i18n("Device changed address, checking it");
        case "added": return i18n("New device found");
        case "restored": return i18n("Device available again");
        default: return ev.text;
        }
    }

    function summary() {
        if (pendingAction === "start" || (unitActive === "activating" && !autoRestarting))
            return i18n("Starting, looking for Chromecasts…");
        if (pendingAction === "stop" || unitActive === "deactivating")
            return i18n("Stopping…");
        if (autoRestarting)
            return i18n("sound-cast stopped unexpectedly, restarting automatically");
        if (unitActive === "failed")
            return i18n("sound-cast stopped with an error");
        if (!serviceOn)
            return i18n("Off");
        if (!connected)
            return i18n("Connecting to sound-cast…");
        if (activeDevice)
            return i18n("%1: %2", activeDevice.friendly_name, phaseLabel(activeDevice.phase));
        if (selectedDevice)
            return i18n("%1 selected, waiting for audio", selectedDevice.friendly_name);
        const n = devices.filter(d => d.phase !== "unavailable").length;
        return n === 0 ? i18n("No Chromecast found on this network") : i18np("On, %1 device ready", "On, %1 devices ready", n);
    }

    function overallColor() {
        if (unitActive === "failed" || autoRestarting)
            return Kirigami.Theme.negativeTextColor;
        if (!serviceOn)
            return "transparent";
        if (activeDevice)
            return phaseColor(activeDevice.phase);
        return connected ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.highlightColor;
    }

    // -- actions -----------------------------------------------------------------------

    function setService(on) {
        pendingAction = on ? "start" : "stop";
        const cmd = on ? `systemctl --user reset-failed ${unit}; systemctl --user start ${unit}` : `systemctl --user stop ${unit}`;
        exec.run(cmd, () => {
            pendingAction = "";
            refreshUnit();
        });
    }

    function setAutostart(on) {
        exec.run(`systemctl --user ${on ? "enable" : "disable"} ${unit}`, () => refreshUnit());
    }

    function moveAudio(sinkName) {
        // sink names are [a-z0-9_.] (sound-cast makes them), safe for the shell
        pendingSink = sinkName || "local";
        pendingSinkTimeout.restart();
        exec.run(sinkName ? `sound-cast-move ${sinkName}` : "sound-cast-move --local", () => {});
    }

    // Ask sound-cast to interrupt the other app (needed with --takeover idle; harmless otherwise).
    function takeover(sinkName) {
        const xhr = new XMLHttpRequest();
        xhr.open("POST", `http://127.0.0.1:${port}/devices/${sinkName}/takeover`);
        xhr.send();
    }

    // A click on a device: confirm first when another app plays on it.
    function chooseDevice(dev) {
        const isActive = activeDevice !== null && activeDevice.sink_name === dev.sink_name;
        if ((dev.busy_with && !isActive) || dev.phase === "busy") {
            confirmSink = confirmSink === dev.sink_name ? "" : dev.sink_name;
            return;
        }
        confirmSink = "";
        moveAudio(dev.sink_name);
    }

    // interrupt: stop the other app now; otherwise (--takeover idle) wait for it to end.
    function confirmDevice(dev, interrupt) {
        confirmSink = "";
        if (interrupt)
            takeover(dev.sink_name);
        if (defaultSink !== dev.sink_name)
            moveAudio(dev.sink_name);
    }

    function isPendingTarget(sinkName) {
        return pendingSink !== "" && (pendingSink === sinkName || (pendingSink === "local" && sinkName === ""));
    }

    onDefaultSinkChanged: {
        if (pendingSink !== "" && (pendingSink === defaultSink || (pendingSink === "local" && !defaultSink.startsWith("sound-cast."))))
            pendingSink = "";
    }

    function handleMessage(message) {
        let msg;
        try {
            msg = JSON.parse(message);
        } catch (e) {
            return;
        }
        if (msg.type === "status") {
            clockOffset = msg.status.now - Date.now() / 1000;
            if (msg.status.events !== undefined)
                events = msg.status.events;
            pstatus = msg.status;
        } else if (msg.type === "event") {
            const list = events.slice(-49);
            list.push(msg.event);
            events = list;
        }
    }

    // -- plumbing ----------------------------------------------------------------------

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})
        property int serial: 0
        onNewData: (source, data) => {
            const cb = callbacks[source];
            delete callbacks[source];
            disconnectSource(source);
            if (cb)
                cb(data["exit code"], data["stdout"] || "", data["stderr"] || "");
        }
        // Only for user actions. Each run gets its own source name (a trailing shell
        // comment), so a command still running never blocks or swallows the next one;
        // the timeout makes sure every source ends and is released.
        function run(cmd, cb) {
            const source = `timeout 30 sh -c '${cmd.replace(/'/g, "'\\''")}' #${++serial}`;
            callbacks[source] = cb;
            connectSource(source);
        }
    }

    // systemd unit state over D-Bus: read once, then updated by PropertiesChanged.
    DBus.Properties {
        id: unitProps
        busType: DBus.BusType.Session
        service: "org.freedesktop.systemd1"
        path: root.unitPath(root.unitFile)
        iface: "org.freedesktop.systemd1.Unit"
    }
    DBus.Properties {
        id: serviceProps
        busType: DBus.BusType.Session
        service: "org.freedesktop.systemd1"
        path: root.unitPath(root.unitFile)
        iface: "org.freedesktop.systemd1.Service"
    }
    Component.onCompleted: {
        // systemd sends unit signals only to subscribed clients.
        DBus.SessionBus.asyncCall({
            service: "org.freedesktop.systemd1",
            path: "/org/freedesktop/systemd1",
            iface: "org.freedesktop.systemd1.Manager",
            member: "Subscribe",
        });
    }

    WebSocket {
        id: socket
        url: `ws://127.0.0.1:${root.port}/events`
        active: root.unitActive === "active"
        onTextMessageReceived: (message) => root.handleMessage(message)
        onStatusChanged: {
            if (status === WebSocket.Closed || status === WebSocket.Error) {
                root.pstatus = null;
                if (active)
                    reconnect.start();
            }
        }
    }

    Timer {
        // give up showing "switching" if the default output never changes
        id: pendingSinkTimeout
        interval: 6000
        onTriggered: root.pendingSink = ""
    }

    Timer {
        id: reconnect
        interval: 2000
        onTriggered: {
            socket.active = false;
            socket.active = Qt.binding(() => root.unitActive === "active");
        }
    }

    Timer {
        // countdowns
        interval: 250
        repeat: true
        running: root.expanded || root.busy
        onTriggered: root.now = Date.now() / 1000
    }

    onExpandedChanged: if (!expanded) {
        showAllEvents = false;
        confirmSink = "";
    }

    Plasmoid.icon: castIcon
    Plasmoid.status: unitActive === "failed" || autoRestarting || activeDevice !== null
        ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus
    toolTipMainText: "sound-cast"
    toolTipSubText: summary()

    function openLog() {
        exec.run(`xdg-open '${logFile}'`, () => {});
    }

    // Right-click menu on the panel icon.
    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Start sound-cast at login")
            icon.name: "system-run-symbolic"
            checkable: true
            checked: root.unitFileState === "enabled"
            enabled: root.unitFileState !== ""
            onTriggered: root.setAutostart(checked)
        },
        PlasmaCore.Action {
            text: i18n("Open log")
            icon.name: "text-x-log"
            onTriggered: root.openLog()
        }
    ]

    // -- compact (panel / tray icon) -----------------------------------------------------

    compactRepresentation: MouseArea {
        id: compact
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            source: root.castIcon
            isMask: true
            color: Kirigami.Theme.textColor
            active: compact.containsMouse
            opacity: root.serviceOn ? 1 : 0.5
        }
        Rectangle {
            width: Math.round(parent.width * 0.4)
            height: width
            radius: width / 2
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            color: root.overallColor()
            border.color: Kirigami.Theme.backgroundColor
            border.width: 1
            visible: color.a > 0
            SequentialAnimation on opacity {
                running: root.busy
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation { to: 0.3; duration: 600; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutQuad }
            }
        }
    }

    // -- full (popup) ------------------------------------------------------------------

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        Layout.preferredWidth: Kirigami.Units.gridUnit * 24
        Layout.preferredHeight: Kirigami.Units.gridUnit * 30
        collapseMarginsHint: true

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Kirigami.Heading {
                        level: 3
                        text: "sound-cast"
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.summary()
                        elide: Text.ElideRight
                        opacity: 0.8
                        font: Kirigami.Theme.smallFont
                    }
                }
                PlasmaComponents3.BusyIndicator {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    visible: root.pendingAction !== "" || root.unitActive === "activating" || root.unitActive === "deactivating"
                        || (root.serviceOn && !root.connected)
                    running: visible
                }
                PlasmaComponents3.Switch {
                    checked: root.pendingAction ? root.pendingAction === "start" : root.serviceOn
                    enabled: root.pendingAction === ""
                    onToggled: root.setService(checked)
                    PlasmaComponents3.ToolTip.text: checked ? i18n("Stop sound-cast") : i18n("Start sound-cast")
                    PlasmaComponents3.ToolTip.visible: hovered
                }
                PlasmaComponents3.ToolButton {
                    id: menuButton
                    icon.name: "overflow-menu"
                    checkable: true
                    checked: optionsMenu.opened
                    onClicked: optionsMenu.popup(menuButton, 0, menuButton.height)
                    PlasmaComponents3.ToolTip.text: i18n("More options")
                    PlasmaComponents3.ToolTip.visible: hovered && !optionsMenu.opened

                    PlasmaComponents3.Menu {
                        id: optionsMenu
                        PlasmaComponents3.MenuItem {
                            text: i18n("Start sound-cast at login")
                            icon.name: "system-run-symbolic"
                            checkable: true
                            checked: root.unitFileState === "enabled"
                            enabled: root.unitFileState !== ""
                            onTriggered: root.setAutostart(checked)
                        }
                        PlasmaComponents3.MenuItem {
                            text: i18n("Open log")
                            icon.name: "text-x-log"
                            onTriggered: root.openLog()
                        }
                        PlasmaComponents3.MenuSeparator {}
                        PlasmaComponents3.MenuItem {
                            text: i18n("Configure widget…")
                            icon.name: "configure-symbolic"
                            onTriggered: Plasmoid.internalAction("configure").trigger()
                        }
                    }
                }
            }
        }

        // Header and stream card stay put; only the output list scrolls. The event log is an
        // accordion pinned to the bottom: closed it shows the latest events, open it takes the
        // place of the output list and scrolls on its own.
        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            ServiceMessage {
                Layout.fillWidth: true
            }

            StreamCard {
                Layout.fillWidth: true
                visible: root.activeDevice !== null
            }

            SectionTitle {
                Layout.fillWidth: true
                visible: root.connected && !root.showAllEvents
                text: i18n("Output")
            }
            PlasmaComponents3.ScrollView {
                id: outputScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.connected && !root.showAllEvents
                PlasmaComponents3.ScrollBar.horizontal.policy: PlasmaComponents3.ScrollBar.AlwaysOff
                contentWidth: availableWidth

                Card {
                    width: outputScroll.availableWidth
                    OutputRow {
                        Layout.fillWidth: true
                        iconSource: "computer-symbolic"
                        title: i18n("This computer")
                        selected: root.defaultSink !== "" && !root.defaultSink.startsWith("sound-cast.")
                        pending: root.isPendingTarget("")
                        subtitle: pending ? i18n("Switching…") : selected ? i18n("Audio plays here") : ""
                        subtitleColor: Kirigami.Theme.highlightColor
                        tooltip: i18n("Play the audio on this computer")
                        onActivated: root.moveAudio("")
                    }
                    Repeater {
                        model: root.devices
                        delegate: ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 0
                            DeviceRow {
                                Layout.fillWidth: true
                                device: modelData
                            }
                            TakeoverConfirm {
                                Layout.fillWidth: true
                                device: modelData
                                visible: root.confirmSink === modelData.sink_name
                            }
                        }
                    }
                }
            }
            Item {
                // Keeps the accordion at the bottom while the service message is shown.
                Layout.fillHeight: true
                visible: !outputScroll.visible && !root.showAllEvents
            }

            EventsAccordion {
                Layout.fillWidth: true
                Layout.fillHeight: root.showAllEvents
                visible: root.events.length > 0 && root.connected
            }
        }
    }

    // Explains why there is nothing else to see (service off, crashed, starting, no devices).
    component ServiceMessage: PlasmaExtras.PlaceholderMessage {
        readonly property bool show: !root.serviceOn || root.autoRestarting || !root.connected
            || root.devices.length === 0
        visible: show
        iconName: root.unitActive === "failed" || root.autoRestarting ? "dialog-error"
            : !root.serviceOn ? "audio-speakers-symbolic"
            : !root.connected ? "network-connect"
            : "edit-find"
        text: {
            if (root.autoRestarting)
                return i18n("sound-cast stopped unexpectedly");
            if (root.unitActive === "failed")
                return i18n("sound-cast stopped with an error");
            if (!root.serviceOn)
                return root.pendingAction === "start" ? i18n("Starting sound-cast…") : i18n("sound-cast is off");
            if (!root.connected)
                return root.unitActive === "activating" ? i18n("Looking for Chromecasts…") : i18n("Connecting to sound-cast…");
            return i18n("No Chromecast found");
        }
        explanation: {
            if (root.autoRestarting)
                return i18np("systemd restarts it in a few seconds (restart %1).", "systemd restarts it in a few seconds (restart %1).", root.unitRestarts + 1);
            if (root.unitActive === "failed")
                return i18n("See the log with: journalctl --user -u %1", root.unit);
            if (!root.serviceOn)
                return i18n("Turn it on to use the Chromecasts on this network as audio outputs.");
            if (root.unitActive === "activating")
                return "";
            if (!root.connected)
                return i18n("If this takes long, sound-cast may be using another port (see the widget settings).");
            return i18n("sound-cast keeps looking. The PC must be on the same network as the Chromecasts.");
        }
        helpfulAction: root.unitActive === "failed" || (!root.serviceOn && root.pendingAction === "") ? startAction : null
        Kirigami.Action {
            id: startAction
            icon.name: "media-playback-start"
            text: root.unitActive === "failed" ? i18n("Try again") : i18n("Start sound-cast")
            onTriggered: root.setService(true)
        }
    }

    // The active stream: what plays where, the pipeline steps, the running timer, health.
    component StreamCard: Rectangle {
        id: card
        readonly property var dev: root.activeDevice
        readonly property var stream: root.connected ? root.pstatus.stream : null
        implicitHeight: cardLayout.implicitHeight + 2 * Kirigami.Units.largeSpacing
        radius: Kirigami.Units.cornerRadius
        color: Qt.alpha(dev ? root.phaseColor(dev.phase) : Kirigami.Theme.textColor, 0.08)
        border.color: Qt.alpha(dev ? root.phaseColor(dev.phase) : Kirigami.Theme.textColor, 0.35)
        border.width: 1

        ColumnLayout {
            id: cardLayout
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Icon {
                    source: root.castIcon
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    color: card.dev ? root.phaseColor(card.dev.phase) : Kirigami.Theme.textColor
                    isMask: true
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Kirigami.Heading {
                        level: 4
                        Layout.fillWidth: true
                        text: card.dev ? card.dev.friendly_name : ""
                        elide: Text.ElideRight
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: card.stream && card.stream.source_app ? i18n("Audio from %1", card.stream.source_app) : ""
                        font: Kirigami.Theme.smallFont
                        opacity: 0.8
                        elide: Text.ElideRight
                    }
                }
                PlasmaComponents3.ToolButton {
                    icon.name: "computer-symbolic"
                    text: i18n("Back to PC")
                    display: PlasmaComponents3.AbstractButton.TextBesideIcon
                    onClicked: root.moveAudio("")
                    PlasmaComponents3.ToolTip.text: i18n("Play the audio on this computer again")
                    PlasmaComponents3.ToolTip.visible: hovered
                }
            }

            PipelineStepper {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                phase: card.dev ? card.dev.phase : ""
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: card.dev ? root.phaseDetail(card.dev) : ""
                color: card.dev ? root.phaseColor(card.dev.phase) : Kirigami.Theme.textColor
                wrapMode: Text.Wrap
            }
            PlasmaComponents3.ProgressBar {
                Layout.fillWidth: true
                visible: card.dev !== null && card.dev.deadline !== null
                from: 0
                to: 1
                value: card.dev ? root.timerFraction(card.dev) : 0
            }

            RowLayout {
                Layout.fillWidth: true
                visible: card.stream !== null && card.stream.last_segment_at !== null
                // sound-cast pushes fetch_stalled when it flips; the timestamps alone are only as
                // fresh as the last pushed snapshot, so they cannot tell a stall by themselves.
                readonly property bool stalled: card.stream !== null && card.stream.fetch_stalled === true
                readonly property real age: stalled && card.stream.last_segment_at ? root.serverNow() - card.stream.last_segment_at : 0
                Kirigami.Icon {
                    source: parent.stalled ? "dialog-warning-symbolic" : "network-transmit-receive-symbolic"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    font: Kirigami.Theme.smallFont
                    text: parent.stalled
                        ? i18n("The Chromecast stopped fetching audio %1 s ago", Math.round(parent.age))
                        : i18n("Audio flowing to the Chromecast")
                    color: parent.stalled ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
                    opacity: parent.stalled ? 1 : 0.7
                    elide: Text.ElideRight
                }
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: card.dev !== null && card.dev.buffering_last_minute > 1
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.neutralTextColor
                wrapMode: Text.Wrap
                // From 8 a minute it is the loop a Chromecast falls into and only leaves
                // after a power cycle (sound-cast logs it as a buffering loop), not the Wi-Fi.
                text: !card.dev ? ""
                    : card.dev.buffering_last_minute >= 8
                    ? i18n("Buffered %1 times in the last minute: the Chromecast seems stuck, unplug it and plug it back in", card.dev.buffering_last_minute)
                    : i18np("Buffered %1 time in the last minute: weak Wi-Fi signal?",
                        "Buffered %1 times in the last minute: weak Wi-Fi signal?", card.dev.buffering_last_minute)
            }
        }
    }

    // Connect → Encoder → Prepare → Load → Play
    component PipelineStepper: RowLayout {
        id: stepper
        property string phase
        readonly property var steps: [i18n("Connect"), i18n("Encoder"), i18n("Prepare"), i18n("Load"), i18n("Play")]
        readonly property int current: {
            switch (phase) {
            case "connecting": return 0;
            case "encoder": return 1;
            case "subscribing":
            case "quitting_app":
            case "busy": return 2;
            case "loading": return 3;
            case "restarting": return -1;
            default: return 4;
            }
        }
        readonly property bool done: current === 4 && phase === "playing"
        spacing: 0

        Repeater {
            model: stepper.steps.length
            delegate: RowLayout {
                id: step
                required property int index
                readonly property bool passed: stepper.current >= 0 && index < stepper.current || (index === 4 && stepper.done)
                readonly property bool here: index === stepper.current && !stepper.done
                Layout.fillWidth: index > 0
                spacing: 0

                Rectangle {
                    // line from the previous step
                    visible: step.index > 0
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: Kirigami.Units.iconSizes.small / 2
                    implicitHeight: 2
                    color: step.passed || step.here ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
                    opacity: step.passed || step.here ? 1 : 0.4
                }
                ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing / 2
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        implicitWidth: Kirigami.Units.iconSizes.small
                        implicitHeight: implicitWidth
                        radius: width / 2
                        color: step.passed ? (step.index === 4 ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.highlightColor)
                            : step.here ? Kirigami.Theme.backgroundColor : "transparent"
                        border.width: 2
                        border.color: step.here ? root.phaseColor(stepper.phase)
                            : step.passed ? color : Qt.alpha(Kirigami.Theme.disabledTextColor, 0.6)
                        Kirigami.Icon {
                            anchors.centerIn: parent
                            width: parent.width - 4
                            height: width
                            visible: step.passed
                            source: "checkmark-symbolic"
                            color: Kirigami.Theme.highlightedTextColor
                            isMask: true
                        }
                        SequentialAnimation on scale {
                            running: step.here
                            loops: Animation.Infinite
                            alwaysRunToEnd: true
                            NumberAnimation { to: 1.25; duration: 500; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 1; duration: 500; easing.type: Easing.InOutQuad }
                        }
                    }
                    PlasmaComponents3.Label {
                        Layout.alignment: Qt.AlignHCenter
                        text: stepper.steps[step.index]
                        font: Kirigami.Theme.smallFont
                        opacity: step.passed || step.here ? 1 : 0.5
                    }
                }
            }
        }
    }

    component SectionTitle: RowLayout {
        property alias text: titleLabel.text
        Layout.topMargin: Kirigami.Units.smallSpacing
        Layout.leftMargin: Kirigami.Units.smallSpacing
        PlasmaComponents3.Label {
            id: titleLabel
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            font.weight: Font.DemiBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 1.2
            opacity: 0.6
        }
        Item {
            Layout.fillWidth: true
        }
    }

    // Rounded, slightly tinted box that groups rows.
    component Card: Rectangle {
        default property alias content: cardColumn.data
        implicitHeight: cardColumn.implicitHeight + 2 * Kirigami.Units.smallSpacing
        radius: Kirigami.Units.cornerRadius * 2
        color: Qt.alpha(Kirigami.Theme.textColor, 0.04)
        border.color: Qt.alpha(Kirigami.Theme.textColor, 0.09)
        border.width: 1
        ColumnLayout {
            id: cardColumn
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: 0
        }
    }

    // A selectable output, like the rows of the desktop audio applet.
    component OutputRow: Item {
        id: orow
        property string iconSource
        property color iconColor: Kirigami.Theme.textColor
        property string title
        property bool strong: selected
        property string subtitle
        property color subtitleColor: Kirigami.Theme.disabledTextColor
        property bool selected: false
        property bool pending: false
        property bool selectable: true
        property real timerValue: -1      // 0..1 shows a timer bar
        property string tooltip
        signal activated()

        implicitHeight: rowContent.implicitHeight + 2 * Kirigami.Units.smallSpacing
        opacity: selectable || selected ? 1 : 0.6

        Rectangle {
            anchors.fill: parent
            radius: Kirigami.Units.cornerRadius
            color: orow.selected ? Qt.alpha(Kirigami.Theme.highlightColor, 0.16)
                : hover.containsMouse && orow.selectable ? Qt.alpha(Kirigami.Theme.highlightColor, 0.08) : "transparent"
            Behavior on color {
                ColorAnimation { duration: Kirigami.Units.shortDuration }
            }
        }
        Rectangle {
            // accent bar on the selected output
            visible: orow.selected
            width: 3
            radius: 1.5
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: Kirigami.Units.smallSpacing
            anchors.bottomMargin: Kirigami.Units.smallSpacing
            color: Kirigami.Theme.highlightColor
        }
        MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            enabled: orow.selectable
            cursorShape: Qt.PointingHandCursor
            onClicked: orow.activated()
        }
        RowLayout {
            id: rowContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Kirigami.Units.largeSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Icon {
                source: orow.iconSource
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                color: orow.iconColor
                isMask: true
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: orow.title
                    font.weight: orow.strong ? Font.DemiBold : Font.Normal
                    elide: Text.ElideRight
                }
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: orow.subtitle
                    font: Kirigami.Theme.smallFont
                    color: orow.subtitleColor
                    elide: Text.ElideRight
                }
                PlasmaComponents3.ProgressBar {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.smallSpacing
                    visible: orow.timerValue >= 0
                    from: 0
                    to: 1
                    value: Math.max(0, orow.timerValue)
                }
            }
            PlasmaComponents3.BusyIndicator {
                visible: orow.pending
                running: visible
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            }
            Kirigami.Icon {
                visible: orow.selected && !orow.pending
                source: "checkmark-symbolic"
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                color: Kirigami.Theme.highlightColor
                isMask: true
            }
        }
        PlasmaComponents3.ToolTip {
            text: orow.tooltip
            visible: hover.containsMouse && orow.tooltip !== "" && !orow.selected
        }
    }

    component DeviceRow: OutputRow {
        id: row
        property var device
        readonly property bool isActive: root.activeDevice !== null && root.activeDevice.sink_name === device.sink_name
        readonly property bool isDefault: root.defaultSink === device.sink_name

        iconSource: root.castIcon
        iconColor: isActive || (device.phase !== "ready" && device.phase !== "unavailable") ? root.phaseColor(device.phase)
            : device.phase === "unavailable" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
        title: device.friendly_name
        selected: isDefault || isActive
        pending: root.isPendingTarget(device.sink_name)
        selectable: device.phase !== "unavailable"
        subtitle: {
            if (pending)
                return i18n("Switching…");
            if (isActive)
                return root.transitional(device.phase) ? root.phaseDetail(device) : root.phaseLabel(device.phase);
            if (device.phase !== "ready")
                return root.phaseDetail(device);
            if (device.busy_with)
                return i18n("In use: %1", device.busy_with);
            if (isDefault)
                return i18n("Selected, starts when audio plays");
            return "";
        }
        subtitleColor: pending ? Kirigami.Theme.highlightColor
            : device.phase === "ready" && device.busy_with && !isActive ? Kirigami.Theme.neutralTextColor
            : isDefault && device.phase === "ready" ? Kirigami.Theme.highlightColor : root.phaseColor(device.phase)
        timerValue: !isActive && device.deadline !== null ? root.timerFraction(device) : -1
        tooltip: i18n("Play the audio on %1", device.friendly_name)
        onActivated: root.chooseDevice(device)
    }

    // Inline confirmation under a device another app is playing on.
    component TakeoverConfirm: RowLayout {
        id: confirm
        property var device
        readonly property bool waiting: device.phase === "busy"
        // With --takeover idle, choosing the device can also wait for the other app to end.
        readonly property bool canWait: !waiting && root.pstatus !== null && root.pstatus.takeover === "idle"
        spacing: Kirigami.Units.smallSpacing
        Layout.leftMargin: Kirigami.Units.largeSpacing + Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.smallSpacing
        Layout.bottomMargin: Kirigami.Units.smallSpacing

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            text: i18n("Stop %1?", confirm.device.busy_with || confirm.device.reason || i18n("the other app"))
            font: Kirigami.Theme.smallFont
            wrapMode: Text.Wrap
        }
        PlasmaComponents3.Button {
            text: i18n("Interrupt")
            icon.name: "media-playback-stop-symbolic"
            onClicked: root.confirmDevice(confirm.device, true)
        }
        PlasmaComponents3.Button {
            visible: confirm.canWait
            text: i18n("Wait")
            onClicked: root.confirmDevice(confirm.device, false)
        }
        PlasmaComponents3.ToolButton {
            icon.name: "dialog-cancel-symbolic"
            display: PlasmaComponents3.AbstractButton.IconOnly
            text: i18n("Cancel")
            onClicked: root.confirmSink = ""
            PlasmaComponents3.ToolTip.visible: hovered
            PlasmaComponents3.ToolTip.text: text
        }
    }

    // Event log, pinned to the bottom of the popup. The header (grab handle, title, count,
    // chevron) opens and closes it; open, it fills the space of the output list.
    component EventsAccordion: Rectangle {
        id: acc
        readonly property bool open: root.showAllEvents
        readonly property bool canOpen: root.events.length > root.collapsedEvents
        implicitHeight: accColumn.implicitHeight + 2 * Kirigami.Units.smallSpacing
        radius: Kirigami.Units.cornerRadius * 2
        color: Qt.alpha(Kirigami.Theme.textColor, 0.04)
        border.color: Qt.alpha(Kirigami.Theme.textColor, accHeader.containsMouse && acc.canOpen ? 0.2 : 0.09)
        border.width: 1

        ColumnLayout {
            id: accColumn
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: 0

            MouseArea {
                id: accHeader
                Layout.fillWidth: true
                implicitHeight: headerColumn.implicitHeight
                enabled: acc.canOpen
                hoverEnabled: true
                cursorShape: acc.canOpen ? Qt.PointingHandCursor : Qt.ArrowCursor
                activeFocusOnTab: acc.canOpen
                onClicked: root.showAllEvents = !root.showAllEvents
                Keys.onSpacePressed: root.showAllEvents = !root.showAllEvents
                Keys.onReturnPressed: root.showAllEvents = !root.showAllEvents
                Accessible.role: Accessible.Button
                Accessible.name: acc.open ? i18n("Show fewer events") : i18n("Show all events")
                PlasmaComponents3.ToolTip.visible: containsMouse && acc.canOpen
                PlasmaComponents3.ToolTip.text: Accessible.name
                PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay

                Rectangle {
                    anchors.fill: parent
                    radius: Kirigami.Units.cornerRadius
                    color: Kirigami.Theme.highlightColor
                    opacity: accHeader.pressed ? 0.2 : accHeader.containsMouse || accHeader.activeFocus ? 0.1 : 0
                    Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
                }

                ColumnLayout {
                    id: headerColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: 0

                    // Grab handle: hints that the panel slides up and down.
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: Kirigami.Units.smallSpacing / 2
                        visible: acc.canOpen
                        implicitWidth: Kirigami.Units.gridUnit * 2
                        implicitHeight: 3
                        radius: height / 2
                        color: Kirigami.Theme.textColor
                        opacity: accHeader.containsMouse ? 0.45 : 0.2
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.margins: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.smallSpacing
                        PlasmaComponents3.Label {
                            text: i18n("Recent events")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            font.weight: Font.DemiBold
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 1.2
                            opacity: 0.6
                        }
                        // Count badge
                        Rectangle {
                            visible: acc.canOpen
                            implicitWidth: Math.max(implicitHeight, countLabel.implicitWidth + Kirigami.Units.smallSpacing * 2)
                            implicitHeight: countLabel.implicitHeight
                            radius: height / 2
                            color: Qt.alpha(Kirigami.Theme.textColor, 0.1)
                            PlasmaComponents3.Label {
                                id: countLabel
                                anchors.centerIn: parent
                                text: root.events.length
                                font: Kirigami.Theme.smallFont
                                opacity: 0.8
                            }
                        }
                        Item {
                            Layout.fillWidth: true
                        }
                        Kirigami.Icon {
                            visible: acc.canOpen
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            source: "arrow-up-symbolic"
                            isMask: true
                            color: Kirigami.Theme.textColor
                            opacity: accHeader.containsMouse ? 1 : 0.6
                            rotation: acc.open ? 180 : 0
                            Behavior on rotation { RotationAnimation { duration: Kirigami.Units.longDuration; easing.type: Easing.InOutQuad } }
                        }
                    }
                }
            }

            PlasmaComponents3.ScrollView {
                id: eventScroll
                Layout.fillWidth: true
                Layout.fillHeight: acc.open
                Layout.preferredHeight: acc.open ? -1 : eventColumn.implicitHeight
                PlasmaComponents3.ScrollBar.horizontal.policy: PlasmaComponents3.ScrollBar.AlwaysOff
                PlasmaComponents3.ScrollBar.vertical.policy: acc.open ? PlasmaComponents3.ScrollBar.AsNeeded : PlasmaComponents3.ScrollBar.AlwaysOff
                contentWidth: availableWidth
                clip: true

                ColumnLayout {
                    id: eventColumn
                    width: eventScroll.availableWidth
                    spacing: 0
                    Repeater {
                        model: root.connected ? root.events.slice(acc.open ? -50 : -root.collapsedEvents).reverse() : []
                        delegate: EventRow {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.margins: Kirigami.Units.smallSpacing
                            event: modelData
                        }
                    }
                }
            }
        }
    }

    component EventRow: RowLayout {
        id: evRow
        property var event
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            source: evRow.event.level === "error" ? "dialog-error-symbolic"
                : evRow.event.level === "warning" ? "dialog-warning-symbolic" : "dialog-information-symbolic"
            color: evRow.event.level === "error" ? Kirigami.Theme.negativeTextColor
                : evRow.event.level === "warning" ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.disabledTextColor
            isMask: true
        }
        PlasmaComponents3.Label {
            Layout.alignment: Qt.AlignTop
            text: Qt.formatTime(new Date(evRow.event.ts * 1000), "hh:mm:ss")
            font: Kirigami.Theme.smallFont
            opacity: 0.6
        }
        PlasmaComponents3.Label {
            Layout.fillWidth: true
            text: evRow.event.sink_name ? i18n("%1: %2", root.deviceName(evRow.event.sink_name), root.eventText(evRow.event))
                : root.eventText(evRow.event)
            font: Kirigami.Theme.smallFont
            wrapMode: Text.Wrap
        }
    }
}
