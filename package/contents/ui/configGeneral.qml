import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_unitName: unitField.text
    property alias cfg_notifications: notificationsBox.checked

    Kirigami.FormLayout {
        QQC2.TextField {
            id: unitField
            Kirigami.FormData.label: i18n("systemd user unit:")
        }
        QQC2.CheckBox {
            id: notificationsBox
            Kirigami.FormData.label: i18n("Notifications:")
            text: i18n("When another app takes a Chromecast, or a room fails")
        }
    }
}
