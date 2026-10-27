.pragma library

// Отчёт по соседним участкам в Word (.docx, форма раздела СЗЗ). Здесь —
// только XML частей документа; в zip их упаковывает
// exportFileHelper.writeZip (C++).
//
// Задание (task):
// { source_numbers: [..], buffer_m, provider,
//   rows: [{ number, rumb, distance_m, area_m2, purpose }] }

// ---------------------------------------------------------------
// Общее
// ---------------------------------------------------------------

function esc(s) {
    return String(s === undefined || s === null ? "" : s)
        // Управляющие символы недопустимы в XML 1.0 — Word не откроет файл.
        .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, "")
        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

function sourceNumbers(task) {
    var nums = task.source_numbers
    if (nums && nums.length !== undefined)
        return nums.filter(function (n) { return !!n }).map(String)
    return task.source_number ? [String(task.source_number)] : []
}

// "<первый номер>[+N] буфер <M> м.<ext>": все номера в имя не влезут,
// а без номера выгрузки затирали бы друг друга. Двоеточия в имени
// Windows запрещены — заменяются на "_".
function fileName(task, ext) {
    var nums = sourceNumbers(task)
    var stem = (nums.length ? nums[0] : "без_номера").replace(/[<>:"\/\\|?*]/g, "_").trim() || "без_номера"
    if (nums.length > 1) stem += "+" + (nums.length - 1)
    return stem + " буфер " + task.buffer_m + " м." + ext
}

var XML_HEAD = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
var REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
var PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"

// ---------------------------------------------------------------
// Word — форма раздела СЗЗ
// ---------------------------------------------------------------

// Порядок румбов — по часовой стрелке от севера.
var RUMB_ORDER = ["С", "СВ", "В", "ЮВ", "Ю", "ЮЗ", "З", "СЗ"]
var RUMB_ADJ = {
    "С": "северном", "СВ": "северо-восточном", "В": "восточном",
    "ЮВ": "юго-восточном", "Ю": "южном", "ЮЗ": "юго-западном",
    "З": "западном", "СЗ": "северо-западном"
}

// Территории с нормируемым качеством атмосферного воздуха (СанПиН
// 2.2.1/2.1.1.1200-03, п. 5.1) по ключевым словам назначения. Первое
// совпадение выигрывает. Ловушки корней снимаются заменой ДО проверки
// ("нежил", "транспорт"): \b и \w в JS не знают кириллицы, а lookbehind
// в движке Qt 5.15 не гарантирован.
var NORMED_KINDS = [
    ["образовательное учреждение", /образовательн|просвещ|школ|дошкольн|детск/],
    ["учреждение здравоохранения", /здравоохран|больниц|поликлин|медицин|лечебн|санатор/],
    ["садоводство", /садовод|огородн|(^|[^а-яё])дачн/],
    ["спортивное сооружение", /спорт/],
    ["зона отдыха", /рекреац|отдых|курорт/],
    ["жилая застройка", /жил|(^|[^а-яё])ижс([^а-яё]|$)|многоквартир|приусадеб/]
]

function normedKind(purpose) {
    var p = String(purpose || "").toLowerCase().replace(/нежил/g, " ").replace(/транспорт/g, " ")
    for (var i = 0; i < NORMED_KINDS.length; i++)
        if (NORMED_KINDS[i][1].test(p)) return NORMED_KINDS[i][0]
    return null
}

// Вид участка для штриховки на карте: нормируемые (по NORMED_KINDS) и
// основные ненормируемые группы. angles — направления линий узора в
// градусах (пусто — без штриховки), title — подпись в легенде.
var PARCEL_KINDS = [
    { kind: "residential", title: "Жилая застройка",               angles: [45] },
    { kind: "social",      title: "Образование, здравоохранение",  angles: [45, 135] },
    { kind: "garden",      title: "Садоводство, дачи",             angles: [135] },
    { kind: "recreation",  title: "Спорт, отдых",                  angles: [90] },
    { kind: "garage",      title: "Гаражи, стоянки",               angles: [0] },
    { kind: "industrial",  title: "Производство, склады",          angles: [0, 90] },
    { kind: "commercial",  title: "Торговля, офисы, сервис",       angles: [0, 45] },
    { kind: "public",      title: "Общего пользования, дороги",    angles: [] },
    { kind: "other",       title: "Прочее",                        angles: [] }
]

function parcelKindInfo(kind) {
    for (var i = 0; i < PARCEL_KINDS.length; i++)
        if (PARCEL_KINDS[i].kind === kind) return PARCEL_KINDS[i]
    return PARCEL_KINDS[PARCEL_KINDS.length - 1]
}

function parcelKind(purpose) {
    var normed = normedKind(purpose)
    if (normed === "жилая застройка") return "residential"
    if (normed === "образовательное учреждение" || normed === "учреждение здравоохранения") return "social"
    if (normed === "садоводство") return "garden"
    if (normed) return "recreation"
    var p = String(purpose || "").toLowerCase()
    if (/гараж|автостоян|стоянк|автотранспорт/.test(p)) return "garage"
    if (/общего пользования|уличн|дорог|проезд|благоустр|(^|[^0-9.])12\.0/.test(p)) return "public"
    if (/производств|склад|промышл|коммунальн|энергет|сельскохоз|переработ|котельн|трансформатор|недропольз/.test(p)) return "industrial"
    if (/торгов|магазин|предприним|офис|делов|обслуживан|административ|придорож|общественн|рынок|бытов/.test(p)) return "commercial"
    return "other"
}

// Метры до целых, половина — вверх.
function roundM(d) { return Math.floor(Number(d || 0) + 0.5) }

// "около N метра/метров" — родительный падеж после "около".
function metersGen(n) { return (n % 10 === 1 && n % 100 !== 11) ? "метра" : "метров" }

function rumbKey(rumb) {
    var i = RUMB_ORDER.indexOf(rumb)
    return i < 0 ? RUMB_ORDER.length : i
}

// 12345.6 → "12 346" (неразрывный пробел между тысячами); 0 — "—".
// Группы — вручную: replace(/\B(?=(\d{3})+(?!\d))/g) в движке Qt 5.15
// вставляет разделитель дважды ("1  234  567"), в node — нет.
function fmtArea(a) {
    if (!a) return "—"
    var s = String(Math.floor(a + 0.5)), out = ""
    for (var i = 0; i < s.length; i++) {
        if (i > 0 && (s.length - i) % 3 === 0) out += " "
        out += s.charAt(i)
    }
    return out
}

function buildIntro(rows) {
    var byRumb = {}
    rows.forEach(function (r) {
        var kind = normedKind(r.purpose)
        if (!kind) return
        if (!byRumb[r.rumb]) byRumb[r.rumb] = []
        byRumb[r.rumb].push({ r: r, kind: kind })
    })
    var rumbs = Object.keys(byRumb).sort(function (a, b) { return rumbKey(a) - rumbKey(b) })
    if (!rumbs.length)
        return "В пределах ориентировочной СЗЗ территории с нормируемым качеством атмосферного воздуха не выявлены."

    var parts = rumbs.map(function (rumb) {
        var items = byRumb[rumb]
        var d = Math.min.apply(null, items.map(function (it) { return it.r.dist }))
        // Все участки на ближайшем (округлённом) расстоянии.
        var nearest = items.filter(function (it) { return it.r.dist === d })
        var kinds = []
        nearest.forEach(function (it) { if (kinds.indexOf(it.kind) < 0) kinds.push(it.kind) })
        var where = "в " + (RUMB_ADJ[rumb] || rumb) + " направлении"
        var dist = d === 0 ? "непосредственно у границы предприятия"
                           : "на расстоянии около " + d + " " + metersGen(d)
        return where + " " + dist + " — " + kinds.join(", ") +
               " (ЗУ " + nearest.map(function (it) { return "№" + it.r.number }).join(", ") + ")"
    })
    var text = "Ближайшие территории с нормируемым качеством атмосферного воздуха расположены " +
               parts.join("; ") + "."
    var rest = RUMB_ORDER.filter(function (r) { return !byRumb[r] }).map(function (r) { return RUMB_ADJ[r] })
    if (rest.length)
        text += " В остальных направлениях (" + rest.join(", ") +
                ") в пределах ориентировочной СЗЗ нормируемые объекты не выявлены."
    return text
}

var W_NS = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'

// Ширины колонок, dxa (1/20 pt): в сумме — ширина текста A4 при полях
// образца (11906 - 1701 - 850).
var DOCX_COL_WIDTHS = [680, 1250, 2150, 2850, 1150, 1275]
var DOCX_HEADERS = ["№ п/п", "Направление по румбам", "Кадастровый номер земельного участка",
                    "Вид объекта (назначение по ЕГРН)", "Площадь, м²",
                    "Расстояние до границ предприятия, м"]

function wRun(text) { return '<w:r><w:t xml:space="preserve">' + esc(text) + '</w:t></w:r>' }
function wPar(text) { return '<w:p>' + wRun(text) + '</w:p>' }

function wCell(text, width, numbered) {
    // pStyle обязан идти в pPr первым (порядок элементов схемы OOXML).
    var num = numbered ? '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>' : ""
    return '<w:tc><w:tcPr><w:tcW w:w="' + width + '" w:type="dxa"/><w:vAlign w:val="center"/></w:tcPr>' +
           '<w:p><w:pPr><w:pStyle w:val="TableText"/>' + num + '</w:pPr>' + (text ? wRun(text) : "") + '</w:p></w:tc>'
}

function wTable(rows) {
    var grid = DOCX_COL_WIDTHS.map(function (w) { return '<w:gridCol w:w="' + w + '"/>' }).join("")
    var head = '<w:tr><w:trPr><w:tblHeader/><w:jc w:val="center"/></w:trPr>' +
               DOCX_HEADERS.map(function (h, i) { return wCell(h, DOCX_COL_WIDTHS[i]) }).join("") + '</w:tr>'
    var body = rows.map(function (r) {
        var vals = ["", r.rumb, r.number, r.purpose || "—", fmtArea(r.area), String(r.dist)]
        return '<w:tr><w:trPr><w:cantSplit/><w:jc w:val="center"/></w:trPr>' +
               vals.map(function (v, i) { return wCell(v, DOCX_COL_WIDTHS[i], i === 0) }).join("") + '</w:tr>'
    }).join("")
    var borders = ["top", "left", "bottom", "right", "insideH", "insideV"].map(function (s) {
        return '<w:' + s + ' w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
    }).join("")
    return '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:jc w:val="center"/>' +
           '<w:tblBorders>' + borders + '</w:tblBorders><w:tblLook w:val="04A0"/></w:tblPr>' +
           '<w:tblGrid>' + grid + '</w:tblGrid>' + head + body + '</w:tbl>'
}

// Строки задания → строки отчёта: целые метры, по площади от большей к
// меньшей (без площади — в конце), при равной площади — по расстоянию.
function docxRows(task) {
    var rows = (task.rows || []).map(function (r) {
        return {
            number: String(r.number || ""),
            rumb: r.rumb || "—",
            dist: roundM(r.distance_m),
            area: Number(r.area_m2) || 0,
            purpose: String(r.purpose || "").trim()
        }
    })
    rows.sort(function (a, b) {
        return (b.area - a.area) || (a.dist - b.dist) || (a.number < b.number ? -1 : a.number > b.number ? 1 : 0)
    })
    return rows
}

// Normal — как в образце отчёта: Times New Roman 14, интервал 1,5,
// отступ 1 см, по ширине. TableText — 12 pt, одинарный, по центру.
var DOCX_STYLES = XML_HEAD + '<w:styles ' + W_NS + '>' +
    '<w:docDefaults><w:rPrDefault><w:rPr>' +
    '<w:rFonts w:ascii="Times New Roman" w:eastAsia="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/>' +
    '<w:sz w:val="28"/><w:szCs w:val="28"/><w:lang w:val="ru-RU" w:eastAsia="ru-RU"/>' +
    '</w:rPr></w:rPrDefault><w:pPrDefault/></w:docDefaults>' +
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/>' +
    '<w:pPr><w:spacing w:after="0" w:line="360" w:lineRule="auto"/><w:ind w:firstLine="567"/><w:jc w:val="both"/></w:pPr></w:style>' +
    '<w:style w:type="paragraph" w:customStyle="1" w:styleId="TableText"><w:name w:val="Table Text"/><w:basedOn w:val="Normal"/>' +
    '<w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:ind w:firstLine="0"/><w:jc w:val="center"/></w:pPr>' +
    '<w:rPr><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>' +
    '</w:styles>'

// Автонумерация "1." в первой колонке — строки можно удалять/вставлять в
// Word без ручной перенумерации. lvlJc="center" НЕЛЬЗЯ: при отступе 0
// Word центрирует номер вокруг левого края ячейки и он не виден. Поэтому
// left без табуляции (suff nothing), по центру ставит jc стиля TableText.
var DOCX_NUMBERING = XML_HEAD + '<w:numbering ' + W_NS + '>' +
    '<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="singleLevel"/>' +
    '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/>' +
    '<w:suff w:val="nothing"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/>' +
    '<w:pPr><w:ind w:left="0" w:firstLine="0"/></w:pPr></w:lvl></w:abstractNum>' +
    '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>'

function buildDocx(task) {
    var rows = docxRows(task)
    var body = wPar(buildIntro(rows)) + wPar("") +
        wPar("Земельные участки, расположенные в пределах ориентировочной СЗЗ.") +
        wTable(rows) + '<w:p/>' +
        // Поля и формат страницы — из образца (A4, 3/1,5/2/2 см).
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>' +
        '<w:pgMar w:top="1134" w:right="850" w:bottom="1134" w:left="1701" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>'
    return {
        "[Content_Types].xml": XML_HEAD +
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
            '<Default Extension="xml" ContentType="application/xml"/>' +
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
            '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>' +
            '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>' +
            '</Types>',
        "_rels/.rels": XML_HEAD + '<Relationships xmlns="' + PKG_REL_NS + '">' +
            '<Relationship Id="rId1" Type="' + REL_NS + '/officeDocument" Target="word/document.xml"/></Relationships>',
        "word/_rels/document.xml.rels": XML_HEAD + '<Relationships xmlns="' + PKG_REL_NS + '">' +
            '<Relationship Id="rId1" Type="' + REL_NS + '/styles" Target="styles.xml"/>' +
            '<Relationship Id="rId2" Type="' + REL_NS + '/numbering" Target="numbering.xml"/></Relationships>',
        "word/document.xml": XML_HEAD + '<w:document ' + W_NS + ' xmlns:r="' + REL_NS + '"><w:body>' +
            body + '</w:body></w:document>',
        "word/styles.xml": DOCX_STYLES,
        "word/numbering.xml": DOCX_NUMBERING
    }
}
