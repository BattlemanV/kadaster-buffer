import QtQuick 2.15
import QtTest 1.15
import QtPositioning 5.15

// Стенд: настоящий Main.qml с заглушками C++-объектов (контекстные
// свойства ищутся по цепочке контекстов — id этого файла их подменяют),
// вымышленными участками в формате НСПД и настоящими кликами мыши.
// НСПД не нужна. Запуск из корня проекта (Git Bash):
//   PATH="build-release:/c/Qt/5.15.2/mingw81_64/bin:$PATH" //     qmltestrunner.exe -input tools/qmltest/tst_main.qml
// Правка в qml/ проверяется стендом БЕЗ пересборки (Main.qml читается с диска).
Item {
    id: harness
    width: 100; height: 100

    QtObject { id: appSettings
        function value(k, d) { return d }
        function setValue(k, v) {}
    }
    QtObject { id: exportFileHelper
        property string lastZip: ""
        property int manualOpened: 0
        function openManual() { manualOpened++; return true }
        function reportsDir() { return "C:/kb_test" }
        function isFileLocked(p) { return false }
        function openInDocViewer(p) { return true }
        function writeZip(p, e) { lastZip = p; return "" }
        function chooseSavePath(t, s, f, e) { return "" }
    }
    QtObject { id: cadastralHttp
        signal finished(int id, int status, string body, string contentType, string error)
        function get() { return 0 }
        function post() { return 0 }
    }
    QtObject { id: tileDiskCache
        signal tileStored(string url)
        signal tileFailed(string url)
        function localSource(u) { return "" }
        function hasFailed(u) { return false }
    }
    QtObject { id: logConsole
        property string text: ""
        function append(s) { text += s + "\n" }
    }

    Loader { id: loader; source: Qt.resolvedUrl("../../qml/Main.qml") }

    readonly property real la: 52.28
    readonly property real lo: 104.30
    readonly property real mLat: 111320
    readonly property real mLon: 111320 * Math.cos(la * Math.PI / 180)
    function pt(x, y) { return { lat: la + y / mLat, lon: lo + x / mLon } }
    function sq(x, y, a, b) { return [pt(x, y), pt(x + a, y), pt(x + a, y + b), pt(x, y + b)] }
    function geo(rings) {     // GeoJSON в градусах, [lon, lat]
        function ring(r) { var c = r.map(function (p) { return [p.lon, p.lat] }); c.push(c[0]); return c }
        if (rings.length === 1) return { type: "Polygon", coordinates: [ring(rings[0])] }
        return { type: "MultiPolygon", coordinates: rings.map(function (r) { return [ring(r)] }) }
    }
    function feat(num, purpose, rings) {
        return { type: "Feature", geometry: geo(rings),
                 properties: { options: { cad_num: num, permitted_use_established_by_document: purpose,
                                          land_record_area: 1000 } } }
    }

    function findItem(item, pred) {
        if (!item) return null
        if (pred(item)) return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            var r = findItem(kids[i], pred)
            if (r) return r
        }
        return null
    }

    TestCase {
        name: "Main"
        when: loader.status === Loader.Ready
        property var win
        property var map

        function screen(lat, lon) {
            return map.fromCoordinate(QtPositioning.coordinate(lat, lon), false)
        }
        function click(p, mods) {
            console.log("  click map at " + p.x.toFixed(0) + "," + p.y.toFixed(0) + " center=" + map.center.latitude.toFixed(5) + "," + map.center.longitude.toFixed(5) + " zoom=" + map.zoomLevel.toFixed(2))
            mouseClick(map, p.x, p.y, Qt.LeftButton, mods || Qt.NoModifier); wait(80)
        }

        function test_1_setup() {
            win = loader.item
            verify(win, "Main.qml загружен")
            wait(300)
            map = findItem(win.contentItem, function (it) { return it.zoomLevel !== undefined && it.center !== undefined && it.plugin !== undefined })
            verify(map, "карта найдена")
            var src = sq(0, 0, 40, 40)
            win.sourceNumbers = ["38:00:000000:1"]
            win._sourceTotal = 1
            win._sourceCollectedCount = 0
            win._onSourceFound({ number: "38:00:000000:1", ring: src, rings: [src], area: 1600, purpose: "" }, "НСПД")
            var feats = [
                feat("38:00:000000:1", "производство", [src]),
                feat("38:00:000000:11", "Малоэтажная жилая застройка", [sq(50, 0, 30, 40)]),
                feat("38:00:000000:12", "магазины", [sq(0, 50, 40, 30)]),
                // многоконтурный «кооператив»: мелкая часть далеко, крупная — у участка
                feat("38:00:000000:13", "под строительство автогаражного кооператива",
                     [sq(-200, -200, 5, 5), sq(-60, -10, 50, 60)])
            ]
            win._finishNeighbors(feats, "НСПД")
            win.show(); win.raise(); win.requestActivate()
            for (var w = 0; w < 30 && (map.height <= 0 || !win.active); w++) wait(100)
            console.log("SHOWN visibility=" + win.visibility + " exposed-ish map=" + map.width + "x" + map.height)
            win._fitToResults()
            wait(500)
            console.log("GEOM win=" + win.width + "x" + win.height + " map=" + map.width + "x" + map.height + " zoom=" + map.zoomLevel.toFixed(2) + " active=" + win.active)
            compare(win.neighbors.length, 3, "соседей")
            compare(win.neighborParts.length, 4, "частей на карте")
            var n13 = win._neighborByNumber("38:00:000000:13")
            compare(n13.rings.length, 2, "у многоконтурного 2 части")
            verify(Math.abs(n13.gap - 10) < 0.5, "зазор многоконтурного по ближней части: " + n13.gap)
            compare(win.bufferRings.length, 1, "единый буфер")
            console.log("STATE zoom=" + map.zoomLevel.toFixed(2) + " gaps=" + win.neighbors.map(function (n) { return n.number.slice(-2) + ":" + n.gap.toFixed(1) }).join(","))
        }

        function test_2a_preselect_then_source_clears() {
            win._setSelection({ "38:00:000000:11": true, "38:00:000000:12": true })
            win.highlightNumber = "38:00:000000:11"
            var c = pt(20, 20)
            var sp = screen(c.lat, c.lon)
            console.log("SOURCE CLICK at " + sp.x.toFixed(0) + "," + sp.y.toFixed(0))
            click(sp)
            console.log("AFTER SOURCE CLICK (preselected) selected=" + win.selectedCount + " highlight='" + win.highlightNumber + "'")
            compare(win.selectedCount, 0, "клик по исходному снимает выбор")
            compare(win.highlightNumber, "", "и подсветку")
        }
        function test_2_click_neighbor() {
            var c = pt(65, 20)
            click(screen(c.lat, c.lon))
            compare(win.highlightNumber, "38:00:000000:11")
            compare(win.selectedCount, 1)
        }
        function test_3_ctrl_click_multipart() {
            var a = pt(65, 20)
            click(screen(a.lat, a.lon))
            var c = pt(-35, 20)
            click(screen(c.lat, c.lon), Qt.ControlModifier)
            compare(win.selectedCount, 2, "Ctrl+клик добавил многоконтурный")
            verify(win.isSelected("38:00:000000:13"))
        }
        function test_4_click_source_clears() {
            var c = pt(20, 20)
            click(screen(c.lat, c.lon))
            console.log("AFTER SOURCE CLICK selected=" + win.selectedCount + " highlight='" + win.highlightNumber + "'")
            compare(win.selectedCount, 0, "клик по исходному снимает выбор")
            compare(win.highlightNumber, "", "и подсветку")
        }
        function test_5_click_label() {
            var n = win._neighborByNumber("38:00:000000:12")
            click(screen(n.label.lat, n.label.lon))
            compare(win.highlightNumber, "38:00:000000:12", "клик по подписи")
        }
        function test_6_sort_area_toggle() {
            var hdr = findItem(win.contentItem, function (it) { return it.text !== undefined && String(it.text).indexOf("Площадь") === 0 })
            verify(hdr, "заголовок площади")
            var hp = hdr.mapToItem(win.contentItem, hdr.width / 2, hdr.height / 2)
            console.log("HDR '" + hdr.text + "' at " + hp.x.toFixed(0) + "," + hp.y.toFixed(0) + " size " + hdr.width + "x" + hdr.height + " key=" + win.sortState.key + " asc=" + win.sortState.ascending)
            mouseClick(win.contentItem, hp.x, hp.y); wait(50)
            var first = win.sortState.ascending
            mouseClick(win.contentItem, hp.x, hp.y); wait(50)
            var second = win.sortState.ascending
            mouseClick(win.contentItem, hp.x, hp.y); wait(50)
            console.log("SORT area clicks: " + first + " " + second + " " + win.sortState.ascending)
            compare(first, false); compare(second, true); compare(win.sortState.ascending, false)
        }
        function test_7_remove_restore() {
            win._setSelection({ "38:00:000000:13": true })
            win.removeSelected()
            compare(win.neighbors.length, 2)
            compare(win.neighborParts.length, 2)
            win.restoreRemoved()
            compare(win.neighbors.length, 3)
        }
        function test_9_help_button() {
            var btn = findItem(win.contentItem, function (it) { return it.text === "?" && it.clicked !== undefined })
            verify(btn, "кнопка «?» в шапке")
            mouseClick(btn); wait(50)
            compare(exportFileHelper.manualOpened, 1, "кнопка открывает инструкцию")
            keyClick(Qt.Key_F1); wait(50)
            compare(exportFileHelper.manualOpened, 2, "F1 открывает инструкцию")
        }
        function test_8_export_word() {
            win.exportWord()
            verify(exportFileHelper.lastZip.indexOf(".docx") > 0, "writeZip вызван: " + exportFileHelper.lastZip)
        }
    }
}
