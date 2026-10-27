import QtQuick 2.15

// Палитра и размеры интерфейса KadBuffer (светлая тема, акцент —
// оранжевый). scale — общий множитель размеров.
QtObject {
    readonly property real scale: 1.0

    readonly property color background: "#FFFFFF"
    readonly property color panel: "#f7f7f7"
    readonly property color panelBorder: "#e2e2e2"
    readonly property color base: "#cdcdcd"

    readonly property color textPrimary: "#111111"
    readonly property color textSecondary: "#3b3b3b"
    readonly property color textTertiary: "#666666"

    readonly property color accent: "#E95420"
    readonly property color focus: "#335280"
    readonly property color positive: "#0e8420"
    readonly property color negative: "#c7162b"
    readonly property color warning: "#b26a00"

    readonly property color fieldBackground: "#FFFFFF"
    readonly property color fieldBorder: "#cdcdcd"
    readonly property color placeholderText: "#8a8a8a"

    readonly property bool isWindows: Qt.platform.os === "windows"
    // На Windows базовый кегль — 13 px (умножается на scale).
    readonly property int winFontSize: Math.max(9, Math.round(13 * scale))

    readonly property int fontTitle: isWindows ? winFontSize : Math.round(22 * scale)
    readonly property int fontTab: isWindows ? winFontSize : Math.round(15 * scale)
    readonly property int fontSection: isWindows ? winFontSize : Math.round(20 * scale)
    readonly property int fontBody: isWindows ? winFontSize : Math.round(16 * scale)
    readonly property int fontSmall: isWindows ? winFontSize : Math.round(14 * scale)
    readonly property int fontFootnote: isWindows ? winFontSize : Math.round(12 * scale)
    readonly property int fontTable: isWindows ? winFontSize : Math.round(11 * scale)
    readonly property int fontBig: isWindows ? winFontSize : Math.round(28 * scale)

    readonly property int fontButton: isWindows ? winFontSize : Math.round(16 * scale)
    readonly property int checkboxIndicatorSize: Math.max(12, Math.round((isWindows ? 13 : 14) * scale))

    readonly property int spacingNone: 0
    readonly property int spacing1: Math.round(1 * scale)
    readonly property int spacing2: Math.round(2 * scale)
    readonly property int spacing3: Math.round(3 * scale)
    readonly property int spacingXs: Math.round(4 * scale)
    readonly property int spacingSm: Math.round(6 * scale)
    readonly property int spacingMd: Math.round(8 * scale)
    readonly property int spacing10: Math.round(10 * scale)
    readonly property int spacing12: Math.round(12 * scale)
    readonly property int spacingLg: Math.round(16 * scale)
}
