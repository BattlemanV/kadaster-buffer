import QtQuick 2.15
import QtQuick.Controls 2.15

// Контекстное меню текстового поля: Вырезать / Копировать / Вставить /
// Выделить всё. target — TextField (QtQuick.Controls) или TextInput
// (внутри DarkTextField / NumericField), у обоих есть selectedText и
// методы cut()/copy()/paste()/selectAll(). Вынесено отдельным
// компонентом, чтобы одинаковое меню было у всех полей, а не только у
// двух полей поиска (координаты/кадастр).
Menu {
    id: root
    property var target: null

    MenuItem {
        text: "Вырезать"
        enabled: root.target !== null && root.target.selectedText.length > 0
        onTriggered: { if (root.target) root.target.cut() }
    }
    MenuItem {
        text: "Копировать"
        enabled: root.target !== null && root.target.selectedText.length > 0
        onTriggered: { if (root.target) root.target.copy() }
    }
    MenuItem {
        text: "Вставить"
        enabled: root.target !== null
        onTriggered: { if (root.target) root.target.paste() }
    }
    MenuItem {
        text: "Выделить всё"
        enabled: root.target !== null
        onTriggered: { if (root.target) root.target.selectAll() }
    }
}
