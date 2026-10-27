import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

// Встроенная консоль отладки (по прямому запросу пользователя): панель
// внизу окна, сворачивается в одну строку. Показывает общий буфер
// logConsole (C++ LogConsole — перехватывает qDebug/qWarning и ошибки
// QML), текст можно выделять и копировать — пользователь присылает вывод
// разработчику, не запуская консоль отдельно.
Rectangle {
    id: root

    Theme { id: theme }

    property bool expanded: false
    readonly property int headerHeight: Math.round(30 * theme.scale)
    implicitHeight: expanded ? Math.round(190 * theme.scale) : headerHeight

    color: theme.panel
    border.color: theme.panelBorder
    border.width: 1
    radius: 6
    clip: true

    function scrollToEnd() {
        if (!expanded)
            return
        var f = logScroll.contentItem
        if (f)
            f.contentY = Math.max(0, f.contentHeight - f.height)
    }

    onExpandedChanged: if (expanded) Qt.callLater(scrollToEnd)

    // -- Заголовок: переключение, последняя строка, копирование --
    Rectangle {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: root.headerHeight
        color: "transparent"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: theme.spacingSm
            anchors.rightMargin: theme.spacingXs
            spacing: theme.spacingXs

            Button {
                text: root.expanded ? "▼ Консоль" : "▲ Консоль"
                flat: true
                onClicked: root.expanded = !root.expanded
            }
            Label {
                Layout.fillWidth: true
                elide: Text.ElideRight
                color: theme.textSecondary
                font.pixelSize: theme.fontFootnote
                text: {
                    var t = logConsole.text
                    if (!t) return "нет сообщений"
                    var lines = t.split("\n")
                    return lines[lines.length - 1]
                }
            }
            Button {
                text: "Выделить всё"
                onClicked: logArea.selectAll()
            }
            Button {
                text: "Копировать"
                // Копируем выделение, а если ничего не выделено — весь лог.
                onClicked: {
                    if (logArea.selectedText.length === 0)
                        logArea.selectAll()
                    logArea.copy()
                }
            }
        }
    }

    ScrollView {
        id: logScroll
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        anchors.margins: theme.spacingXs
        visible: root.expanded
        clip: true

        TextArea {
            id: logArea
            readOnly: true
            selectByMouse: true
            wrapMode: TextArea.Wrap
            color: theme.textPrimary
            font.family: "Consolas"
            font.pixelSize: theme.fontFootnote
            text: logConsole.text
            background: null
            onTextChanged: Qt.callLater(root.scrollToEnd)
        }
    }
}
