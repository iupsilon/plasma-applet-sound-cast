import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_port: portField.value
    property alias cfg_unitName: unitField.text

    Kirigami.FormLayout {
        QQC2.SpinBox {
            id: portField
            Kirigami.FormData.label: i18n("sound-cast port:")
            from: 1
            to: 65535
            textFromValue: (value) => String(value)
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.Wrap
            font: Kirigami.Theme.smallFont
            text: i18n("The Chromecasts download the audio from this computer on this port, so it must be reachable from the local network: allow it in the firewall (for example: sudo ufw allow %1/tcp). It must match the port sound-cast uses (--port, default 3000).", portField.value)
        }
        QQC2.TextField {
            id: unitField
            Kirigami.FormData.label: i18n("systemd user unit:")
        }
    }
}
