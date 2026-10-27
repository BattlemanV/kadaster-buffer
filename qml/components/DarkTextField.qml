import QtQuick 2.15

// Обычное текстовое поле (имя файла историческое, палитра светлая).
Rectangle {
    id: root
    implicitWidth: 120
    implicitHeight: 44
    radius: 4
    color: theme.fieldBackground
    border.width: 1
    border.color: input.activeFocus ? theme.focus : theme.fieldBorder

    Theme { id: theme }

    property alias text: input.text
    property alias placeholderText: placeholder.text
    property alias font: input.font
    property alias horizontalAlignment: input.horizontalAlignment
    property bool isPassword: false
    property int extraInputHints: 0

    signal accepted()
    signal editingFinished()

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignLeft
        font.pixelSize: theme.fontBody
        color: theme.textPrimary
        selectByMouse: true
        clip: true
        echoMode: root.isPassword ? TextInput.Password : TextInput.Normal
        inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase | root.extraInputHints
        onAccepted: root.accepted()
        onEditingFinished: root.editingFinished()
    }

    Text {
        id: placeholder
        anchors.fill: input
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: input.horizontalAlignment
        font: input.font
        color: theme.placeholderText
        visible: input.text.length === 0 && !input.activeFocus
    }

    // Правый клик — контекстное меню (принимает только правую кнопку,
    // поэтому левые клики/выделение проходят к TextInput ниже).
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: inputMenu.popup()
    }
    EditContextMenu {
        id: inputMenu
        target: input
    }
}
