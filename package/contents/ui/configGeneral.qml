import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_unitName: unitField.text

    Kirigami.FormLayout {
        QQC2.TextField {
            id: unitField
            Kirigami.FormData.label: i18n("systemd user unit:")
        }
    }
}
