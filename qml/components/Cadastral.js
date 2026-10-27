.pragma library
.import "GeoMath.js" as GeoMath

// .import обязателен: .pragma library изолирует модуль, и импорты
// из Main.qml сюда НЕ попадают. Без этой строки проверка
// typeof GeoMath !== "undefined" в parcelFromFeature всегда ложна,
// контур не вычисляется, и найденный участок выглядит ненайденным.

var _pendingHttp = {};
var USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";
var REFERER_NSPD = "https://nspd.gov.ru/map?thematic=PKK";
var REFERER_PKK = "https://pkk.rosreestr.ru/";

// http — объект cadastralHttp, он приходит ПАРАМЕТРОМ: этот файл объявлен
// .pragma library, а такие модули не видят контекст QML, поэтому до
// contextProperty из main.cpp здесь не достать (раньше проверка
// typeof cadastralHttp всегда срабатывала и запрос не уходил).
function _httpCall(http, url, referer, userAgent, timeoutMs, cb) {
    if (!http) {
        if (cb) cb({status: 0, body: "", error: "cadastralHttp недоступен"});
        return 0;
    }
    try {
        var id = http.get(url, referer || "", userAgent || USER_AGENT, timeoutMs || 20000);
        if (id <= 0) {
            if (cb) cb({status: 0, body: "", error: "не удалось запустить запрос"});
            return 0;
        }
        _pendingHttp[id] = cb;
        return id;
    } catch (e) {
        if (cb) cb({status: 0, body: "", error: String(e)});
        return 0;
    }
}

function _onHttpFinished(id, status, body, contentType, error) {
    var cb = _pendingHttp[id];
    if (!cb) return;
    delete _pendingHttp[id];
    cb({status: status, body: body || "", contentType: contentType || "", error: error || ""});
}

// Поиск одного участка ПО КАДАСТРОВОМУ НОМЕРУ — цепочка провайдеров
var searchProviders = [
    {
        name: "НСПД",
        referer: REFERER_NSPD,
        buildUrl: function (number) {
            return "https://nspd.gov.ru/api/geoportal/v2/search/geoportal?query=" + encodeURIComponent(number) + "&thematicSearchId=1";
        }
    },
    // ПКК из цепочки убрана: pkk.rosreestr.ru/api/features/1 больше не API.
    // Проверено 22.10.2026 с машины оператора: хост переадресует на
    // НСПД и отдаёт HTTP 200 с text/html — HTML-оболочку веб-карты,
    // а не JSON. Держать его в цепочке значит только тратить время и сорить в лог.
];

// --- Поиск соседей: НСПД /intersects -----------------------------
// Замена умершего bbox-поиска ПКК. Адрес и формат тела сняты
// с собственного веб-клиента НСПД (его инструмент «найти пересечения»
// делает ровно такой запрос). Это POST с JSON, поэтому в CadastralHttp
// добавлен post().
var INTERSECTS_URL = "https://nspd.gov.ru/api/geoportal/v1/intersects?typeIntersect=fullObject";

// Слой «Земельные участки». Ид виден в запросах самого НСПД
// (categories:[{id:36368}] и .../favorites-geom-object-check/36368/...).
var PARCEL_CATEGORY_ID = 36368;

function _httpPost(http, url, referer, userAgent, timeoutMs, body, cb) {
    if (!http || !http.post) {
        if (cb) cb({status: 0, body: "", error: "cadastralHttp.post недоступен"});
        return 0;
    }
    try {
        var id = http.post(url, referer || "", userAgent || USER_AGENT, timeoutMs || 45000, body);
        if (id <= 0) {
            if (cb) cb({status: 0, body: "", error: "не удалось запустить запрос"});
            return 0;
        }
        _pendingHttp[id] = cb;
        return id;
    } catch (e) {
        if (cb) cb({status: 0, body: "", error: String(e)});
        return 0;
    }
}

// Тело POST: одно кольцо в EPSG:3857. Кольцо ЗАМЫКАЕМ — GeoJSON
// требует совпадения первой и последней вершины, а boundsToRing отдаёт
// контур без дубля.
//
// НСПД в своём запросе кладёт вторым кольцом сам участок (дырка),
// чтобы исключить его из выборки. Мы так не делаем нарочно: одно
// кольцо — заведомо надмножество результатов, а исходный участок
// приложение и так отбрасывает по номеру, а лишние — по реальному
// зазору. Неверная намотка дырки могла бы тихо урезать выборку.
function buildIntersectsBody(ringLatLon) {
    var coords = [];
    for (var i = 0; i < ringLatLon.length; i++) {
        var m = GeoMath.latLonToWebMercator(ringLatLon[i].lat, ringLatLon[i].lon);
        coords.push([m.x, m.y]);
    }
    if (coords.length > 0)
        coords.push([coords[0][0], coords[0][1]]);
    return JSON.stringify({
        geom: {
            type: "FeatureCollection",
            features: [{
                type: "Feature",
                geometry: {
                    crs: { type: "name", properties: { name: "EPSG:3857" } },
                    type: "Polygon",
                    coordinates: [coords]
                },
                properties: {}
            }]
        },
        categories: [{ id: PARCEL_CATEGORY_ID }]
    });
}

// Массив features из ответа любого из провайдеров
function featuresFromResponse(data) {
    if (!data || typeof data !== "object") return [];
    if (data.data && data.data.features && data.data.features.length !== undefined) return data.data.features;
    if (data.features && data.features.length !== undefined) return data.features;
    if (data.data && data.data.features && data.data.features.features) return data.data.features.features;
    return [];
}

// Кадастровый номер ЦЕЛИКОМ: регион:район:квартал:участок.
//
// Было /\d{2}:\d{2}:\d+/ — всего ТРИ группы, из-за чего номер
// обрезался до кадастрового квартала: вместо 38:00:000000:100
// в таблицу и в Excel попадало 38:00:000000. Четвёртая группа
// необязательная: сам квартал тоже бывает объектом поиска.
var CAD_NUM_RE = /\d{1,3}:\d{1,3}:\d{1,8}(?::\d{1,8})?/;

function extractNumber(f) {
    var attrs = f && (f.attrs || f.attributes || f.properties || {});
    var opts = (attrs.options) ? attrs.options : {};
    var candidates = [opts.cad_num, attrs.cn, attrs.cid, attrs.id, attrs.cadNumber, attrs.cad_num, attrs.number];
    for (var k in attrs) {
        var v = attrs[k];
        if (v && typeof v === "object") {
            candidates.push(v.cn, v.cid, v.id, v.cadNumber, v.cad_num);
        }
    }
    for (var i = 0; i < candidates.length; i++) {
        var c = candidates[i];
        if (typeof c === "string" && CAD_NUM_RE.test(c)) {
            var m = c.match(CAD_NUM_RE);
            if (m) return m[0];
        }
    }
    if (f && f.id && typeof f.id === "string" && CAD_NUM_RE.test(f.id)) {
        var m2 = f.id.match(CAD_NUM_RE);
        if (m2) return m2[0];
    }
    return "";
}

// Площадь (м², если провайдер её отдаёт). В гектарах считается ТОЛЬКО
// поле area_ha. Прежняя эвристика "число <= 100 — это га" превращала
// гаражный участок 24 м² в 240 000 м² и ломала сортировку по площади.
// Единицы остальных полей НСПД (м²) по логу не подтверждены — см. §9 AGENTS.md.
function extractAreaM2(f) {
    var attrs = f && (f.attrs || f.attributes || f.properties || {});
    var opts = (attrs.options) ? attrs.options : {};
    var candidates = [opts.declared_area, opts.land_record_area, opts.specified_area, attrs.area, attrs.landRecordArea, attrs.square, attrs.square_m];
    for (var k in attrs) {
        var v = attrs[k];
        if (v && typeof v === "object")
            candidates.push(v.area, v.landRecordArea, v.square);
    }
    function num(c) {
        if (typeof c === "number") return c;
        if (typeof c === "string") return parseFloat(c.replace(",", "."));
        return NaN;
    }
    for (var i = 0; i < candidates.length; i++) {
        var n = num(candidates[i]);
        if (isFinite(n) && n > 0) return n;
    }
    var ha = num(attrs.area_ha);
    if (isFinite(ha) && ha > 0) return Math.round(ha * 10000);
    return 0;
}

// Назначение участка.
//
// «Назначением» в отчётах обычно называют РАЗРЕШЁННОЕ
// ИСПОЛЬЗОВАНИЕ; если источник его не отдал — берём КАТЕГОРИЮ
// ЗЕМЕЛЬ. Имена полей у НСПД не документированы и менялись,
// поэтому список кандидатов широкий, а в конце — поиск по шаблону
// ключа. Фактические ключи первого соседа пишутся в консоль
// (dumpAttrKeys) — без этого угадывать имена пришлось бы слепо.
var PURPOSE_KEYS = [
    "permitted_use_established_by_document", "permitted_use", "permittedUse",
    "permitted_use_text", "util_by_doc", "utilByDoc", "land_use", "landUse",
    "use_by_doc", "allowed_use"
];
var CATEGORY_KEYS = [
    "land_record_category_type", "category_type", "categoryType",
    "land_category", "category"
];

function _firstString(obj, keys) {
    if (!obj) return "";
    for (var i = 0; i < keys.length; i++) {
        var v = obj[keys[i]];
        if (typeof v === "string" && v.replace(/^\s+|\s+$/g, "").length > 1)
            return v.replace(/^\s+|\s+$/g, "");
    }
    return "";
}

function _attrsOf(f) {
    return f && (f.attrs || f.attributes || f.properties || {});
}

function extractPurpose(f) {
    var attrs = _attrsOf(f);
    var opts = attrs.options ? attrs.options : {};
    var v = _firstString(opts, PURPOSE_KEYS) || _firstString(attrs, PURPOSE_KEYS);
    if (v) return v;
    v = _firstString(opts, CATEGORY_KEYS) || _firstString(attrs, CATEGORY_KEYS);
    if (v) return v;
    // Последняя попытка: любой ключ, похожий на назначение.
    var re = /(permit|util|use|categor|назнач|категор|использ)/i;
    var pools = [opts, attrs];
    for (var pi = 0; pi < pools.length; pi++) {
        for (var k in pools[pi]) {
            var val = pools[pi][k];
            if (typeof val !== "string") continue;
            var t = val.replace(/^\s+|\s+$/g, "");
            if (re.test(k) && t.length > 1 && t.length < 300) return t;
        }
    }
    return "";
}

// Диагностика: какие поля источник вообще прислал.
function dumpAttrKeys(f) {
    var attrs = _attrsOf(f);
    var opts = attrs.options ? attrs.options : {};
    var out = [];
    function add(prefix, obj) {
        for (var k in obj) {
            var v = obj[k];
            if (v === null) { out.push(prefix + k + "=null"); continue; }
            if (typeof v === "object") { out.push(prefix + k + "=<obj>"); continue; }
            var sv = String(v);
            if (sv.length > 60) sv = sv.substring(0, 60) + "…";
            out.push(prefix + k + "=" + sv);
        }
    }
    add("", attrs);
    add("options.", opts);
    return out.length ? out.join(" | ") : "(полей нет)";
}

// Что за геометрия пришла — для диагностики «участок есть, контура нет».
// Возвращает строку вида "Polygon", "Point", "нет поля geometry".
function geometryKind(f) {
    var geom = f && (f.geometry || (f.feature && f.feature.geometry));
    if (!geom) return "нет поля geometry";
    var t = geom.type ? String(geom.type) : "без type";
    if (!geom.coordinates) return t + ", нет coordinates";
    var crs = (geom.crs && geom.crs.properties && geom.crs.properties.name) || "crs не указан";
    var n = 0;
    try {
        if (t === "Polygon") n = geom.coordinates[0].length;
        else if (t === "MultiPolygon") {
            for (var p = 0; p < geom.coordinates.length; p++) n += geom.coordinates[p][0].length;
            t += " из " + geom.coordinates.length + " частей";
        }
    } catch (e) { n = -1; }
    return t + ", вершин " + n + ", " + crs;
}

// Feature → {number, ring, area} либо null
function parcelFromFeature(f) {
    var ring = null;
    // Все контуры участка: многоконтурный (MultiPolygon) — несколько.
    // ring — самый большой из них.
    var rings = [];
    if (typeof GeoMath !== "undefined" && GeoMath.cadastralGeometryToRings) {
        rings = GeoMath.cadastralGeometryToRings(f && (f.geometry || f));
        ring = GeoMath.largestRing(rings);
    }
    if (!ring) {
        var geom = f && (f.geometry || (f.feature && f.feature.geometry));
        if (geom && geom.type === "Point") {
            // Only have point - can't form ring. Return null to let fallback work.
            return null;
        }
    }
    if (!ring) return null;
    var number = extractNumber(f);
    // area — площадь из атрибутов НСПД (м²): у многоконтурного участка
    // это площадь всех частей, а не только ring.
    return {
        number: number,
        ring: ring,
        rings: rings,
        area: extractAreaM2(f),
        purpose: extractPurpose(f)
    };
}

