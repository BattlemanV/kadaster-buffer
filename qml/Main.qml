import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtLocation 5.15
import QtPositioning 5.15

import "components/GeoMath.js" as GeoMath
import "components/Cadastral.js" as Cadastral
import "components/Reports.js" as Reports
import "components"

// «Буфер участка» (KadBuffer): по кадастровым номерам и буферу в метрах
// собирает из НСПД соседние земельные участки, показывает их на карте
// (подложка НСПД) и в таблице: № / номер / румб / зазор границ /
// назначение. Экспорт — Word (форма раздела СЗЗ), см. Reports.js.
ApplicationWindow {
    id: window
    width: 1280
    height: 860
    visible: true
    title: "Буфер участка " + appVersion
    color: theme.background

    Theme { id: theme }

    // Инструкция пользователя (docs/manual.html, лежит рядом с exe).
    function openManual() {
        if (!exportFileHelper.openManual())
            statusText = "Инструкция не найдена: manual.html должен лежать рядом с программой"
    }
    Shortcut {
        sequence: "F1"
        onActivated: window.openManual()
    }
    Shortcut {
        sequence: "F12"
        onActivated: logPanel.visible = !logPanel.visible
    }

    Connections {
        target: cadastralHttp
        function onFinished(id, status, body, contentType, error) {
            if (Cadastral._onHttpFinished) Cadastral._onHttpFinished(id, status, body, contentType, error)
        }
    }

    // ---------------------------------------------------------------
    // Состояние
    // ---------------------------------------------------------------
    property var sourceNumbers: []       // [string] кадастровые номера
    property var sourceRings: []         // [[{lat,lon}]] контуры исходных
    property var sourceCentroids: []     // [{lat,lon}] центроиды
    property var sourceProviders: []     // [string] имена провайдеров
    // Буферная зона — общая для всех исходных участков (объединение,
    // GeoMath.bufferRingsM): одно кольцо, если зоны слились, несколько —
    // если участки далеко друг от друга.
    property var bufferRings: []         // [[{lat,lon}]] кольца общей буферной зоны
    property var neighbors: []           // [{no, number, ring, centroid, label, area, gap, rumb}]
    property string sourceProviderName: ""
    property bool sourceLoading: false
    property bool neighborsLoading: false
    property string statusText: "Введите кадастровые номера участков и буфер в метрах"
    property bool busy: sourceLoading || neighborsLoading

    property var sortState: ({ key: "dist", ascending: true })

    // Центр и масштаб карты — отдельно от Map: их ставят и читают
    // _fitToBounds и клики по таблице.
    property real _mapCenterLat: 52.286
    property real _mapCenterLon: 104.30
    property real _mapZoom: 15

    // Цвета и штриховка слоёв — выбираются в легенде карты и
    // запоминаются в настройках (ключи layers/*). По умолчанию: исходный
    // участок синий со штриховкой, буфер оранжевый, соседи бледно-серые.
    property color sourceColor: appSettings.value("layers/sourceColor", "#1f5fd1")
    property color bufferColor: appSettings.value("layers/bufferColor", "#E95420")
    property color neighborColor: appSettings.value("layers/neighborColor", "#9e9e9e")
    // ini-файл QSettings отдаёт bool строкой "true"/"false".
    property bool sourceHatchOn: String(appSettings.value("layers/sourceHatch", true)) === "true"
    property bool neighborHatchOn: String(appSettings.value("layers/neighborHatch", false)) === "true"
    readonly property var layerPalette: [
        "#1f5fd1", "#00838f", "#0e8420", "#7cb342", "#f2c500", "#E95420",
        "#c7162b", "#ad1457", "#7e3fb2", "#5d4037", "#9e9e9e", "#424242"
    ]

    function setLayerColor(layer, c) {
        if (layer === "source") sourceColor = c
        else if (layer === "buffer") bufferColor = c
        else if (layer === "neighbor") neighborColor = c
        appSettings.setValue("layers/" + layer + "Color", String(c))
    }
    function setLayerHatch(layer, on) {
        if (layer === "source") sourceHatchOn = on
        else if (layer === "neighbor") { neighborHatchOn = on; _buildNeighborHatch() }
        appSettings.setValue("layers/" + layer + "Hatch", on)
    }

    // Штриховка соседей — узор по виду участка (Reports.PARCEL_KINDS:
    // жильё — косая, гаражи — горизонталь, производство — сетка…). Только
    // когда включена: на сотне участков это тысячи MapPolyline.
    property var neighborHatch: []
    // Виды участков, которые сейчас на карте, — для расшифровки в легенде.
    property var kindsPresent: []
    // Контуры соседей для карты: по одному на каждую часть многоконтурного
    // участка — [{number, ring}]. Выбор/подсветка — по number.
    property var neighborParts: []
    function _buildNeighborHatch() {
        var partsAll = []
        for (var q = 0; q < neighbors.length; q++) {
            var rs = neighbors[q].rings || [neighbors[q].ring]
            for (var qi = 0; qi < rs.length; qi++)
                partsAll.push({ number: neighbors[q].number, ring: rs[qi] })
        }
        neighborParts = partsAll

        var counts = {}
        for (var n = 0; n < neighbors.length; n++)
            counts[neighbors[n].kind] = (counts[neighbors[n].kind] || 0) + 1
        var kinds = []
        for (var k = 0; k < Reports.PARCEL_KINDS.length; k++) {
            var info = Reports.PARCEL_KINDS[k]
            if (counts[info.kind])
                kinds.push({ kind: info.kind, title: info.title, angles: info.angles, count: counts[info.kind] })
        }
        kindsPresent = kinds

        if (!neighborHatchOn) { neighborHatch = []; return }
        var segs = []
        for (var i = 0; i < neighbors.length; i++) {
            var angles = Reports.parcelKindInfo(neighbors[i].kind).angles
            if (!angles.length) continue
            var rings = neighbors[i].rings || [neighbors[i].ring]
            for (var ri = 0; ri < rings.length; ri++) {
                var ring = rings[ri]
                if (!ring || ring.length < 3) continue
                var bb = GeoMath.ringBbox(ring)
                var diag = GeoMath.haversineM(bb.minLat, bb.minLon, bb.maxLat, bb.maxLon)
                var step = Math.max(1, Math.min(50, diag / 12))
                for (var a = 0; a < angles.length; a++)
                    segs = segs.concat(GeoMath.hatchSegments(ring, step, angles[a]))
            }
        }
        neighborHatch = segs
    }

    // ---------------------------------------------------------------
    // Выбор строк таблицы и удаление участков (например, мелочь
    // гаражного кооператива, засоряющая карту). Удалённые не теряются:
    // «Вернуть» возвращает их все. Номера после удаления пересчитываются
    // по порядку, чтобы на карте не было дыр.
    // ---------------------------------------------------------------
    property var selectedNumbers: ({})
    property int selectedCount: 0
    property int _selRev: 0
    property int _selAnchor: -1
    property var removedNeighbors: []

    function isSelected(num) { _selRev; return !!selectedNumbers[num] }
    function _setSelection(sel) {
        selectedNumbers = sel
        selectedCount = Object.keys(sel).length
        _selRev++
    }
    function clearSelection() { _setSelection({}); _selAnchor = -1 }

    // Клик по строке: просто — выбрать одну и показать на карте;
    // Ctrl — добавить/убрать; Shift — диапазон от предыдущего клика.
    function _rowClicked(row, num, mods) {
        var sel = {}
        if (mods & Qt.ControlModifier) {
            for (var k in selectedNumbers) sel[k] = true
            if (sel[num]) delete sel[num]; else sel[num] = true
            _selAnchor = row
            _setSelection(sel)
            highlightNumber = num
        } else if ((mods & Qt.ShiftModifier) && _selAnchor >= 0) {
            var a = Math.min(_selAnchor, row), b = Math.max(_selAnchor, row)
            for (var r = a; r <= b && r < rowsModel.count; r++) sel[rowsModel.get(r).number] = true
            _setSelection(sel)
            highlightNumber = num
        } else {
            sel[num] = true
            _selAnchor = row
            _setSelection(sel)
            _focusNeighbor(num)
        }
    }
    function selectAllRows() {
        var sel = {}
        for (var r = 0; r < rowsModel.count; r++) sel[rowsModel.get(r).number] = true
        _setSelection(sel)
    }

    function _renumber(list) {
        list.sort(function (a, b) { return a.gap - b.gap })
        for (var i = 0; i < list.length; i++) list[i].no = i + 1
        return list
    }
    function _neighborsChanged() {
        _buildNeighborHatch()
        _fillTable()
    }
    function removeSelected() {
        if (selectedCount === 0) return
        var keep = [], gone = []
        for (var i = 0; i < neighbors.length; i++)
            (selectedNumbers[neighbors[i].number] ? gone : keep).push(neighbors[i])
        removedNeighbors = removedNeighbors.concat(gone)
        if (selectedNumbers[highlightNumber]) highlightNumber = ""
        neighbors = _renumber(keep)
        clearSelection()
        _neighborsChanged()
        statusText = "Удалено участков: " + gone.length + ", осталось: " + neighbors.length
    }
    function restoreRemoved() {
        if (!removedNeighbors.length) return
        var n = removedNeighbors.length
        neighbors = _renumber(neighbors.concat(removedNeighbors))
        removedNeighbors = []
        clearSelection()
        _neighborsChanged()
        statusText = "Возвращено участков: " + n + ", всего: " + neighbors.length
    }

    Shortcut {
        sequence: StandardKey.Delete
        enabled: window.selectedCount > 0 && !numberField.activeFocus && !bufferField.activeFocus
        onActivated: window.removeSelected()
    }
    Shortcut {
        sequence: StandardKey.SelectAll
        enabled: rowsModel.count > 0 && !numberField.activeFocus && !bufferField.activeFocus
        onActivated: window.selectAllRows()
    }
    Shortcut {
        sequence: "Escape"
        enabled: window.selectedCount > 0
        onActivated: window.clearSelection()
    }

    // ---------------------------------------------------------------
    // Экспорт карты в PNG: снимок панели карты (подложка, участки,
    // подписи, легенда) в двойном разрешении — для вставки в отчёт.
    // ---------------------------------------------------------------
    function exportMap() {
        // Куда сохранить — спрашиваем; по умолчанию папка прошлого
        // сохранения карты (или папка выгрузок) и имя по номеру участка.
        var dir = String(appSettings.value("export/mapDir", "")) || exportFileHelper.reportsDir()
        var name = Reports.fileName({ source_numbers: sourceNumbers, buffer_m: bufferMeters() }, "png")
        var path = exportFileHelper.chooseSavePath("Сохранить карту", dir + "/" + name,
                                                   "Изображение PNG", "png")
        if (!path) return
        appSettings.setValue("export/mapDir", path.substring(0, path.lastIndexOf("/")))
        if (exportFileHelper.isFileLocked(path)) {
            statusText = "Экспорт карты: файл открыт в другой программе — закройте его"
            return
        }
        colorPopup.close()
        statusText = "Экспорт карты…"
        var ok = mapFrame.grabToImage(function (result) {
            if (result.saveToFile(path)) {
                statusText = "Готово: " + path
                exportFileHelper.openInDocViewer(path)
            } else {
                statusText = "Экспорт карты: не удалось записать " + path
                logConsole.append(statusText)
            }
        }, Qt.size(mapFrame.width * 2, mapFrame.height * 2))
        if (!ok) statusText = "Экспорт карты: снимок не удался (окно свёрнуто?)"
    }

    // Косая штриховка исходных участков: [[{lat,lon},{lat,lon}]] —
    // все отрезки всех участков одним списком (см. GeoMath.hatchSegments).
    property var sourceHatch: []

    function _buildSourceHatch() {
        var segs = []
        for (var i = 0; i < sourceRings.length; i++) {
            var bb = GeoMath.ringBbox(sourceRings[i])
            var diag = GeoMath.haversineM(bb.minLat, bb.minLon, bb.maxLat, bb.maxLon)
            // ~20 линий на участок независимо от его размера.
            var step = Math.max(1, Math.min(50, diag / 20))
            segs = segs.concat(GeoMath.hatchSegments(sourceRings[i], step))
        }
        sourceHatch = segs
    }

    function bufferMeters() {
        var v = parseFloat(bufferField.text.replace(",", "."))
        return isFinite(v) && v > 0 ? v : 0
    }

    // ---------------------------------------------------------------
    // Сбор: 1) контуры всех исходных участков, 2) bbox+буфер → соседи
    // ---------------------------------------------------------------
    function collect() {
        var raw = numberField.text.trim()
        if (!raw) { statusText = "Введите кадастровый номер"; return }
        var buf = bufferMeters()
        if (buf <= 0) { statusText = "Укажите буфер в метрах (> 0)"; return }
        // Разбиваем по запятой, точке с запятой или новой строке
        var numbers = raw.split(/[,;\n\r]+/).map(function(s){ return s.trim() }).filter(function(s){ return s.length > 0 })
        if (numbers.length === 0) { statusText = "Введите кадастровый номер"; return }
        sourceNumbers = numbers
        sourceRings = []
        sourceHatch = []
        sourceCentroids = []
        sourceProviders = []
        bufferRings = []
        neighbors = []
        neighborHatch = []
        neighborParts = []
        removedNeighbors = []
        clearSelection()
        rowsModel.clear()
        _sourceDiag = []        // иначе причины прошлого поиска переедут в новый
        _neighborsDiag = []
        _sourceRetry = 0
        _neighborsRetry = 0
        _sourceCollectedCount = 0
        _sourceTotal = numbers.length
        sourceLoading = true
        statusText = "Поиск участка 1 из " + _sourceTotal + "…"
        logConsole.append("--- поиск " + numbers.length + " участков, буфер " + buf + " м ---")
        _requestSource(numbers[0], 0)
    }

    property int _sourceCollectedCount: 0
    property int _sourceTotal: 1

    // Таймаут держит сам cadastralHttp (параметр вызова) и присылает
    // ответ со status 0 — отдельный QML-таймер больше не нужен.
    property int _sourceToken: 0
    property string _sourceReqNumber: ""
    property int _sourceAttempt: 0
    // Причина неудачи по каждому провайдеру. Раньше тут был один флаг
    // _sourceAnyEmpty, который (а) не сбрасывался между поисками и (б)
    // склеивал три разных случая в «участок не найден» — в том числе
    // случай «участок НАЙДЕН, но контур не разобран».
    property var _sourceDiag: []
    // Один повтор на временную ошибку (статус 0 или 5xx). В цепочке
    // остался единственный провайдер, поэтому разовый HTTP 500 иначе
    // обрывает весь поиск.
    property int _sourceRetry: 0

    function _requestSource(number, attempt) {
        if (attempt >= Cadastral.searchProviders.length) {
            sourceLoading = false
            var why = _sourceDiag.length > 0
                    ? _sourceDiag.join("; ")
                    : "ответа не было"
            statusText = "Участок «" + number + "»: " + why
            logConsole.append("Контур не получен. " + why)
            return
        }
        _sourceReqNumber = number
        _sourceAttempt = attempt
        var provider = Cadastral.searchProviders[attempt]
        statusText = "Запрос " + provider.name + "…"
        // Запрос идёт через cadastralHttp, а не XMLHttpRequest: Qt не даёт
        // выставить в QML-XHR ни User-Agent, ни Referer (оба в списке
        // запрещённых заголовков), а НСПД и ПКК без них отвечают отказом.
        _sourceToken++
        var token = _sourceToken
        var id = Cadastral._httpCall(cadastralHttp, provider.buildUrl(number),
                                     provider.referer, Cadastral.USER_AGENT, 12000,
                                     function (r) {
            if (window._sourceToken !== token) return   // ответ от отменённого запроса
            function fail(reason) {
                window._sourceDiag.push(provider.name + " — " + reason)
                logConsole.append(provider.name + ": " + reason)
                window._requestSource(number, attempt + 1)
            }
            if (r.status < 200 || r.status >= 300) {
                // 'transient' - зарезервированное слово в грамматике QML JS,
                // назвать так переменную нельзя.
                var isTransient = (r.status === 0 || r.status >= 500)
                if (isTransient && window._sourceRetry < 1) {
                    window._sourceRetry++
                    logConsole.append(provider.name + ": HTTP " + r.status
                                      + ", повтор " + window._sourceRetry)
                    window._requestSource(number, attempt)
                    return
                }
                window._sourceRetry = 0
                fail("HTTP " + r.status + (r.error ? " (" + r.error + ")" : ""))
                return
            }
            window._sourceRetry = 0
            logConsole.append(provider.name + ": HTTP " + r.status + ", "
                              + r.body.length + " байт, " + r.contentType)
            if (r.contentType.indexOf("json") < 0) {
                logConsole.append(provider.name + " начало ответа: " + r.body.substring(0, 300))
                fail("сервис вернул " + r.contentType + " вместо JSON — эндпоинт, вероятно, больше не существует")
                return
            }
            var data
            try {
                data = JSON.parse(r.body)
            } catch (e) {
                logConsole.append(provider.name + " начало ответа: " + r.body.substring(0, 400))
                fail("ответ не является JSON (" + e + ")")
                return
            }
            var feats = Cadastral.featuresFromResponse(data)
            if (!feats.length) {
                logConsole.append(provider.name + " начало ответа: " + r.body.substring(0, 400))
                fail("в ответе нет участков")
                return
            }
            var parcel = Cadastral.parcelFromFeature(feats[0])
            if (!parcel || !parcel.ring) {
                // Самый коварный случай: участок есть, а контура нет. Пишем в
                // лог тип геометрии и сам фрагмент ответа — без этого отличить
                // «нет такого участка» от «границы не отданы» невозможно.
                var kind = Cadastral.geometryKind(feats[0])
                logConsole.append(provider.name + " геометрия первого участка: " + kind)
                logConsole.append(provider.name + " начало ответа: " + r.body.substring(0, 600))
                fail("участок найден (" + feats.length + " шт.), но контур не разобран, geometry: " + kind)
                return
            }
            window.sourceLoading = false
            window._onSourceFound(parcel, provider.name)
        })
        // id <= 0 — запрос не стартовал. Колбэк в этом случае уже вызван
        // синхронно и сам сдвинул токен, поэтому дублировать переход нельзя.
        if (id <= 0 && _sourceToken === token)
            _requestSource(number, attempt + 1)
    }

    function _onSourceFound(parcel, providerName) {
        // Аккумулируем найденный участок — ВСЕ его контуры: у
        // многоконтурного буфер и зазоры считаются от каждой части.
        // Присваивание НОВОГО массива, а не push: push не уведомляет
        // привязки, и слой исходных участков на карте оставался пустым —
        // ни контура, ни клика по нему (была видна только штриховка).
        var parts = parcel.rings && parcel.rings.length ? parcel.rings : [parcel.ring]
        sourceRings = sourceRings.concat(parts)
        sourceCentroids = sourceCentroids.concat(parts.map(function (r) { return GeoMath.centroidOfRing(r) }))
        sourceProviders.push(providerName)
        _sourceCollectedCount++

        var nv = 0
        for (var pi = 0; pi < parts.length; pi++) nv += parts[pi].length
        logConsole.append(providerName + ": «" + parcel.number + "» → "
                          + (parts.length > 1 ? parts.length + " контуров, " : "") + nv + " вершин")

        if (_sourceCollectedCount < _sourceTotal) {
            // Запрашиваем следующий участок
            var nextIdx = _sourceCollectedCount
            statusText = "Поиск участка " + (nextIdx + 1) + " из " + _sourceTotal + "…"
            logConsole.append("--- поиск «" + sourceNumbers[nextIdx] + "» ---")
            _requestSource(sourceNumbers[nextIdx], 0)
            return
        }

        // Все участки собраны — вычисляем объединённый bbox и буфер
        var minLat = Infinity, maxLat = -Infinity, minLon = Infinity, maxLon = -Infinity
        for (var i = 0; i < sourceRings.length; i++) {
            var rbb = GeoMath.ringBbox(sourceRings[i])
            if (rbb.minLat < minLat) minLat = rbb.minLat
            if (rbb.maxLat > maxLat) maxLat = rbb.maxLat
            if (rbb.minLon < minLon) minLon = rbb.minLon
            if (rbb.maxLon > maxLon) maxLon = rbb.maxLon
        }
        var bounds = { south: minLat, north: maxLat, west: minLon, east: maxLon }
        var buf = bufferMeters()
        var bufBounds = GeoMath.expandBoundsMeters(bounds, buf)

        // Буферная зона — настоящий многоугольник по контурам
        // (GeoMath.bufferRingsM). Прямоугольник остаётся подстраховкой: без
        // него при вырожденном контуре зона поиска стала бы невидимой.
        var t0buf = Date.now()
        // Одна общая зона вокруг ВСЕХ исходных контуров (объединение):
        // у соседних участков зоны сливаются, у далёких — отдельные кольца.
        var rings = GeoMath.bufferRingsM(sourceRings, buf)
        bufferRings = rings.length > 0 ? rings : [GeoMath.boundsToRing(bufBounds)]
        _buildSourceHatch()
        logConsole.append("Буферная зона: колец " + rings.length
                          + " вокруг " + sourceRings.length + " контуров"
                          + (rings.length === 0 ? " (не построена, подставлен прямоугольник)" : "")
                          + ", " + (Date.now() - t0buf) + " мс")

        var plural = _sourceTotal + " участков"
        statusText = "Участки найдены (" + sourceProviders.join(", ") + "), запрос соседей…"
        logConsole.append("Все " + _sourceTotal + " участков собраны, bbox "
                          + Math.round((maxLon - minLon) * 111320) + "x" + Math.round((maxLat - minLat) * 111320) + " м, буфер " + buf + " м")
        neighborsLoading = true
        _requestNeighbors(bufBounds, 0)
        _fitToBounds(bufBounds)
    }

    property int _neighborsToken: 0
    property var _neighborsDiag: []
    property int _neighborsRetry: 0

    function _requestNeighbors(bounds, attempt) {
        // Поиск соседей — НСПД /api/geoportal/v1/intersects. Было: bbox-поиск
        // ПКК, но pkk.rosreestr.ru больше не API — переадресует на НСПД и
        // отдаёт HTML (проверено 22.10.2026).
        if (attempt >= 1) {
            neighborsLoading = false
            var nwhy = _neighborsDiag.length > 0 ? _neighborsDiag.join("; ") : "ответа не было"
            statusText = "Соседи не получены: " + nwhy
            logConsole.append("Соседи не получены. " + nwhy)
            return
        }
        statusText = "Запрос соседей в НСПД…"
        _neighborsToken++
        var token = _neighborsToken
        var ring = GeoMath.boundsToRing(bounds)
        var body = Cadastral.buildIntersectsBody(ring)
        logConsole.append("НСПД /intersects: кольцо " + ring.length
                          + " вершин, слой " + Cadastral.PARCEL_CATEGORY_ID
                          + ", тело " + body.length + " байт")
        var t0 = Date.now()
        var id = Cadastral._httpPost(cadastralHttp, Cadastral.INTERSECTS_URL,
                                     Cadastral.REFERER_NSPD, Cadastral.USER_AGENT, 45000,
                                     body, function (r) {
            var ms = Date.now() - t0
            if (window._neighborsToken !== token) {
                logConsole.append("НСПД: ответ от отменённого запроса отброшен (" + ms + " мс)")
                return
            }
            function nfail(reason) {
                window._neighborsDiag.push(reason)
                logConsole.append("НСПД: " + reason)
                window._requestNeighbors(bounds, attempt + 1)
            }
            if (r.status < 200 || r.status >= 300) {
                if (r.status === 0 || r.status >= 500) {
                    if (window._neighborsRetry < 1) {
                        window._neighborsRetry++
                        logConsole.append("НСПД: HTTP " + r.status + ", повтор "
                                          + window._neighborsRetry)
                        window._requestNeighbors(bounds, attempt)
                        return
                    }
                }
                if (r.body && r.body.length > 0)
                    logConsole.append("НСПД тело ошибки: " + r.body.substring(0, 400))
                nfail("HTTP " + r.status + (r.error ? " (" + r.error + ")" : "") + ", " + ms + " мс")
                return
            }
            logConsole.append("НСПД: HTTP " + r.status + ", " + r.body.length
                              + " байт, " + r.contentType + ", " + ms + " мс")
            if (r.contentType.indexOf("json") < 0) {
                logConsole.append("НСПД начало ответа: " + r.body.substring(0, 300))
                nfail("сервис вернул " + r.contentType + " вместо JSON")
                return
            }
            var data
            try {
                data = JSON.parse(r.body)
            } catch (e) {
                logConsole.append("НСПД начало ответа: " + r.body.substring(0, 400))
                nfail("ответ не является JSON (" + e + ")")
                return
            }
            var feats = Cadastral.featuresFromResponse(data)
            logConsole.append("НСПД: участков в ответе: " + feats.length)
            // Имена полей у НСПД не документированы и менялись. Печатаем
            // фактические атрибуты первого соседа — по ним видно, из какого
            // поля брать назначение, если автоподбор не сработал.
            if (feats.length > 0)
                logConsole.append("НСПД атрибуты 1-го участка: " + Cadastral.dumpAttrKeys(feats[0]))
            if (!feats.length) {
                // Форма ответа /intersects вживую ещё не виделась: если
                // участки лежат не в data.features, фрагмент покажет где.
                logConsole.append("НСПД начало ответа: " + r.body.substring(0, 700))
                nfail("в ответе ни одного участка")
                return
            }
            window._finishNeighbors(feats, "НСПД")
        })
        if (id <= 0 && _neighborsToken === token)
            _requestNeighbors(bounds, attempt + 1)
    }

    function _finishNeighbors(feats, providerName) {
        neighborsLoading = false
        var buf = bufferMeters()
        var result = []
        var skippedGeometry = 0
        for (var i = 0; i < feats.length; i++) {
            var parcel = Cadastral.parcelFromFeature(feats[i])
            if (!parcel || !parcel.ring) { skippedGeometry++; continue }
            // Исходные участки (и возможные дубли их номеров) пропускаем.
            var isSource = false
            for (var s = 0; s < sourceNumbers.length; s++) {
                if (parcel.number && parcel.number === sourceNumbers[s]) { isSource = true; break }
            }
            if (isSource) continue
            // Минимальный зазор от ЛЮБОЙ части parcel до ЛЮБОГО исходного
            // контура. nearPart — ближайшая часть: в ней ставится подпись.
            var parts = parcel.rings && parcel.rings.length ? parcel.rings : [parcel.ring]
            var minGap = Infinity, nearPart = parts[0]
            for (var pp = 0; pp < parts.length; pp++) {
                for (var r = 0; r < sourceRings.length; r++) {
                    var g = GeoMath.minDistanceRingsM(sourceRings[r], parts[pp])
                    if (g < minGap) { minGap = g; nearPart = parts[pp] }
                }
            }
            if (!(minGap <= buf)) continue
            var c = GeoMath.centroidOfRings(parts) || GeoMath.centroidOfRing(parcel.ring)
            // Румб — от ближайшего исходного участка.
            var nearestCentroid = null
            var nearestDist = Infinity
            for (var cr = 0; cr < sourceCentroids.length; cr++) {
                var d = GeoMath.haversineM(sourceCentroids[cr].lat, sourceCentroids[cr].lon, c.lat, c.lon)
                if (d < nearestDist) { nearestDist = d; nearestCentroid = sourceCentroids[cr] }
            }
            var rumb = nearestCentroid
                    ? GeoMath.rumbBetween(nearestCentroid.lat, nearestCentroid.lon, c.lat, c.lon)
                    : "—"
            result.push({
                number: parcel.number || "(без номера в ответе)",
                ring: parcel.ring,
                rings: parts,
                centroid: c,
                // Точка подписи — внутри ближайшей части И внутри буфера: у
                // дороги/Г-образного/многоконтурного участка центроид лежит за зоной.
                label: GeoMath.labelPointInBuffer(nearPart, sourceRings, buf) || c,
                area: parcel.area || 0,
                purpose: parcel.purpose || "",
                // Вид — для узора штриховки (Reports.PARCEL_KINDS).
                kind: Reports.parcelKind(parcel.purpose),
                gap: minGap,
                rumb: rumb
            })
        }
        // Сортировка по зазору — ближайшие сверху.
        result.sort(function (a, b) { return a.gap - b.gap })
        // Постоянный номер участка — подпись на карте, левый список и
        // колонка «№» таблицы. Сортировка таблицы его НЕ меняет, иначе
        // номер на карте разойдётся с номером в строке.
        for (var ri = 0; ri < result.length; ri++) result[ri].no = ri + 1
        neighbors = result
        _buildNeighborHatch()
        _fillTable()
        // НСПД ищет по ПРЯМОУГОЛЬНИКУ вокруг участков (bbox + буфер) и
        // отдаёт всё, что его задевает, включая сами исходные участки.
        // Углы прямоугольника дальше буфера, поэтому часть ответа
        // отсеивается по настоящему зазору. В статус — только итог,
        // подробности — в консоль (F12). Подозрительно круглое число от
        // НСПД — повод проверить обрезку: лимит /intersects не известен.
        statusText = "Найдено участков в зоне " + buf + " м: " + result.length
        var msg = providerName + ": по прямоугольнику поиска получено " + feats.length
                + ", в зоне " + buf + " м от границы — " + result.length
        if (skippedGeometry > 0)
            msg += ", пропущено с неразобранной геометрией: " + skippedGeometry
        logConsole.append(msg)
        if (result.length > 0) _fitToResults()
    }

    // ---------------------------------------------------------------
    // Таблица
    // ---------------------------------------------------------------
    function _fillTable() {
        rowsModel.clear()
        for (var i = 0; i < neighbors.length; i++) {
            var n = neighbors[i]
            rowsModel.append({
                n: n.no,
                number: n.number,
                rumb: n.rumb,
                dist: Math.round(n.gap * 10) / 10,
                area: n.area || 0,
                purpose: n.purpose ? n.purpose : "—"
            })
        }
        // Текущая сортировка сохраняется и после удаления/возврата.
        _applySort(sortState.key, sortState.ascending, false)
    }

    function _applySort(key, ascending, keepOrder) {
        if (!keepOrder) {
            sortState.key = key
            sortState.ascending = ascending
            // Копии строк, а не rowsModel.get(i): тот отдаёт живые ссылки
            // на элементы модели, которые clear() ниже уничтожает.
            var rows = []
            for (var i = 0; i < rowsModel.count; i++) {
                var src = rowsModel.get(i)
                rows.push({ n: src.n, number: src.number, rumb: src.rumb,
                            dist: src.dist, area: src.area, purpose: src.purpose })
            }
            rows.sort(function (a, b) {
                var r
                if (key === "dist" || key === "n" || key === "area")
                    r = a[key] - b[key]
                else
                    r = String(a[key]).localeCompare(String(b[key]), "ru")
                return ascending ? r : -r
            })
            rowsModel.clear()
            // n не перенумеровываем — это номер участка на карте.
            for (i = 0; i < rows.length; i++) rowsModel.append(rows[i])
        }
        tableHeaderRepeater.model = 0
        tableHeaderRepeater.model = headerColumns.length
    }

    readonly property var headerColumns: [
        { key: "n",      label: "№",                    width: 48 },
        { key: "number", label: "Кадастровый номер",     width: 190 },
        { key: "rumb",   label: "Румб",                  width: 70 },
        { key: "dist",   label: "Расстояние от границы, м", width: 150 },
        { key: "area",   label: "Площадь, м²",           width: 100 },
        { key: "purpose", label: "Назначение",            width: 260 }
    ]

    // ---------------------------------------------------------------
    // Карта
    // ---------------------------------------------------------------
    function _fitToBounds(bounds) {
        var lat0 = (bounds.south + bounds.north) / 2
        var lon0 = (bounds.west + bounds.east) / 2
        var mPerDegLat = 111320.0
        var mPerDegLon = 111320.0 * Math.cos(lat0 * Math.PI / 180)
        var wM = Math.max(50, (bounds.east - bounds.west) * mPerDegLon)
        var hM = Math.max(50, (bounds.north - bounds.south) * mPerDegLat)
        _mapCenterLat = lat0
        _mapCenterLon = lon0
        // zoom из формулы метров/пиксель Web Mercator, с запасом 1.35.
        var zx = Math.log2(156543.03392 * Math.cos(lat0 * Math.PI / 180)
                           * map.width / (wM * 1.35))
        var zy = Math.log2(156543.03392 * Math.cos(lat0 * Math.PI / 180)
                           * map.height / (hM * 1.35))
        var z = Math.min(zx, zy)
        _mapZoom = Math.max(map.minimumZoomLevel, Math.min(map.maximumZoomLevel, z))
        if (map) {
            // Сначала масштаб, потом центр: при мелком масштабе Qt зажимает
            // широту центра (мир целиком в окне) — центр оставался на 0°.
            map.zoomLevel = _mapZoom
            map.center = QtPositioning.coordinate(lat0, lon0)
        }
    }

    function _fitToResults() {
        // Объединяем bbox всех колец: и исходных участков, и буферных
        // зон. Без буферных карта обрезала бы зону поиска по краю.
        var bb = null
        function acc(ring) {
            if (!ring || ring.length < 2) return
            var r = GeoMath.ringBbox(ring)
            if (!bb) {
                bb = { minLat: r.minLat, maxLat: r.maxLat,
                       minLon: r.minLon, maxLon: r.maxLon }
                return
            }
            if (r.minLat < bb.minLat) bb.minLat = r.minLat
            if (r.maxLat > bb.maxLat) bb.maxLat = r.maxLat
            if (r.minLon < bb.minLon) bb.minLon = r.minLon
            if (r.maxLon > bb.maxLon) bb.maxLon = r.maxLon
        }
        for (var i = 0; i < sourceRings.length; i++) acc(sourceRings[i])
        for (var j = 0; j < bufferRings.length; j++) acc(bufferRings[j])
        if (!bb) return
        // ВАЖНО: ringBbox отдаёт minLat/maxLat/minLon/maxLon, а
        // _fitToBounds читает south/north/west/east. Без переименования
        // все поля undefined, центр карты NaN — слои рисуются и тут же
        // исчезают, потому что карта уезжает в никуда.
        _fitToBounds({ south: bb.minLat, north: bb.maxLat,
                       west: bb.minLon, east: bb.maxLon })
    }

    // Принимает индекс в neighbors (зовётся с карты). Строку таблицы
    // ищем по номеру — её позиция зависит от текущей сортировки.
    // Показать участок: подсветить и прокрутить к нему таблицу. Всё —
    // по кадастровому номеру: индекс через neighbors.indexOf(modelData)
    // НЕ работает — делегаты моделей из JS-массива получают в modelData
    // КОПИЮ объекта, indexOf даёт -1, и клик по карте молча пропадал.
    function _selectRow(num) {
        if (!num) return
        highlightNumber = num
        for (var r = 0; r < rowsModel.count; r++) {
            if (rowsModel.get(r).number === num) {
                table.positionViewAtIndex(r, ListView.Contain)
                return
            }
        }
    }

    // Клик по участку на карте (полигон или подпись): выбрать его строку
    // в таблице и прокрутить к ней. Ctrl — добавить/убрать из выбора,
    // как Ctrl+клик в таблице; карту при этом не двигаем.
    function _mapClicked(num, mods) {
        if (!num) return
        var row = -1
        for (var r = 0; r < rowsModel.count; r++)
            if (rowsModel.get(r).number === num) { row = r; break }
        var sel = {}
        if (mods & Qt.ControlModifier) {
            for (var k in selectedNumbers) sel[k] = true
            if (sel[num]) delete sel[num]; else sel[num] = true
        } else {
            sel[num] = true
        }
        _setSelection(sel)
        _selAnchor = row
        _selectRow(num)
    }

    // Точка экрана карты внутри контура участка? MouseArea полигона —
    // это прямоугольник вокруг него: у дороги он накрывает десятки
    // соседей, и без этой проверки клик доставался не тому участку.
    function _ringContainsScreen(ring, item, mx, my) {
        if (!ring || ring.length < 3) return false
        var c = map.toCoordinate(item.mapToItem(map, mx, my), false)
        if (!c.isValid) return false
        var poly = ring.map(function (p) { return { x: p.lon, y: p.lat } })
        return GeoMath.pointInPolygonXY({ x: c.longitude, y: c.latitude }, poly)
    }

    // Клик по строке таблицы: подсветить участок и сдвинуть к нему карту.
    function _focusNeighbor(num) {
        var n = _neighborByNumber(num)
        if (!n) return
        _selectRow(n.number)
        var at = n.label || n.centroid
        if (at) {
            _mapCenterLat = at.lat
            _mapCenterLon = at.lon
            map.center = QtPositioning.coordinate(at.lat, at.lon)
        }
    }

    // Сосед по кадастровому номеру — общая часть для карты и таблицы.
    function _neighborByNumber(num) {
        for (var k = 0; k < neighbors.length; k++)
            if (neighbors[k].number === num) return neighbors[k]
        return null
    }
    // Подсветка — по кадастровому номеру, а НЕ по индексу: у карты
    // индекс в neighbors, у таблицы — номер строки rowsModel, и после
    // сортировки это разные вещи.
    property string highlightNumber: ""

    // ---------------------------------------------------------------
    // Экспорт в Word по форме раздела СЗЗ: абзац о нормируемых
    // территориях + таблица всех участков по площади. Документ строит
    // Reports.buildDocx, в zip (.docx — это zip с XML) упаковывает
    // exportFileHelper.writeZip.
    // ---------------------------------------------------------------
    function exportWord() {
        if (neighbors.length === 0) {
            statusText = "Нечего экспортировать — сначала соберите соседей"
            return
        }
        var rows = []
        for (var i = 0; i < neighbors.length; i++) {
            var n = neighbors[i]
            rows.push({
                number: n.number,
                rumb: n.rumb,
                distance_m: Math.round(n.gap * 10) / 10,
                area_m2: n.area || 0,
                purpose: n.purpose ? n.purpose : ""
            })
        }
        // Источник — без повторов: у нескольких исходных участков он один
        // и тот же ("НСПД, НСПД").
        var providers = sourceProviders.filter(function (p, k, a) { return p && a.indexOf(p) === k })
        var task = {
            source_numbers: sourceNumbers,
            buffer_m: bufferMeters(),
            provider: providers.join(", "),
            rows: rows
        }
        var path = exportFileHelper.reportsDir() + "/" + Reports.fileName(task, "docx")
        var err = exportFileHelper.writeZip(path, Reports.buildDocx(task))
        if (err) {
            statusText = "Экспорт в Word: " + err
            logConsole.append(statusText)
            return
        }
        statusText = "Готово: " + path
        exportFileHelper.openInDocViewer(path)
    }

    // ---------------------------------------------------------------
    // Интерфейс
    // ---------------------------------------------------------------
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: theme.spacingMd
        spacing: theme.spacingMd

        // -- Верхняя панель --
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: headerRow.implicitHeight + theme.spacingMd * 2
            color: theme.panel
            border.color: theme.panelBorder
            border.width: 1
            radius: 6

            RowLayout {
                id: headerRow
                anchors.fill: parent
                anchors.margins: theme.spacingMd
                spacing: theme.spacingMd

                Label {
                    text: "Кадастр. номер(а):"
                    color: theme.textSecondary
                    font.pixelSize: theme.fontBody
                }
                DarkTextField {
                    id: numberField
                    Layout.preferredWidth: 240
                    placeholderText: "38:00:000000:100, 38:00:000000:300"
                    onAccepted: window.collect()
                }
                Label {
                    text: "Буфер, м:"
                    color: theme.textSecondary
                    font.pixelSize: theme.fontBody
                }
                NumericField {
                    id: bufferField
                    Layout.preferredWidth: 90
                    text: "50"
                    onAccepted: window.collect()
                }
                Button {
                    text: window.busy ? "…" : "Собрать"
                    enabled: !window.busy
                    onClicked: window.collect()
                }
                Button {
                    text: "Экспорт Word"
                    enabled: !window.busy && neighbors.length > 0
                    onClicked: window.exportWord()
                }
                Button {
                    text: "Экспорт карты"
                    enabled: !window.busy && window.sourceRings.length > 0
                    onClicked: window.exportMap()
                }
                Button {
                    text: "?"
                    font.bold: true
                    Layout.preferredWidth: implicitHeight
                    onClicked: window.openManual()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "Инструкция (F1)"
                }
                Label {
                    Layout.fillWidth: true
                    text: window.statusText
                    color: window.busy ? theme.accent : theme.textSecondary
                    font.pixelSize: theme.fontFootnote
                    elide: Text.ElideRight
                    wrapMode: Text.WordWrap
                }
            }
        }

        // -- Карта + таблица -- SplitView: ширину таблицы меняют,
        // перетаскивая границу между ней и картой.
        SplitView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: Qt.Horizontal

            handle: Rectangle {
                implicitWidth: theme.spacingMd
                color: SplitHandle.pressed ? theme.base
                     : (SplitHandle.hovered ? theme.panelBorder : "transparent")
                // Риска посередине — видно, что за границу можно тянуть.
                Rectangle {
                    anchors.centerIn: parent
                    width: 2
                    height: 40
                    radius: 1
                    color: theme.textTertiary
                    opacity: 0.6
                }
            }

            // Карта
            Rectangle {
                id: mapFrame
                SplitView.fillWidth: true
                SplitView.minimumWidth: 300
                color: theme.panel
                border.color: theme.panelBorder
                border.width: 1
                radius: 6
                clip: true

                Map {
                    id: map
                    anchors.fill: parent
                    // Подложка — карта НСПД (Росреестр), рисует её слой
                    // nspdTiles ниже. Плагин "itemsoverlay" сам тайлов не
                    // рисует: он только даёт Map проекцию, жесты и слои.
                    // Почему не "osm" + custom.host: CARTO без ключа ставит
                    // водяной знак "API KEY REQUIRED", а OSM и чужие хосты
                    // этот плагин молча не качает (проверено 26.10.2026), и
                    // Referer, без которого НСПД отвечает 403, он не шлёт.
                    plugin: Plugin { name: "itemsoverlay" }
                    color: "#eeeeee"
                    maximumZoomLevel: 20
                    copyrightsVisible: false
                    center: QtPositioning.coordinate(window._mapCenterLat, window._mapCenterLon)
                    zoomLevel: window._mapZoom
                    onCenterChanged: {
                        window._mapCenterLat = center.latitude
                        window._mapCenterLon = center.longitude
                        nspdTiles.refresh()
                    }
                    onZoomLevelChanged: {
                        window._mapZoom = zoomLevel
                        nspdTiles.refresh()
                    }
                    onWidthChanged: nspdTiles.refresh()
                    onHeightChanged: nspdTiles.refresh()

                    // Тайлы подложки НСПД: XYZ в Web Mercator,
                    // /api/aeggis/v4/235/wmts/{z}/{x}/{y}.png (адрес снят из
                    // веб-карты nspd.gov.ru 26.10.2026). Качает и кэширует
                    // на диск tileDiskCache (C++, с Referer НСПД). Набор
                    // тайлов пересобирается только при смене состава —
                    // при панорамировании двигаются уже созданные Image.
                    Item {
                        id: nspdTiles
                        anchors.fill: parent
                        z: 0
                        // Максимальный уровень тайлов НСПД не подтверждён —
                        // глубже растягиваем тайлы этого уровня.
                        readonly property int maxTileZoom: 19
                        property var tiles: []
                        property string _key: ""
                        // Счётчик кадров: позиции Image зависят от него,
                        // чтобы пересчитаться при любом сдвиге карты.
                        property int frame: 0

                        function tileUrl(z, x, y) {
                            return "https://nspd.gov.ru/api/aeggis/v4/235/wmts/" + z + "/" + x + "/" + y + ".png"
                        }
                        function lon2x(lon, z) { return (lon + 180) / 360 * Math.pow(2, z) }
                        function lat2y(lat, z) {
                            var r = lat * Math.PI / 180
                            return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * Math.pow(2, z)
                        }
                        function x2lon(x, z) { return x / Math.pow(2, z) * 360 - 180 }
                        function y2lat(y, z) {
                            var n = Math.PI - 2 * Math.PI * y / Math.pow(2, z)
                            return Math.atan(0.5 * (Math.exp(n) - Math.exp(-n))) * 180 / Math.PI
                        }
                        // Экранная точка угла тайла (tx, ty) уровня z.
                        function screenOf(tx, ty, z) {
                            return map.fromCoordinate(QtPositioning.coordinate(y2lat(ty, z), x2lon(tx, z)), false)
                        }

                        function refresh() {
                            frame++
                            if (map.width <= 0 || map.height <= 0) return
                            var tl = map.toCoordinate(Qt.point(0, 0), false)
                            var br = map.toCoordinate(Qt.point(map.width, map.height), false)
                            if (!tl.isValid || !br.isValid) return
                            var z = Math.max(1, Math.min(maxTileZoom, Math.round(map.zoomLevel)))
                            var n = Math.pow(2, z)
                            var x0 = Math.floor(lon2x(tl.longitude, z)), x1 = Math.floor(lon2x(br.longitude, z))
                            var y0 = Math.max(0, Math.floor(lat2y(tl.latitude, z)))
                            var y1 = Math.min(n - 1, Math.floor(lat2y(br.latitude, z)))
                            var key = z + ":" + x0 + ":" + x1 + ":" + y0 + ":" + y1
                            if (key === _key) return
                            _key = key
                            var out = []
                            for (var ty = y0; ty <= y1; ty++)
                                for (var tx = x0; tx <= x1; tx++)
                                    out.push({ z: z, x: tx, y: ty,
                                               url: tileUrl(z, ((tx % n) + n) % n, ty) })
                            tiles = out
                        }

                        Repeater {
                            model: nspdTiles.tiles
                            delegate: Image {
                                property var t: modelData
                                property point p0: { nspdTiles.frame; return nspdTiles.screenOf(t.x, t.y, t.z) }
                                property point p1: { nspdTiles.frame; return nspdTiles.screenOf(t.x + 1, t.y + 1, t.z) }
                                x: p0.x
                                y: p0.y
                                width: p1.x - p0.x
                                height: p1.y - p0.y
                                smooth: true
                                asynchronous: true
                                cache: false
                                source: tileDiskCache.localSource(t.url)
                                Connections {
                                    target: tileDiskCache
                                    function onTileStored(url) {
                                        if (url === t.url) source = tileDiskCache.localSource(t.url)
                                    }
                                }
                            }
                        }
                        Component.onCompleted: refresh()
                    }

                    // Атрибуция подложки (родной copyright плагина скрыт).
                    Text {
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 4
                        z: 10
                        text: "© Росреестр, НСПД"
                        font.pixelSize: theme.fontFootnote
                        color: "#333333"
                        style: Text.Outline
                        styleColor: "white"
                    }

                    function selectMapType() {
                        for (var i = 0; i < supportedMapTypes.length; i++) {
                            if (supportedMapTypes[i].style === MapType.CustomMap) {
                                activeMapType = supportedMapTypes[i]
                                return
                            }
                        }
                        if (supportedMapTypes.length > 0)
                            activeMapType = supportedMapTypes[0]
                    }
                    onSupportedMapTypesChanged: selectMapType()
                    Component.onCompleted: selectMapType()

                    // Буферные зоны (по одной на исходный участок).
                    // MapItemView по той же причине, что и выше.
                    MapItemView {
                        model: window.bufferRings
                        delegate: MapPolygon {
                            property var bufRing: modelData
                            visible: !!(bufRing && bufRing.length >= 3)
                            path: {
                                var pts = []
                                var r = bufRing
                                if (!r) return pts
                                for (var i = 0; i < r.length; i++)
                                    pts.push(QtPositioning.coordinate(r[i].lat, r[i].lon))
                                return pts
                            }
                            color: Qt.rgba(window.bufferColor.r, window.bufferColor.g,
                                           window.bufferColor.b, 0.08)
                            border.color: window.bufferColor
                            border.width: 2
                            z: 1
                        }
                    }

                    // Исходные участки (все, не только один).
                    // MapItemView, а НЕ Repeater: QtLocation добавляет на Map
                    // только элементы, объявленные напрямую или созданные
                    // MapItemView. Элементы из Repeater на карту не попадают —
                    // карта молча остаётся пустой.
                    MapItemView {
                        model: window.sourceRings
                        delegate: MapPolygon {
                            // modelData, а не массив по index: в делегате
                            // MapItemView index может быть undefined, и тогда
                            // path пустой, а visible получает undefined.
                            property var ring: modelData
                            visible: !!(ring && ring.length >= 3)
                            path: {
                                var pts = []
                                for (var i = 0; i < ring.length; i++)
                                    pts.push(QtPositioning.coordinate(
                                        ring[i].lat,
                                        ring[i].lon))
                                return pts
                            }
                            color: Qt.rgba(window.sourceColor.r, window.sourceColor.g,
                                           window.sourceColor.b, 0.10)
                            border.color: window.sourceColor
                            border.width: 3
                            z: 2
                            // Клик по исходному участку снимает выбор и подсветку
                            // соседей. Только внутри контура: MouseArea — это
                            // прямоугольник вокруг участка.
                            MouseArea {
                                id: srcMouse
                                anchors.fill: parent
                                onPressed: mouse.accepted = window._ringContainsScreen(ring, srcMouse, mouse.x, mouse.y)
                                onClicked: {
                                    window.clearSelection()
                                    window.highlightNumber = ""
                                }
                            }
                        }
                    }

                    // Косая штриховка исходных участков — отдельными
                    // линиями: MapPolygon узорную заливку не умеет.
                    MapItemView {
                        model: window.sourceHatchOn ? window.sourceHatch : []
                        delegate: MapPolyline {
                            property var seg: modelData
                            visible: !!(seg && seg.length === 2)
                            path: seg ? [QtPositioning.coordinate(seg[0].lat, seg[0].lon),
                                         QtPositioning.coordinate(seg[1].lat, seg[1].lon)] : []
                            line.color: window.sourceColor
                            line.width: 1.5
                            z: 2
                        }
                    }

                    // Штриховка соседей (включается в легенде).
                    MapItemView {
                        model: window.neighborHatchOn ? window.neighborHatch : []
                        delegate: MapPolyline {
                            property var seg: modelData
                            visible: !!(seg && seg.length === 2)
                            path: seg ? [QtPositioning.coordinate(seg[0].lat, seg[0].lon),
                                         QtPositioning.coordinate(seg[1].lat, seg[1].lon)] : []
                            line.color: window.neighborColor
                            line.width: 1
                            z: 3
                        }
                    }

                    // Соседние участки — по контуру на каждую часть
                    // (neighborParts: у многоконтурного их несколько).
                    MapItemView {
                        model: window.neighborParts
                        delegate: MapPolygon {
                            property var neighborData: modelData
                            visible: !!(neighborData && neighborData.ring
                                        && neighborData.ring.length >= 3)
                            path: {
                                var pts = []
                                var d = neighborData
                                if (!d) return pts
                                for (var i = 0; i < d.ring.length; i++)
                                    pts.push(QtPositioning.coordinate(d.ring[i].lat, d.ring[i].lon))
                                return pts
                            }
                            // Подсвечен — показан (highlight) или выбран в таблице.
                            property bool picked: !!neighborData
                                                  && (window.highlightNumber === neighborData.number
                                                      || window.isSelected(neighborData.number))
                            color: Qt.rgba(window.neighborColor.r, window.neighborColor.g,
                                           window.neighborColor.b, picked ? 0.45 : 0.25)
                            // Выбранный — контуром акцента: на бледном сером
                            // одна толщина линии почти не заметна.
                            border.color: picked ? theme.accent : window.neighborColor
                            border.width: picked ? 3 : 1.5
                            // Выбранный — поверх соседей, иначе его контур
                            // прячется под перекрывающими участками.
                            z: picked ? 4 : 3
                            MouseArea {
                                id: polyMouse
                                anchors.fill: parent
                                // Мимо контура — пропустить клик ниже (другому участку
                                // или карте для перетаскивания).
                                onPressed: mouse.accepted = !!neighborData
                                           && window._ringContainsScreen(neighborData.ring, polyMouse, mouse.x, mouse.y)
                                onClicked: window._mapClicked(neighborData.number, mouse.modifiers)
                            }
                        }
                    }

                    // Подписи номеров у соседей
                    MapItemView {
                        model: window.neighbors
                        delegate: MapQuickItem {
                            property var neighborData: modelData
                            z: 5
                            coordinate: neighborData && neighborData.label
                                    ? QtPositioning.coordinate(neighborData.label.lat,
                                                               neighborData.label.lon)
                                    : QtPositioning.coordinate(0, 0)
                            visible: !!(coordinate.latitude !== 0
                                        || coordinate.longitude !== 0)
                            anchorPoint.x: label.width / 2
                            anchorPoint.y: label.height / 2
                            sourceItem: Rectangle {
                                id: label
                                width: lbl.implicitWidth + 10
                                height: lbl.implicitHeight + 4
                                radius: 3
                                color: Qt.rgba(0, 0, 0, 0.65)
                                border.color: window.neighborColor
                                border.width: 1
                                Text {
                                    id: lbl
                                    anchors.centerIn: parent
                                    // Номер по порядку — колонка «№» в таблице справа.
                                    text: neighborData ? neighborData.no : ""
                                    color: "white"
                                    font.pixelSize: theme.fontFootnote
                                }
                                // Внутри плашки, а не в MapQuickItem: у того нулевой
                                // размер, и anchors.fill давал область 0×0.
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: window._mapClicked(neighborData.number, mouse.modifiers)
                                    // На карте — только номер по порядку,
                                    // кадастровый номер — при наведении.
                                    ToolTip.visible: containsMouse && !!neighborData
                                    ToolTip.text: neighborData ? neighborData.number : ""
                                    ToolTip.delay: 200
                                }
                            }
                        }
                    }

                    // Легенда — крупная (k = 2): читается на снимке карты.
                    Rectangle {
                        id: legendBox
                        readonly property real k: 2
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.margins: theme.spacingMd
                        width: legendCol.implicitWidth + theme.spacingMd * 2 * k
                        height: legendCol.implicitHeight + theme.spacingMd * 2 * k
                        color: Qt.rgba(0, 0, 0, 0.55)
                        radius: 4 * k
                        // Слои: клик по значку — выбор цвета, «▨» — штриховка
                        // вкл/выкл (у буфера штриховки нет: она залила бы
                        // и исходный участок, и соседей).
                        Column {
                            id: legendCol
                            anchors.centerIn: parent
                            spacing: theme.spacingXs * legendBox.k
                            Repeater {
                                model: [
                                    { layer: "source", title: "Исходные (" + window.sourceRings.length + ")",
                                      color: window.sourceColor, hatch: window.sourceHatchOn, canHatch: true, fill: 0.10 },
                                    { layer: "buffer", title: "Буферная зона",
                                      color: window.bufferColor, hatch: false, canHatch: false, fill: 0.0 },
                                    { layer: "neighbor", title: "Участки в зоне",
                                      color: window.neighborColor, hatch: window.neighborHatchOn, canHatch: true, fill: 0.25 }
                                ]
                                delegate: Row {
                                    spacing: theme.spacingSm * legendBox.k
                                    LegendSwatch {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 16 * legendBox.k; height: 16 * legendBox.k
                                        swatchColor: modelData.color
                                        hatch: modelData.hatch
                                        fillOpacity: modelData.fill
                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                colorPopup.layer = modelData.layer
                                                colorPopup.open()
                                            }
                                            ToolTip.visible: containsMouse
                                            ToolTip.text: "Изменить цвет"
                                            ToolTip.delay: 300
                                        }
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.title
                                        color: "white"
                                        font.pixelSize: theme.fontFootnote * legendBox.k
                                    }
                                    Text {
                                        visible: modelData.canHatch
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "▨"
                                        color: "white"
                                        opacity: modelData.hatch ? 1.0 : 0.35
                                        font.pixelSize: theme.fontBody * legendBox.k
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -3
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: window.setLayerHatch(modelData.layer, !modelData.hatch)
                                            ToolTip.visible: containsMouse
                                            ToolTip.text: modelData.hatch ? "Убрать штриховку" : "Добавить штриховку"
                                            ToolTip.delay: 300
                                        }
                                    }
                                }
                            }
                            // Узоры видов участков — когда у «Участков в зоне»
                            // включена штриховка.
                            Repeater {
                                model: window.neighborHatchOn ? window.kindsPresent : []
                                delegate: Row {
                                    spacing: theme.spacingSm * legendBox.k
                                    leftPadding: theme.spacingMd * legendBox.k
                                    LegendSwatch {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 14 * legendBox.k; height: 14 * legendBox.k
                                        swatchColor: window.neighborColor
                                        hatch: modelData.angles.length > 0
                                        angles: modelData.angles
                                        fillOpacity: 0.25
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.title + " (" + modelData.count + ")"
                                        color: "white"
                                        font.pixelSize: theme.fontFootnote * legendBox.k
                                    }
                                }
                            }
                        }

                        // Палитра цвета слоя — над легендой.
                        Popup {
                            id: colorPopup
                            property string layer: ""
                            y: -implicitHeight - theme.spacingXs
                            padding: theme.spacingSm
                            background: Rectangle { color: theme.panel; border.color: theme.panelBorder; radius: 4 }
                            Grid {
                                columns: 6
                                spacing: theme.spacingXs
                                Repeater {
                                    model: window.layerPalette
                                    delegate: Rectangle {
                                        width: 22; height: 22; radius: 3
                                        color: modelData
                                        border.color: "#40000000"
                                        border.width: 1
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                window.setLayerColor(colorPopup.layer, modelData)
                                                colorPopup.close()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Таблица результатов
            Rectangle {
                SplitView.preferredWidth: 600
                SplitView.minimumWidth: 300
                color: theme.panel
                border.color: theme.panelBorder
                border.width: 1
                radius: 6
                clip: true

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: theme.spacingSm
                    spacing: theme.spacingXs

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: theme.spacingSm
                        Label {
                            Layout.fillWidth: true
                            text: "Участки в буфере" +
                                  (window.neighbors.length > 0
                                   ? " (" + window.neighbors.length + ")" : "")
                            color: theme.textPrimary
                            font.pixelSize: theme.fontBody
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        Button {
                            text: "Удалить" + (window.selectedCount > 0 ? " (" + window.selectedCount + ")" : "")
                            enabled: window.selectedCount > 0
                            onClicked: window.removeSelected()
                            ToolTip.visible: hovered
                            ToolTip.delay: 400
                            ToolTip.text: "Убрать выбранные участки с карты, из таблицы и отчёта.\n"
                                          + "Ctrl+клик — добавить к выбору, Shift+клик — диапазон,\n"
                                          + "Ctrl+A — все, Delete — удалить, Esc — снять выбор."
                        }
                        Button {
                            visible: window.removedNeighbors.length > 0
                            text: "Вернуть (" + window.removedNeighbors.length + ")"
                            onClicked: window.restoreRemoved()
                        }
                    }

                    // Шапка таблицы
                    Rectangle {
                        Layout.fillWidth: true
                        // Две строки: длинные заголовки переносятся, а не
                        // наезжают на соседние колонки.
                        implicitHeight: 40
                        color: theme.base
                        radius: 3
                        Row {
                            anchors.fill: parent
                            Repeater {
                                id: tableHeaderRepeater
                                model: headerColumns.length
                                delegate: Rectangle {
                                    width: headerColumns[index].width
                                    height: parent.height
                                    color: "transparent"
                                    Text {
                                        anchors.fill: parent
                                        anchors.leftMargin: 2
                                        anchors.rightMargin: 2
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                        text: headerColumns[index].label
                                             + (sortState.key === headerColumns[index].key
                                                ? (sortState.ascending ? " ▲" : " ▼") : "")
                                        color: theme.textPrimary
                                        font.pixelSize: theme.fontFootnote
                                        font.bold: true
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            var key = headerColumns[index].key
                                            // Повторный клик по той же колонке — обратный порядок;
                                            // новая колонка — по возрастанию, площадь — от большей.
                                            var asc = sortState.key === key ? !sortState.ascending
                                                                             : key !== "area"
                                            window._applySort(key, asc, false)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    ListView {
                        id: table
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: ListModel { id: rowsModel }
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar {}

                        delegate: Rectangle {
                            width: table.width
                            height: 26
                            color: window.isSelected(model.number)
                                   ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.25)
                                   : (index % 2 === 0 ? "transparent" : theme.background)
                            // Участок, показанный на карте, — рамкой.
                            border.color: theme.accent
                            border.width: window.highlightNumber === model.number ? 1 : 0
                            Row {
                                anchors.fill: parent
                                Text {
                                    width: headerColumns[0].width
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignHCenter
                                    text: model.n
                                    color: theme.textSecondary
                                    font.pixelSize: theme.fontFootnote
                                }
                                Text {
                                    width: headerColumns[1].width
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: model.number
                                    color: theme.textPrimary
                                    font.pixelSize: theme.fontFootnote
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: headerColumns[2].width
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignHCenter
                                    text: model.rumb
                                    color: theme.textPrimary
                                    font.pixelSize: theme.fontFootnote
                                }
                                Text {
                                    width: headerColumns[3].width
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignRight
                                    rightPadding: theme.spacingSm
                                    text: model.dist.toFixed(1).replace(".", ",")
                                    color: theme.textPrimary
                                    font.pixelSize: theme.fontFootnote
                                }
                                Text {
                                    width: headerColumns[4].width
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignRight
                                    rightPadding: theme.spacingSm
                                    text: Reports.fmtArea(model.area)
                                    color: theme.textPrimary
                                    font.pixelSize: theme.fontFootnote
                                }
                                Text {
                                    // Назначение — текст, часто длинный: по левому краю
                                    // с обрезкой. Полный текст виден в подсказке и в отчёте Word.
                                    width: headerColumns[5].width
                                    anchors.verticalCenter: parent.verticalCenter
                                    leftPadding: theme.spacingSm
                                    rightPadding: theme.spacingSm
                                    text: model.purpose ? model.purpose : "—"
                                    color: theme.textPrimary
                                    font.pixelSize: theme.fontFootnote
                                    elide: Text.ElideRight
                                    ToolTip.visible: purposeHover.hovered && model.purpose && model.purpose !== "—"
                                    ToolTip.text: model.purpose
                                    ToolTip.delay: 400
                                    HoverHandler { id: purposeHover }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: window._rowClicked(index, model.number, mouse.modifiers)
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: rowsModel.count === 0
                            text: window.busy ? "Загрузка…"
                                 : "Результаты появятся здесь"
                            color: theme.textTertiary
                            font.pixelSize: theme.fontBody
                        }
                    }
                }
            }
        }

        // -- Консоль -- скрыта, открывается по F12. Совсем не убрана:
        // это единственный канал диагностики (НСПД с машины разработки
        // недоступна, отказы тайлов и API видны только здесь).
        LogConsole {
            id: logPanel
            Layout.fillWidth: true
            visible: false
            expanded: true
        }
    }
}


