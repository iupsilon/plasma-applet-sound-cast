/*
 * sound-cast status widget.
 *
 * Service state comes from systemd over D-Bus (property change signals), the default
 * output from the Plasma audio module, the rest from sound-cast's own D-Bus object
 * (org.soundcast.Daemon1: Status and Events properties): the rooms with their phases
 * and timers, and an event log. Nothing is polled: shell commands run only for user
 * actions. The streams of the apps come from the Plasma audio module too, so each one
 * can be sent to its own room; warnings and errors also show as notifications.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.private.volume as PA
import org.kde.plasma.workspace.dbus as DBus
import org.kde.kirigami as Kirigami
import org.kde.notification

PlasmoidItem {
    id: root

    // -- state -------------------------------------------------------------------------

    readonly property string unit: Plasmoid.configuration.unitName || "sound-cast"
    // The TCP port the Chromecasts fetch the audio from, as sound-cast reports it.
    readonly property int port: pstatus ? pstatus.port : 8574

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
    // The colour logo, from the package: a theme may not have it under this name.
    readonly property string logoIcon: Qt.resolvedUrl("../icons/sound-cast.svg")

    // sound-cast's Status and Events properties, parsed; null while it does not answer
    readonly property var pstatus: daemonWatcher.registered ? parseJson(propString(daemonProps.properties.Status)) : null
    readonly property var events: daemonWatcher.registered ? (parseJson(propString(daemonProps.properties.Events)) || []) : []
    property real clockOffset: 0            // server time - local time
    property real now: Date.now() / 1000
    property bool showAllEvents: false
    property string confirmSink: ""         // busy device waiting for "interrupt?" confirmation

    readonly property bool serviceOn: unitActive === "active" || unitActive === "activating" || unitActive === "reloading"
    readonly property bool autoRestarting: unitActive === "activating" && unitSub === "auto-restart"
    readonly property bool connected: pstatus !== null
    // Volume, mute and rescan came with the Version property (0.2.0). Read again
    // with every status: a key that appears in the properties map later does not
    // update a binding that read it while it was missing.
    property bool hasVersion: false
    readonly property bool controls: connected && hasVersion
    readonly property var devices: connected ? sortedDevices(pstatus.devices.map(normalized)) : []
    // Rooms with a Cast session open or being retried; several can play at once.
    readonly property var activeDevices: devices.filter(d => isActive(d))
    readonly property var activeDevice: activeDevices.length > 0 ? activeDevices[0] : null
    // Rooms that get a card: those with audio, plus the selected output even while it is
    // silent. A room the audio left only waits out its grace period: it stays in the list.
    readonly property var cardDevices: activeDevices.filter(d => hasCard(d))
    // A sound-cast device chosen as output (by the widget or the desktop mixer); it streams
    // only while something plays.
    readonly property var selectedDevice: defaultSink.startsWith("sound-cast.") ? (devices.find(d => d.sink_name === defaultSink) || null) : null
    readonly property bool busy: pendingAction !== "" || pendingSink !== "" || unitActive === "activating" || unitActive === "deactivating"
        || activeDevices.some(d => transitional(d.phase))

    onPstatusChanged: {
        hasVersion = daemonProps.properties.Version !== undefined;
        if (pstatus)
            clockOffset = pstatus.now - Date.now() / 1000;
    }

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

    function parseJson(text) {
        if (!text)
            return null;
        try {
            return JSON.parse(text);
        } catch (e) {
            return null;
        }
    }

    // A room whose device left the network shows as unavailable until its sink goes.
    function normalized(d) {
        if (d.lost_until === null || d.phase !== "ready")
            return d;
        return Object.assign({}, d, { phase: "unavailable", reason: "lost", since: d.since, deadline: d.lost_until });
    }

    function hasCard(d) {
        return isActive(d) && (d.phase !== "lingering" || d.sink_name === defaultSink);
    }

    function isActive(d) {
        return !["ready", "unavailable", "busy"].includes(d.phase);
    }

    function serverNow() {
        return now + clockOffset;
    }

    function transitional(phase) {
        return ["connecting", "launching", "loading", "buffering", "restarting", "lingering"].includes(phase);
    }

    function sortedDevices(list) {
        const rank = d => isActive(d) ? 0 : d.phase === "unavailable" ? 2 : 1;
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
        // Phases that end by themselves carry a deadline; "since" is when they began.
        if (!dev.deadline || dev.deadline <= dev.since)
            return 0;
        return Math.min(1, Math.max(0, (dev.deadline - serverNow()) / (dev.deadline - dev.since)));
    }

    function phaseLabel(phase) {
        switch (phase) {
        case "ready": return i18n("Ready");
        case "unavailable": return i18n("Not reachable");
        case "connecting": return i18n("Connecting");
        case "launching": return i18n("Starting the receiver");
        case "loading": return i18n("Loading on the Chromecast");
        case "playing": return i18n("Playing");
        case "buffering": return i18n("Buffering");
        case "paused": return i18n("Paused");
        case "lingering": return i18n("No audio");
        case "restarting": return i18n("Restarting");
        case "busy": return i18n("In use by another app");
        default: return phase;
        }
    }

    // One line telling what is happening and, when a timer runs, what happens when.
    function phaseDetail(dev) {
        const left = secondsLeft(dev);
        switch (dev.phase) {
        case "unavailable": return i18n("No longer on the network, removed in %1 s", left);
        case "connecting": return i18n("Connecting to the Chromecast…");
        case "launching": return i18n("Starting the receiver on the Chromecast…");
        case "loading": return i18n("Loading on the Chromecast… %1 s", elapsed(dev.since));
        case "paused": return i18n("Paused on the Chromecast");
        case "lingering": return i18n("No audio, stops in %1 s", left);
        case "restarting":
            return left > 0 ? i18n("Retrying in %1 s: %2", left, dev.reason) : i18n("Retrying…");
        case "busy":
            return dev.reason ? i18n("%1 took the Chromecast", dev.reason) : i18n("Another app took the Chromecast");
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
        case "lingering":
        case "restarting": return Kirigami.Theme.neutralTextColor;
        default: return Kirigami.Theme.highlightColor;
        }
    }

    function eventText(ev) {
        const a = ev.args || {};
        switch (ev.code) {
        case "started": return i18n("sound-cast started");
        case "found": return i18n("Found on the network");
        case "lost": return i18n("Gone from the network");
        case "back": return i18n("Back on the network");
        case "removed": return i18n("Removed: gone from the network for a minute");
        case "playing": return i18n("Playing");
        case "idle_stop": return i18n("No audio for %1 s, stopped", a.seconds);
        case "yielded": return a.app ? i18n("%1 took the Chromecast", a.app) : i18n("Another app took the Chromecast");
        case "resumed": return i18n("Taken back");
        case "stopped": return i18n("Stopped");
        case "error": return i18n("%1, retrying in %2 s", a.error, a.retry);
        case "not_fetched": return i18n("The Chromecast did not fetch the audio: is port %1/tcp open in the firewall?", a.port);
        case "rescan": return i18n("Looking for Chromecasts again");
        case "paused_on_device": return i18n("Paused on the Chromecast, the player paused too");
        case "resumed_on_device": return i18n("Resumed on the Chromecast, the player resumed too");
        case "stopped_on_device": return i18n("Stopped on the Chromecast, the player paused");
        default: return ev.code || "";
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
        // A room the audio left only waits out its grace period: it does not count.
        if (cardDevices.length > 1)
            return i18np("Playing in %1 room", "Playing in %1 rooms", cardDevices.length);
        if (cardDevices.length === 1)
            return i18n("%1: %2", cardDevices[0].friendly_name, phaseLabel(cardDevices[0].phase));
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

    // The helper ships inside the widget: plasmashell's PATH may lack ~/.local/bin, and a
    // user install (make test-install) has no /usr/bin copy.
    readonly property string moveHelper: decodeURIComponent(Qt.resolvedUrl("../code/sound-cast-move").toString().replace("file://", ""))

    function moveAudio(sinkName) {
        // sink names are [a-z0-9_.] (sound-cast makes them), safe for the shell
        pendingSink = sinkName || "local";
        pendingSinkTimeout.restart();
        exec.run(`bash '${moveHelper}' ${sinkName || "--local"}`, () => {});
    }

    // Moves one app's stream; the default output and the other streams stay.
    function moveStream(index, sinkName) {
        // index is a number, sink names are [a-z0-9_.]: safe for the shell
        exec.run(`bash '${moveHelper}' --stream ${Number(index)} ${sinkName || "--local"}`, () => {});
    }

    // extra: further D-Bus arguments after the sink name
    function callDaemon(member, sinkName, extra) {
        const args = sinkName === undefined ? [] : [new DBus.string(sinkName)];
        DBus.SessionBus.asyncCall({
            service: "org.soundcast.Daemon",
            path: "/org/soundcast/Daemon",
            iface: "org.soundcast.Daemon1",
            member: member,
            arguments: args.concat(extra || []),
        });
    }

    // The volume of a room, 0 to 100: sound-cast sets its sink and the device.
    function setVolume(sinkName, percent) {
        callDaemon("SetVolume", sinkName, [new DBus.double(Math.max(0, Math.min(100, percent)) / 100)]);
    }

    function setMute(sinkName, muted) {
        callDaemon("SetMute", sinkName, [new DBus.bool(muted)]);
    }

    // Ask every Chromecast on the network to answer again.
    function rescan() {
        callDaemon("Rescan");
    }

    function trackText(track) {
        if (!track || !track.title)
            return "";
        return track.artist ? i18n("%1 – %2", track.artist, track.title) : track.title;
    }

    // Ask sound-cast to take a device back from the app that took it.
    function resume(sinkName) {
        callDaemon("Resume", sinkName);
    }

    // Ask sound-cast to end now a session that only waits out its grace period.
    function stopRoom(sinkName) {
        callDaemon("Stop", sinkName);
    }

    // A click on a device: confirm first when another app has it.
    function chooseDevice(dev) {
        if (dev.phase === "busy") {
            confirmSink = confirmSink === dev.sink_name ? "" : dev.sink_name;
            return;
        }
        confirmSink = "";
        moveAudio(dev.sink_name);
    }

    function confirmDevice(dev) {
        confirmSink = "";
        resume(dev.sink_name);
        if (defaultSink !== dev.sink_name)
            moveAudio(dev.sink_name);
    }

    function isPendingTarget(sinkName) {
        return pendingSink !== "" && (pendingSink === sinkName || (pendingSink === "local" && sinkName === ""));
    }

    // -- notifications -------------------------------------------------------------------

    // Events worth a notification, and how they look. Each kind shows at most once in
    // NOTIFY_EVERY seconds per room: a retry loop does not flood the desktop.
    readonly property var notifyCodes: ["yielded", "error", "not_fetched"]
    readonly property int notifyEvery: 300
    property real lastEventSeq: -1          // the newest event already looked at
    property var lastNotified: ({})         // "code sink" -> server time
    readonly property real loadedAt: Date.now() / 1000

    // The number of an event; sound-cast 0.1 has none, its time stands in.
    function eventSeq(ev) {
        return ev.seq !== undefined ? ev.seq : ev.ts;
    }

    onEventsChanged: {
        if (events.length === 0)
            return;
        const newest = eventSeq(events[events.length - 1]);
        // The events already there when the widget connects are history, not news,
        // except those after the widget started (sound-cast started from it).
        const fresh = lastEventSeq < 0
            ? events.filter(ev => ev.ts > loadedAt + clockOffset)
            : events.filter(ev => eventSeq(ev) > lastEventSeq);
        lastEventSeq = Math.max(lastEventSeq, newest);
        if (!Plasmoid.configuration.notifications)
            return;
        for (const ev of fresh) {
            if (!notifyCodes.includes(ev.code))
                continue;
            const id = ev.code + " " + (ev.sink_name || "");
            if (lastNotified[id] !== undefined && ev.ts - lastNotified[id] < notifyEvery)
                continue;
            lastNotified[id] = ev.ts;
            notify(ev);
        }
    }

    // A new daemon process starts a new event log.
    onConnectedChanged: if (!connected)
        lastEventSeq = -1

    function notify(ev) {
        const n = notificationComponent.createObject(root, {
            title: ev.sink_name ? root.deviceName(ev.sink_name) : "sound-cast",
            text: root.eventText(ev),
            // High urgency would stay on screen until closed, also in Do Not Disturb.
            urgency: Notification.NormalUrgency,
            sinkName: ev.sink_name || "",
            canTakeBack: ev.code === "yielded" && !!ev.sink_name,
        });
        n.sendEvent();
    }

    Component {
        id: notificationComponent
        Notification {
            id: notification
            property string sinkName
            property bool canTakeBack: false
            property NotificationAction takeBack: NotificationAction {
                label: i18n("Take back")
                onActivated: root.resume(notification.sinkName)
            }
            componentName: "plasma_workspace"
            eventId: "notification"
            iconName: "sound-cast-symbolic"
            autoDelete: true
            actions: canTakeBack ? [takeBack] : []
        }
    }

    onDefaultSinkChanged: {
        if (pendingSink !== "" && (pendingSink === defaultSink || (pendingSink === "local" && !defaultSink.startsWith("sound-cast."))))
            pendingSink = "";
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

    // sound-cast's own state: read once, then updated by PropertiesChanged.
    DBus.Properties {
        id: daemonProps
        busType: DBus.BusType.Session
        service: "org.soundcast.Daemon"
        path: "/org/soundcast/Daemon"
        iface: "org.soundcast.Daemon1"
    }
    DBus.DBusServiceWatcher {
        id: daemonWatcher
        busType: DBus.BusType.Session
        watchedService: "org.soundcast.Daemon"
        // A new daemon process starts with a new state.
        onRegisteredChanged: if (registered)
            daemonProps.updateAll()
    }

    // The apps' playback streams, and the sink names by index to tell where each plays.
    PA.PulseObjectFilterModel {
        id: appStreams
        filters: [{ role: "VirtualStream", value: false }]
        sourceModel: PA.SinkInputModel {}
    }
    property var sinkNames: ({})            // sink index -> sink name
    Instantiator {
        id: sinkList
        model: PA.SinkModel {}
        delegate: QtObject {
            required property var model
            readonly property int sinkIndex: model.PulseObject ? model.PulseObject.index : -1
            readonly property string sinkName: model.PulseObject ? model.PulseObject.name : ""
        }
        onObjectAdded: root.updateSinkNames()
        onObjectRemoved: root.updateSinkNames()
    }
    function updateSinkNames() {
        const names = {};
        for (let i = 0; i < sinkList.count; i++) {
            const o = sinkList.objectAt(i);
            if (o)
                names[o.sinkIndex] = o.sinkName;
        }
        sinkNames = names;
    }

    Timer {
        // give up showing "switching" if the default output never changes
        id: pendingSinkTimeout
        interval: 6000
        onTriggered: root.pendingSink = ""
    }

    Timer {
        // countdowns
        interval: 250
        repeat: true
        running: root.expanded || root.busy
        onTriggered: root.now = Date.now() / 1000
    }

    onExpandedChanged: if (!root.expanded) {
        showAllEvents = false;
        confirmSink = "";
    }

    Plasmoid.icon: logoIcon
    Plasmoid.status: unitActive === "failed" || autoRestarting || activeDevices.length > 0
        ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus
    toolTipMainText: "sound-cast"
    toolTipSubText: summary()

    // sound-cast logs to the journal. setsid detaches the terminal from the command timeout.
    function openLog() {
        exec.run(`setsid -f konsole -e journalctl --user -f -u ${unit}`, () => {});
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
            source: root.logoIcon
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
                        PlasmaComponents3.MenuItem {
                            text: i18n("Look for Chromecasts again")
                            icon.name: "view-refresh-symbolic"
                            enabled: root.controls
                            onTriggered: root.rescan()
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

            Repeater {
                model: root.cardDevices
                delegate: StreamCard {
                    required property var modelData
                    Layout.fillWidth: true
                    dev: modelData
                }
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

                ColumnLayout {
                width: outputScroll.availableWidth
                spacing: Kirigami.Units.largeSpacing
                Card {
                    Layout.fillWidth: true
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

                // Each app's stream on its own output: one app in a room, the rest here.
                SectionTitle {
                    Layout.fillWidth: true
                    visible: appsCard.visible
                    text: i18n("Apps")
                }
                Card {
                    id: appsCard
                    Layout.fillWidth: true
                    visible: appStreams.count > 0 && root.devices.some(d => d.phase !== "unavailable")
                    Repeater {
                        model: appStreams
                        delegate: AppRow {
                            required property var model
                            Layout.fillWidth: true
                            stream: model.PulseObject
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
                return i18n("If this takes long, see the log with: journalctl --user -u %1", root.unit);
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

    // A room with a Cast session: the device, the pipeline steps, the running timer, health.
    component StreamCard: Rectangle {
        id: card
        property var dev: null
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
                        // What plays, as the app's media player tells it.
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: card.dev ? root.trackText(card.dev.track) : ""
                        font: Kirigami.Theme.smallFont
                        opacity: 0.8
                        elide: Text.ElideRight
                        PlasmaComponents3.ToolTip.text: card.dev && card.dev.track
                            ? [text, card.dev.track.album, card.dev.track.identity || card.dev.track.player]
                                .filter(x => x).join("\n") : ""
                        PlasmaComponents3.ToolTip.visible: trackHover.hovered && text !== ""
                        HoverHandler { id: trackHover }
                    }
                }
                PlasmaComponents3.ToolButton {
                    // Only the default output can be moved back; other rooms play their own sink.
                    visible: card.dev !== null && root.defaultSink === card.dev.sink_name
                    icon.name: "computer-symbolic"
                    text: i18n("Back to PC")
                    display: PlasmaComponents3.AbstractButton.TextBesideIcon
                    onClicked: root.moveAudio("")
                    PlasmaComponents3.ToolTip.text: i18n("Play the audio on this computer again")
                    PlasmaComponents3.ToolTip.visible: hovered
                }
            }

            RowLayout {
                // The room's volume: sound-cast sets it on its sink and on the device.
                Layout.fillWidth: true
                visible: root.controls && card.dev !== null && card.dev.volume !== null
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents3.ToolButton {
                    readonly property bool muted: card.dev !== null && card.dev.muted
                    icon.name: muted ? "audio-volume-muted-symbolic"
                        : volumeSlider.value < 34 ? "audio-volume-low-symbolic"
                        : volumeSlider.value < 67 ? "audio-volume-medium-symbolic" : "audio-volume-high-symbolic"
                    text: muted ? i18n("Unmute") : i18n("Mute")
                    display: PlasmaComponents3.AbstractButton.IconOnly
                    onClicked: root.setMute(card.dev.sink_name, !muted)
                    PlasmaComponents3.ToolTip.text: text
                    PlasmaComponents3.ToolTip.visible: hovered
                }
                PlasmaComponents3.Slider {
                    id: volumeSlider
                    Layout.fillWidth: true
                    from: 0
                    to: 100
                    stepSize: 1
                    opacity: card.dev !== null && card.dev.muted ? 0.5 : 1
                    // The level sent last, until the status reports it back.
                    property int pending: -1
                    readonly property int reported: card.dev && card.dev.volume !== null ? card.dev.volume : 0
                    onReportedChanged: if (reported === pending)
                        pending = -1
                    // Follows the device, except while the user drags or a change is on its way.
                    Binding on value {
                        when: !volumeSlider.pressed && volumeSlider.pending < 0
                        value: volumeSlider.reported
                        restoreMode: Binding.RestoreNone
                    }
                    function send() {
                        if (!card.dev)
                            return;
                        pending = Math.round(value);
                        pendingTimeout.restart();
                        root.setVolume(card.dev.sink_name, pending);
                    }
                    onMoved: if (!volumeSend.running)
                        volumeSend.start()
                    onPressedChanged: if (!pressed) {
                        volumeSend.stop();
                        send();
                    }
                    Accessible.name: i18n("Volume of %1", card.dev ? card.dev.friendly_name : "")
                    Timer {
                        // at most a few changes a second reach the device while dragging
                        id: volumeSend
                        interval: 150
                        onTriggered: volumeSlider.send()
                    }
                    Timer {
                        // the device may settle elsewhere: follow it again
                        id: pendingTimeout
                        interval: 1500
                        onTriggered: volumeSlider.pending = -1
                    }
                }
                PlasmaComponents3.Label {
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                    horizontalAlignment: Text.AlignRight
                    text: card.dev !== null && card.dev.muted ? i18n("Muted") : i18n("%1%", Math.round(volumeSlider.value))
                    font: Kirigami.Theme.smallFont
                    opacity: 0.8
                }
            }

            PipelineStepper {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                // Only while the session is being set up; a playing room stays compact.
                visible: card.dev !== null && ["connecting", "launching", "loading", "restarting"].includes(card.dev.phase)
                phase: card.dev ? card.dev.phase : ""
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: !card.dev ? ""
                    : card.dev.phase === "playing" && card.dev.latency_ms
                    ? i18n("%1 · %2 ms delay", root.phaseDetail(card.dev), card.dev.latency_ms)
                    : root.phaseDetail(card.dev)
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
                visible: card.dev !== null && card.dev.phase === "loading"
                // While loading, no listener means the Chromecast cannot reach the stream port.
                readonly property bool unreached: card.dev !== null && card.dev.listeners === 0 && card.dev.phase === "loading"
                    && root.serverNow() - card.dev.since > 5
                readonly property bool flowing: card.dev !== null && card.dev.listeners > 0
                Kirigami.Icon {
                    source: parent.unreached ? "dialog-warning-symbolic" : "network-transmit-receive-symbolic"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    font: Kirigami.Theme.smallFont
                    text: parent.unreached
                        ? i18n("The Chromecast has not fetched the audio yet: is port %1/tcp open in the firewall?", root.port)
                        : parent.flowing ? i18n("The Chromecast is fetching the audio")
                        : i18n("Waiting for the Chromecast to fetch the audio")
                    color: parent.unreached ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
                    opacity: parent.unreached ? 1 : 0.7
                    wrapMode: Text.Wrap
                }
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: card.dev !== null && card.dev.buffering_last_minute > 1
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.neutralTextColor
                wrapMode: Text.Wrap
                // From 8 a minute it is the loop a Chromecast falls into and only leaves
                // after a power cycle, not the Wi-Fi.
                text: !card.dev ? ""
                    : card.dev.buffering_last_minute >= 8
                    ? i18n("Buffered %1 times in the last minute: the Chromecast seems stuck, unplug it and plug it back in", card.dev.buffering_last_minute)
                    : i18np("Buffered %1 time in the last minute: weak Wi-Fi signal?",
                        "Buffered %1 times in the last minute: weak Wi-Fi signal?", card.dev.buffering_last_minute)
            }
        }
    }

    // Connect → Start → Load → Play
    component PipelineStepper: RowLayout {
        id: stepper
        property string phase
        readonly property var steps: [i18n("Connect"), i18n("Start"), i18n("Load"), i18n("Play")]
        readonly property int last: steps.length - 1
        readonly property int current: {
            switch (phase) {
            case "connecting": return 0;
            case "launching": return 1;
            case "loading": return 2;
            case "restarting": return -1;
            default: return last;
            }
        }
        readonly property bool done: current === last && phase === "playing"
        spacing: 0

        Repeater {
            model: stepper.steps.length
            delegate: RowLayout {
                id: step
                required property int index
                readonly property bool passed: stepper.current >= 0 && index < stepper.current || (index === stepper.last && stepper.done)
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
                        color: step.passed ? (step.index === stepper.last ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.highlightColor)
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
        property string actionIcon        // a small button at the end of the row, when set
        property string actionText
        signal activated()
        signal actionTriggered()

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
            PlasmaComponents3.ToolButton {
                visible: orow.actionIcon !== ""
                icon.name: orow.actionIcon
                text: orow.actionText
                display: PlasmaComponents3.AbstractButton.IconOnly
                onClicked: orow.actionTriggered()
                PlasmaComponents3.ToolTip.text: text
                PlasmaComponents3.ToolTip.visible: hovered
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
        readonly property bool isActive: root.isActive(device)
        readonly property bool isDefault: root.defaultSink === device.sink_name

        iconSource: root.castIcon
        iconColor: isActive || (device.phase !== "ready" && device.phase !== "unavailable") ? root.phaseColor(device.phase)
            : device.phase === "unavailable" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
        title: device.friendly_name
        // The audio left this room: it plays silence until the grace period ends.
        readonly property bool leaving: device.phase === "lingering" && !isDefault
        selected: isDefault || (isActive && !leaving)
        pending: root.isPendingTarget(device.sink_name)
        selectable: device.phase !== "unavailable"
        subtitle: {
            if (pending)
                return i18n("Switching…");
            if (leaving)
                return i18n("No audio, stops in %1 s · click to play here again", root.secondsLeft(device));
            if (isActive)
                return root.transitional(device.phase) ? root.phaseDetail(device) : root.phaseLabel(device.phase);
            if (device.phase !== "ready")
                return root.phaseDetail(device);
            if (isDefault)
                return i18n("Selected, starts when audio plays");
            return "";
        }
        subtitleColor: pending ? Kirigami.Theme.highlightColor
            : isDefault && device.phase === "ready" ? Kirigami.Theme.highlightColor : root.phaseColor(device.phase)
        timerValue: !root.hasCard(device) && device.deadline !== null ? root.timerFraction(device) : -1
        tooltip: i18n("Play the audio on %1", device.friendly_name)
        actionIcon: leaving ? "media-playback-stop-symbolic" : ""
        actionText: i18n("Stop now")
        onActivated: root.chooseDevice(device)
        onActionTriggered: root.stopRoom(device.sink_name)
    }

    // An app's stream and the output it plays on, which a menu changes.
    component AppRow: RowLayout {
        id: app
        property var stream: null
        readonly property var props: stream ? stream.properties : ({})
        readonly property string appName: props["application.name"] || (stream && stream.client ? stream.client.name : "")
            || (stream ? stream.name : "")
        readonly property string sinkName: stream ? (root.sinkNames[stream.deviceIndex] || "") : ""
        // "" is this computer. Rebuilt only when the list changes, not with every
        // status update, so an open menu stays as it is.
        readonly property var currentOutputs: [{ text: i18n("This computer"), sink: "" }].concat(
            root.devices.filter(d => d.phase !== "unavailable" || d.sink_name === sinkName)
                .map(d => ({ text: d.friendly_name, sink: d.sink_name })))
        property var outputs: []
        Component.onCompleted: outputs = currentOutputs
        onCurrentOutputsChanged: if (JSON.stringify(currentOutputs) !== JSON.stringify(outputs))
            outputs = currentOutputs
        spacing: Kirigami.Units.largeSpacing
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.smallSpacing
        Layout.topMargin: Kirigami.Units.smallSpacing
        Layout.bottomMargin: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            source: app.props["application.icon_name"] || "audio-x-generic"
            fallback: "audio-x-generic"
            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: app.appName
                elide: Text.ElideRight
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: text !== "" && text !== app.appName
                text: app.stream ? app.stream.name : ""
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                elide: Text.ElideRight
            }
        }
        PlasmaComponents3.ToolButton {
            // The output it plays on; a click opens the others. (Plasma's ComboBox
            // loops on its width in a row like this one.)
            id: outputButton
            readonly property string current: app.sinkName.startsWith("sound-cast.") ? app.sinkName : ""
            readonly property var currentOutput: app.outputs.find(o => o.sink === current) || app.outputs[0]
            Layout.maximumWidth: Kirigami.Units.gridUnit * 9
            text: currentOutput ? currentOutput.text : ""
            icon.name: current ? "" : "computer-symbolic"
            icon.source: current ? root.castIcon : ""
            display: PlasmaComponents3.AbstractButton.TextBesideIcon
            down: pressed || outputMenu.opened
            // A press on the button leaves the menu open for the click to close it.
            onClicked: outputMenu.opened ? outputMenu.close()
                : outputMenu.popup(outputButton, 0, outputButton.height)
            Accessible.name: i18n("Output of %1", app.appName)
            PlasmaComponents3.ToolTip.text: Accessible.name
            PlasmaComponents3.ToolTip.visible: hovered && !outputMenu.opened

            PlasmaComponents3.Menu {
                id: outputMenu
                closePolicy: QQC2.Popup.CloseOnEscape | QQC2.Popup.CloseOnPressOutsideParent
                Instantiator {
                    model: app.outputs
                    delegate: PlasmaComponents3.MenuItem {
                        required property var modelData
                        text: modelData.text
                        checkable: true
                        checked: modelData.sink === outputButton.current
                        // The click toggled the mark: back to the output it plays on,
                        // which a move then changes.
                        onTriggered: {
                            checked = Qt.binding(() => modelData.sink === outputButton.current)
                            if (modelData.sink !== outputButton.current)
                                root.moveStream(app.stream.index, modelData.sink)
                        }
                    }
                    onObjectAdded: (index, object) => outputMenu.insertItem(index, object)
                    onObjectRemoved: (index, object) => outputMenu.removeItem(object)
                }
            }
        }
    }

    // Inline confirmation under a device another app took.
    component TakeoverConfirm: RowLayout {
        id: confirm
        property var device
        spacing: Kirigami.Units.smallSpacing
        Layout.leftMargin: Kirigami.Units.largeSpacing + Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.smallSpacing
        Layout.bottomMargin: Kirigami.Units.smallSpacing

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            text: i18n("Stop %1 and play here?", confirm.device.reason || i18n("the other app"))
            font: Kirigami.Theme.smallFont
            wrapMode: Text.Wrap
        }
        PlasmaComponents3.Button {
            text: i18n("Take back")
            icon.name: "media-playback-start-symbolic"
            onClicked: root.confirmDevice(confirm.device)
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

    // Event log, pinned to the bottom of the popup. Closed it is one line with the latest
    // event; a click opens it in the place of the output list, another closes it.
    component EventsAccordion: Rectangle {
        id: acc
        readonly property bool open: root.showAllEvents
        // Closed it is one line with the latest event; the events only serve troubleshooting.
        readonly property bool canOpen: root.events.length > 0
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
                Accessible.name: acc.open ? i18n("Hide the events") : i18n("Show all events")
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

                    // Grab handle: hints that the open panel slides back down.
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: Kirigami.Units.smallSpacing / 2
                        visible: acc.open
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
                            visible: acc.open
                            text: i18n("Recent events")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            font.weight: Font.DemiBold
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 1.2
                            opacity: 0.6
                        }
                        // Count badge
                        Rectangle {
                            visible: acc.open
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
                        EventRow {
                            visible: !acc.open && root.events.length > 0
                            Layout.fillWidth: true
                            singleLine: true
                            event: root.events.length > 0 ? root.events[root.events.length - 1] : ({})
                        }
                        Item {
                            visible: acc.open
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
                visible: acc.open
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
                        model: root.connected && acc.open ? root.events.slice(-50).reverse() : []
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
        property bool singleLine: false
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
            wrapMode: evRow.singleLine ? Text.NoWrap : Text.Wrap
            elide: evRow.singleLine ? Text.ElideRight : Text.ElideNone
        }
    }
}
