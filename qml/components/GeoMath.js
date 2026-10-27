.pragma library

// Геометрия KadBuffer: локальная проекция вокруг центроида, зазор между
// контурами, буферная зона, румб, штриховка и точка подписи участка.
// Без доступа к QML-контексту — поэтому .pragma library.

// Локальная проекция вокруг (lat0, lon0) — площадка в десятки/сотни
// метров, погрешностью проекции на таком масштабе пренебрегаем.
function projectLocal(lat, lon, lat0, lon0) {
    var mPerDegLat = 111320.0
    var mPerDegLon = 111320.0 * Math.cos(lat0 * Math.PI / 180)
    return { x: (lon - lon0) * mPerDegLon, y: (lat - lat0) * mPerDegLat }
}
function unprojectLocal(x, y, lat0, lon0) {
    var mPerDegLat = 111320.0
    var mPerDegLon = 111320.0 * Math.cos(lat0 * Math.PI / 180)
    return { lat: lat0 + y / mPerDegLat, lon: lon0 + x / mPerDegLon }
}
function pointInPolygonXY(point, polygon) {
    if (!point || !polygon || polygon.length < 3) return false
    var inside = false
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
        var pi = polygon[i], pj = polygon[j]
        var crosses = ((pi.y > point.y) !== (pj.y > point.y))
                && (point.x < (pj.x - pi.x) * (point.y - pi.y) / ((pj.y - pi.y) || 1e-9) + pi.x)
        if (crosses) inside = !inside
    }
    return inside
}
// Кратчайшее расстояние от точки до отрезка [a,b] — база для
// "минимум N м от границы/здания" (простого point-in-polygon недостаточно:
// он не запрещает точку в 1 см от линии).
function distToSegmentXY(p, a, b) {
    var dx = b.x - a.x, dy = b.y - a.y
    var len2 = dx * dx + dy * dy
    var t = len2 > 1e-12 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0
    t = Math.max(0, Math.min(1, t))
    var cx = a.x + dx * t, cy = a.y + dy * t
    var ddx = p.x - cx, ddy = p.y - cy
    return Math.sqrt(ddx * ddx + ddy * ddy)
}
function distToPolygonEdgeXY(p, polygon) {
    var best = Infinity
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
        var d = distToSegmentXY(p, polygon[j], polygon[i])
        if (d < best) best = d
    }
    return best
}

function haversineM(lat1, lon1, lat2, lon2) {
    var R = 6371000
    var toRad = Math.PI / 180
    var dLat = (lat2 - lat1) * toRad, dLon = (lon2 - lon1) * toRad
    var a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
            + Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) * Math.sin(dLon / 2) * Math.sin(dLon / 2)
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

// Контур кадастрового участка (GeoJSON Polygon/MultiPolygon) → [{lat,lon}].
// ВАЖНО: НСПД отдаёт geometry.coordinates в EPSG:3857 (метры Web Mercator,
// x/y порядка миллионов), а не в градусах 4326 — как crs внутри geometry,
// так и просто по величине координат. Если этого не учесть, вершины уходят
// за диапазон ±180/±90: карта улетает на мировой зум, а граница не видна.
function webMercatorToLatLon(x, y) {
    var R = 6378137.0
    var lon = x / R * 180.0 / Math.PI
    var lat = (2.0 * Math.atan(Math.exp(y / R)) - Math.PI / 2.0) * 180.0 / Math.PI
    return { lat: lat, lon: lon }
}
// Обратная к webMercatorToLatLon: градусы → EPSG:3857. Нужна для
// запросов к ПКК — она и отдаёт, и принимает геометрию в метрах Web Mercator.
function latLonToWebMercator(lat, lon) {
    var R = 6378137.0
    var x = lon * Math.PI / 180.0 * R
    var y = Math.log(Math.tan(Math.PI / 4.0 + lat * Math.PI / 360.0)) * R
    return { x: x, y: y }
}
// Все внешние контуры геометрии НСПД: у Polygon — один, у MultiPolygon —
// по одному на часть. Многоконтурные участки (гаражные кооперативы,
// линейные объекты) приходят MultiPolygon'ом; раньше бралась только
// первая часть, и большой участок рисовался и мерился одним мелким
// контуром. Отверстия (внутренние кольца) не учитываются.
function cadastralGeometryToRings(geom) {
    if (!geom || !geom.coordinates) return []
    var polys
    if (geom.type === "Polygon") polys = [geom.coordinates]
    else if (geom.type === "MultiPolygon") polys = geom.coordinates
    else return []
    var crsName = (geom.crs && geom.crs.properties && geom.crs.properties.name) || ""
    var isMercator = String(crsName).indexOf("3857") >= 0
    var rings = []
    for (var p = 0; p < polys.length; p++) {
        var coords = polys[p] && polys[p][0]
        if (!coords || coords.length < 3) continue
        var ring = []
        for (var i = 0; i < coords.length; i++) {
            var c = coords[i]
            if (!c || c.length < 2) continue
            var x = c[0], y = c[1]
            if (typeof x !== "number" || typeof y !== "number" || isNaN(x) || isNaN(y)) continue
            if (isMercator || Math.abs(x) > 180 || Math.abs(y) > 90)
                ring.push(webMercatorToLatLon(x, y))
            else
                ring.push({ lat: y, lon: x })
        }
        if (ring.length >= 3) rings.push(ring)
    }
    return rings
}

// Самый большой контур — для мест, где нужен один (лог, совместимость).
function cadastralGeometryToRing(geom) {
    return largestRing(cadastralGeometryToRings(geom))
}

// Площадь контура, м² (локальная проекция, шнурок Гаусса).
function ringAreaM2(ring) {
    if (!ring || ring.length < 3) return 0
    var lat0 = ring[0].lat, lon0 = ring[0].lon, a = 0
    for (var i = 0; i < ring.length; i++) {
        var p = projectLocal(ring[i].lat, ring[i].lon, lat0, lon0)
        var q = projectLocal(ring[(i + 1) % ring.length].lat, ring[(i + 1) % ring.length].lon, lat0, lon0)
        a += p.x * q.y - q.x * p.y
    }
    return Math.abs(a) / 2
}

function largestRing(rings) {
    var best = null, bestA = -1
    for (var i = 0; i < (rings || []).length; i++) {
        var a = ringAreaM2(rings[i])
        if (a > bestA) { bestA = a; best = rings[i] }
    }
    return best
}

// Центроид нескольких контуров — взвешенный по их площади.
function centroidOfRings(rings) {
    var sw = 0, lat = 0, lon = 0
    for (var i = 0; i < (rings || []).length; i++) {
        var w = ringAreaM2(rings[i])
        var c = centroidOfRing(rings[i])
        lat += c.lat * w; lon += c.lon * w; sw += w
    }
    if (sw > 0) return { lat: lat / sw, lon: lon / sw }
    return rings && rings.length ? centroidOfRing(rings[0]) : null
}

// ------------------------------------------------------------------
// Дополнения для «Буфер участка»: румбы, зазор между контурами,
// буферная зона. Та же локальная равнопрямоугольная проекция
// (projectLocal) — на масштабах участка в десятки/сотни метров её
// погрешностью пренебрегаем, как и весь остальной модуль.
// ------------------------------------------------------------------

// Bbox кольца [{lat,lon}] → {minLat,maxLat,minLon,maxLon}.
function ringBbox(ring) {
    var minLat = ring[0].lat, maxLat = ring[0].lat
    var minLon = ring[0].lon, maxLon = ring[0].lon
    for (var i = 1; i < ring.length; i++) {
        minLat = Math.min(minLat, ring[i].lat); maxLat = Math.max(maxLat, ring[i].lat)
        minLon = Math.min(minLon, ring[i].lon); maxLon = Math.max(maxLon, ring[i].lon)
    }
    return { minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon }
}

// Центроид полигона (площадной, по шнуру Гаусса) в градусах.
// Вырожденный случай (нулевая площадь) — среднее вершин.
function centroidOfRing(ring) {
    var lat0 = 0, lon0 = 0
    for (var i = 0; i < ring.length; i++) { lat0 += ring[i].lat; lon0 += ring[i].lon }
    lat0 /= ring.length; lon0 /= ring.length
    // Координаты — ОТНОСИТЕЛЬНО средней точки: произведения полных
    // градусов (104° × 52°) теряли точность на вычитании, и центроид
    // уезжал на метры (у полосы 1 м — на 6 м вбок).
    var a = 0, cx = 0, cy = 0
    for (i = 0; i < ring.length; i++) {
        var p = ring[i], q = ring[(i + 1) % ring.length]
        var px = p.lon - lon0, py = p.lat - lat0
        var qx = q.lon - lon0, qy = q.lat - lat0
        var cross = px * qy - qx * py
        a += cross
        cx += (px + qx) * cross
        cy += (py + qy) * cross
    }
    if (Math.abs(a) < 1e-24)
        return { lat: lat0, lon: lon0 }
    a *= 3.0
    return { lat: lat0 + cy / a, lon: lon0 + cx / a }
}

// Кратчайшее расстояние между двумя ОТРЕЗКАМИ [a,b] и [c,d] в XY.
// Классическая формула: минимум из четырёх «точка–отрезок» (если
// отрезки не пересекаются), иначе 0 (пересечение зафиксировано
// знаками произведений параметров).
function _segSegDistXY(a, b, c, d) {
    function cross(ox, oy, px, py, qx, qy) {
        return (px - ox) * (qy - oy) - (py - oy) * (qx - ox)
    }
    var d1 = cross(c.x, c.y, d.x, d.y, a.x, a.y)
    var d2 = cross(c.x, c.y, d.x, d.y, b.x, b.y)
    var d3 = cross(a.x, a.y, b.x, b.y, c.x, c.y)
    var d4 = cross(a.x, a.y, b.x, b.y, d.x, d.y)
    if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
            ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)))
        return 0
    var best = Infinity
    var candidates = [
        distToSegmentXY(a, c, d), distToSegmentXY(b, c, d),
        distToSegmentXY(c, a, b), distToSegmentXY(d, a, b)
    ]
    for (var i = 0; i < candidates.length; i++)
        if (candidates[i] < best) best = candidates[i]
    return best
}

// Минимальный зазор (в метрах) между двумя замкнутыми контурами —
// минимум по всем парам рёбер в ОДНОЙ локальной проекции (вокруг
// общего центроида). Касание/пересечение → 0.
function minDistanceRingsM(ringA, ringB) {
    if (!ringA || !ringB || ringA.length < 2 || ringB.length < 2)
        return Infinity
    var lat0 = 0, lon0 = 0, i
    for (i = 0; i < ringA.length; i++) { lat0 += ringA[i].lat; lon0 += ringA[i].lon }
    for (i = 0; i < ringB.length; i++) { lat0 += ringB[i].lat; lon0 += ringB[i].lon }
    lat0 /= (ringA.length + ringB.length)
    lon0 /= (ringA.length + ringB.length)
    function toXY(ring) {
        var xy = []
        for (var k = 0; k < ring.length; k++)
            xy.push(projectLocal(ring[k].lat, ring[k].lon, lat0, lon0))
        return xy
    }
    var a = toXY(ringA), b = toXY(ringB)
    var best = Infinity
    for (i = 0; i < a.length && best > 0; i++) {
        var a1 = a[i], a2 = a[(i + 1) % a.length]
        for (var j = 0; j < b.length && best > 0; j++) {
            var d = _segSegDistXY(a1, a2, b[j], b[(j + 1) % b.length])
            if (d < best) best = d
        }
    }
    // Один контур целиком внутри другого (редко, но бывает: дачный
    // участок внутри большого) — зазора «между границами» нет, 0.
    if (best > 0 && (pointInPolygonXY(projectToRingFrame(ringA[0], b, lat0, lon0), b) ||
                     pointInPolygonXY(projectToRingFrame(ringB[0], a, lat0, lon0), a)))
        return 0
    return best
}

function projectToRingFrame(p, xyRing, lat0, lon0) {
    return projectLocal(p.lat, p.lon, lat0, lon0)
}

// Азимут (градусы от севера, по часовой) от точки 1 к точке 2 —
// через локальную проекцию (для расстояний в сотни метров точности
// достаточно; на глобальном масштабе модуль и не применяется).
function azimuthDeg(lat1, lon1, lat2, lon2) {
    var p1 = projectLocal(lat1, lon1, lat1, lon1)
    var p2 = projectLocal(lat2, lon2, lat1, lon1)
    var az = Math.atan2(p2.x, p2.y) * 180.0 / Math.PI
    if (az < 0) az += 360.0
    return az
}

// Азимут → румб (8 сторон горизонта, сектор ±22.5°): С, СВ, В, ЮВ,
// Ю, ЮЗ, З, СЗ. Стандартное землемерное приведение.
function rumbFromAzimuth(az) {
    var names = ["С", "СВ", "В", "ЮВ", "Ю", "ЮЗ", "З", "СЗ"]
    var idx = Math.round(((az % 360) + 360) % 360 / 45.0) % 8
    return names[idx]
}

// Румб между двумя точками (центроиды участков).
function rumbBetween(lat1, lon1, lat2, lon2) {
    return rumbFromAzimuth(azimuthDeg(lat1, lon1, lat2, lon2))
}

// Bbox {south,north,west,east} + буфер в метрах → тот же bbox,
// расширенный ровно на буфер (метры → градусы через широту центра).
function expandBoundsMeters(bounds, meters) {
    var lat0 = (bounds.south + bounds.north) / 2
    var mPerDegLat = 111320.0
    var mPerDegLon = 111320.0 * Math.cos(lat0 * Math.PI / 180)
    var dLat = meters / mPerDegLat
    var dLon = meters / Math.max(1e-9, mPerDegLon)
    return {
        south: bounds.south - dLat, north: bounds.north + dLat,
        west: bounds.west - dLon, east: bounds.east + dLon
    }
}

// Упрощение ломаной (Дугласа—Пекера). Marching squares ставит вершину
// на каждой ячейке сетки — для отрисовки это сотни точек впустую.
function simplifyXY(pts, tol) {
    if (pts.length < 4) return pts;
    var keep = new Uint8Array(pts.length);
    keep[0] = 1; keep[pts.length - 1] = 1;
    var stack = [[0, pts.length - 1]];
    while (stack.length) {
        var seg = stack.pop(), a = seg[0], b = seg[1];
        var ax = pts[a].x, ay = pts[a].y, bx = pts[b].x, by = pts[b].y;
        var dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
        var far = -1, fd = tol;
        for (var i = a + 1; i < b; i++) {
            var t = len2 > 1e-12 ? ((pts[i].x - ax) * dx + (pts[i].y - ay) * dy) / len2 : 0;
            if (t < 0) t = 0; else if (t > 1) t = 1;
            var ddx = pts[i].x - (ax + dx * t), ddy = pts[i].y - (ay + dy * t);
            var d = Math.sqrt(ddx * ddx + ddy * ddy);
            if (d > fd) { fd = d; far = i; }
        }
        if (far > 0) { keep[far] = 1; stack.push([a, far]); stack.push([far, b]); }
    }
    var out = [];
    for (i = 0; i < pts.length; i++) if (keep[i]) out.push(pts[i]);
    return out;
}

// Настоящая буферная зона: кольца на расстоянии meters вокруг
// ОБЪЕДИНЕНИЯ контуров rings (несколько исходных участков или частей
// многоконтурного — одна общая зона, а не по зоне на каждый). Строится
// по ПОЛЮ РАССТОЯНИЙ + marching squares, а не смещением вершин по
// бисектрисам: смещение на вогнутых углах даёт самопересечения, а
// участки сплошь бывают Г- и U-образными. Поле объединения — минимум
// знаковых расстояний до каждого контура.
//
// Проверено на выпуклых контурах против аналитической формулы
// S = A + P*buf + pi*buf^2: расхождение по площади менее 1%.
// Возвращает массив колец [{lat,lon}] без дубля первой вершины: одно,
// если зоны слились, несколько — если участки далеко друг от друга.
// Внутренние дыры зоны (двор между далёкими участками) отбрасываются.
// Пустой массив — построить не удалось.
function bufferRingsM(rings, meters, maxNodes) {
    rings = (rings || []).filter(function (r) { return r && r.length >= 3 });
    if (!rings.length || !(meters > 0)) return [];
    maxNodes = maxNodes || 60000;

    var lat0 = 0, lon0 = 0, i, n0 = 0;
    for (var ri = 0; ri < rings.length; ri++)
        for (i = 0; i < rings[ri].length; i++) { lat0 += rings[ri][i].lat; lon0 += rings[ri][i].lon; n0++; }
    lat0 /= n0; lon0 /= n0;

    var polys = rings.map(function (ring) {
        return ring.map(function (q) { return projectLocal(q.lat, q.lon, lat0, lon0) });
    });

    var minx = Infinity, maxx = -Infinity, miny = Infinity, maxy = -Infinity;
    polys.forEach(function (poly) {
        for (var k = 0; k < poly.length; k++) {
            if (poly[k].x < minx) minx = poly[k].x;
            if (poly[k].x > maxx) maxx = poly[k].x;
            if (poly[k].y < miny) miny = poly[k].y;
            if (poly[k].y > maxy) maxy = poly[k].y;
        }
    });
    // Поле считаем с запасом: уровень meters должен попасть внутрь сетки.
    var pad = meters * 1.25 + 2;
    minx -= pad; maxx += pad; miny -= pad; maxy += pad;

    // Шаг: ~1/20 буфера, но так, чтобы узлов было не больше maxNodes.
    var step = Math.max(0.25, meters / 20);
    for (;;) {
        var nx0 = Math.ceil((maxx - minx) / step) + 1;
        var ny0 = Math.ceil((maxy - miny) / step) + 1;
        if (nx0 * ny0 <= maxNodes) break;
        step *= 1.5;
    }
    var nx = Math.ceil((maxx - minx) / step) + 1;
    var ny = Math.ceil((maxy - miny) / step) + 1;

    // Знаковое расстояние: внутри контура отрицательное.
    var fld = new Float64Array(nx * ny);
    var p = { x: 0, y: 0 };
    for (var iy = 0; iy < ny; iy++) {
        p.y = miny + iy * step;
        for (var ix = 0; ix < nx; ix++) {
            p.x = minx + ix * step;
            var best = Infinity;
            for (var pi = 0; pi < polys.length; pi++) {
                var d = distToPolygonEdgeXY(p, polys[pi]);
                var sd = pointInPolygonXY(p, polys[pi]) ? -d : d;
                if (sd < best) best = sd;
            }
            fld[iy * nx + ix] = best;
        }
    }

    // Marching squares на уровне meters.
    var segs = [];
    function interp(x1, y1, v1, x2, y2, v2) {
        var t = (meters - v1) / ((v2 - v1) || 1e-12);
        if (t < 0) t = 0; else if (t > 1) t = 1;
        return { x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t };
    }
    for (iy = 0; iy < ny - 1; iy++) {
        for (ix = 0; ix < nx - 1; ix++) {
            var x0 = minx + ix * step, y0 = miny + iy * step;
            var x1 = x0 + step, y1 = y0 + step;
            var v0 = fld[iy * nx + ix];            // (x0,y0)
            var v1 = fld[iy * nx + ix + 1];        // (x1,y0)
            var v2 = fld[(iy + 1) * nx + ix + 1];  // (x1,y1)
            var v3 = fld[(iy + 1) * nx + ix];      // (x0,y1)
            // «Внутри» = значение меньше уровня.
            var code = (v0 < meters ? 1 : 0) | (v1 < meters ? 2 : 0)
                     | (v2 < meters ? 4 : 0) | (v3 < meters ? 8 : 0);
            if (code === 0 || code === 15) continue;
            var bottom = interp(x0, y0, v0, x1, y0, v1);
            var right  = interp(x1, y0, v1, x1, y1, v2);
            var top    = interp(x1, y1, v2, x0, y1, v3);
            var left   = interp(x0, y1, v3, x0, y0, v0);
            // Ориентация: «внутри» слева по ходу — чтобы кольцо вышло связным.
            switch (code) {
            case 1:  segs.push([left, bottom]); break;
            case 2:  segs.push([bottom, right]); break;
            case 3:  segs.push([left, right]); break;
            case 4:  segs.push([right, top]); break;
            case 5:  // седло
                if ((v0 + v1 + v2 + v3) / 4 < meters) { segs.push([left, top]); segs.push([right, bottom]); }
                else { segs.push([left, bottom]); segs.push([right, top]); }
                break;
            case 6:  segs.push([bottom, top]); break;
            case 7:  segs.push([left, top]); break;
            case 8:  segs.push([top, left]); break;
            case 9:  segs.push([top, bottom]); break;
            case 10: // седло: внутри углы (x1,y0) и (x0,y1)
                // Центр внутри  -> перемычка есть, изолированы углы (x0,y0) и (x1,y1):
                //                  контуры как в случаях 14 и 11.
                // Центр снаружи -> два отдельных островка: как в случаях 2 и 8.
                if ((v0 + v1 + v2 + v3) / 4 < meters) { segs.push([bottom, left]); segs.push([top, right]); }
                else { segs.push([bottom, right]); segs.push([top, left]); }
                break;
            case 11: segs.push([top, right]); break;
            case 12: segs.push([right, left]); break;
            case 13: segs.push([right, bottom]); break;
            case 14: segs.push([bottom, left]); break;
            }
        }
    }
    if (!segs.length) return [];

    // Сшивка в кольца: концы соседних ячеек совпадают, округление
    // ключа гасит расхождение последнего бита.
    function key(pt) { return Math.round(pt.x * 1000) + "_" + Math.round(pt.y * 1000); }
    var byStart = {};
    for (i = 0; i < segs.length; i++) {
        var k = key(segs[i][0]);
        if (!byStart[k]) byStart[k] = [];
        byStart[k].push(i);
    }
    var used = new Uint8Array(segs.length);
    var chains = [];
    for (i = 0; i < segs.length; i++) {
        if (used[i]) continue;
        var chain = [segs[i][0], segs[i][1]];
        used[i] = 1;
        var cur = segs[i][1];
        for (var guard = 0; guard < segs.length + 5; guard++) {
            var cand = byStart[key(cur)];
            if (!cand) break;
            var nxt = -1;
            for (var c = 0; c < cand.length; c++) if (!used[cand[c]]) { nxt = cand[c]; break; }
            if (nxt < 0) break;
            used[nxt] = 1;
            cur = segs[nxt][1];
            chain.push(cur);
            if (key(cur) === key(chain[0])) break;
        }
        if (chain.length >= 4) chains.push(chain);
    }

    var out = [];
    for (var ci = 0; ci < chains.length; ci++) {
        var ch = chains[ci];
        // Убираем дубль замыкающей вершины: контуры в этом модуле хранятся
        // без него (как boundsToRing).
        if (key(ch[ch.length - 1]) === key(ch[0])) ch.pop();
        if (ch.length < 3) continue;
        // Сшивка marching squares даёт внешний контур ПО часовой
        // (площадь < 0), дыру — против. Дыры не рисуем. Проверено на
        // «рамке» из 4 участков вокруг двора: при обратном знаке
        // оставался только двор.
        var area2 = 0;
        for (i = 0; i < ch.length; i++) {
            var u = ch[i], w = ch[(i + 1) % ch.length];
            area2 += u.x * w.y - w.x * u.y;
        }
        if (area2 >= 0) continue;
        // Замыкаем на время упрощения, чтобы первая вершина не стала изломом.
        ch.push({ x: ch[0].x, y: ch[0].y });
        ch = simplifyXY(ch, Math.max(0.2, step / 3));
        ch.pop();
        var ringOut = [];
        for (i = 0; i < ch.length; i++)
            ringOut.push(unprojectLocal(ch[i].x, ch[i].y, lat0, lon0));
        out.push(ringOut);
    }
    return out;
}

// Буфер вокруг одного контура — самое большое кольцо (совместимость).
function bufferRingM(ring, meters, maxNodes) {
    return largestRing(bufferRingsM([ring], meters, maxNodes));
}

// Bbox {south,north,west,east} → кольцо-прямоугольник [{lat,lon}]
// (замкнуто без дубля первой вершины) — контур буферной зоны для
// отрисовки на карте. Реальный «масштабный» полигон со скруглениями
// не строим: визуально достаточно расширенного прямоугольника, а
// ФИЛЬТРАЦИЯ соседей идёт по настоящему зазору между контурами
// (minDistanceRingsM), а не по этому прямоугольнику.
function boundsToRing(bounds) {
    return [
        { lat: bounds.south, lon: bounds.west },
        { lat: bounds.south, lon: bounds.east },
        { lat: bounds.north, lon: bounds.east },
        { lat: bounds.north, lon: bounds.west }
    ]
}

// Штриховка полигона: отрезки параллельных линий под углом angleDeg к
// востоку (против часовой; по умолчанию 45° — с юго-запада на
// северо-восток) с шагом stepM метров между линиями, обрезанные по
// контуру. QtLocation не умеет заливать MapPolygon узором, поэтому
// штриховку рисуют отдельные MapPolyline. Для невыпуклых контуров
// пересечения линии с рёбрами сортируются и берутся парами (правило
// чётности). Возвращает [[{lat,lon},{lat,lon}], ...].
function hatchSegments(ring, stepM, angleDeg) {
    var out = []
    if (!ring || ring.length < 3 || !(stepM > 0)) return out
    var ang = (angleDeg === undefined ? 45 : angleDeg) * Math.PI / 180
    var dx = Math.cos(ang), dy = Math.sin(ang)      // вдоль линии
    var nx = -dy, ny = dx                           // нормаль: линия n·p = k
    var c = centroidOfRing(ring)
    var xy = ring.map(function (p) { return projectLocal(p.lat, p.lon, c.lat, c.lon) })
    var kMin = Infinity, kMax = -Infinity
    for (var i = 0; i < xy.length; i++) {
        var k0 = nx * xy[i].x + ny * xy[i].y
        if (k0 < kMin) kMin = k0
        if (k0 > kMax) kMax = k0
    }
    var dk = stepM
    // Не больше 400 линий — защита от крошечного шага на большом участке.
    if ((kMax - kMin) / dk > 400) dk = (kMax - kMin) / 400
    for (var k = Math.ceil(kMin / dk) * dk; k <= kMax; k += dk) {
        var pts = []
        for (var j = 0; j < xy.length; j++) {
            var a = xy[j], b = xy[(j + 1) % xy.length]
            var fa = nx * a.x + ny * a.y - k, fb = nx * b.x + ny * b.y - k
            // Полуоткрытое правило: вершина на линии считается один раз.
            if ((fa > 0) === (fb > 0)) continue
            var t = fa / (fa - fb)
            var px = a.x + (b.x - a.x) * t, py = a.y + (b.y - a.y) * t
            pts.push({ x: px, y: py, s: dx * px + dy * py })
        }
        pts.sort(function (p, q) { return p.s - q.s })
        for (var m = 0; m + 1 < pts.length; m += 2) {
            out.push([unprojectLocal(pts[m].x, pts[m].y, c.lat, c.lon),
                      unprojectLocal(pts[m + 1].x, pts[m + 1].y, c.lat, c.lon)])
        }
    }
    return out
}

// Точка для подписи соседа: внутри его контура И внутри буфера (не
// дальше bufM от какого-либо исходного участка), по возможности
// подальше от краёв этой общей части. Центроид для подписи не годится:
// у длинного/Г-образного участка (дорога, «уличная сеть») край заходит
// в буфер, а центроид лежит далеко за зоной или вообще вне участка.
// Перебор сетки 16×16 по bbox участка; если ни один узел не подошёл
// (узкая полоса), — вершина или середина ребра, ближайшая к исходным.
function labelPointInBuffer(ring, sourceRings, bufM) {
    if (!ring || ring.length < 3) return null
    var c = centroidOfRing(ring)
    function toXY(r) {
        return r.map(function (p) { return projectLocal(p.lat, p.lon, c.lat, c.lon) })
    }
    var poly = toXY(ring)
    var srcs = (sourceRings || []).filter(function (r) { return r && r.length >= 3 }).map(toXY)
    function distToSources(p) {
        var best = Infinity
        for (var s = 0; s < srcs.length; s++) {
            if (pointInPolygonXY(p, srcs[s])) return 0
            var d = distToPolygonEdgeXY(p, srcs[s])
            if (d < best) best = d
        }
        return best
    }
    var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
    for (var i = 0; i < poly.length; i++) {
        minX = Math.min(minX, poly[i].x); maxX = Math.max(maxX, poly[i].x)
        minY = Math.min(minY, poly[i].y); maxY = Math.max(maxY, poly[i].y)
    }
    var N = 16, best = null, bestScore = -Infinity
    for (var gx = 0; gx < N; gx++) {
        for (var gy = 0; gy < N; gy++) {
            var p = { x: minX + (gx + 0.5) * (maxX - minX) / N,
                      y: minY + (gy + 0.5) * (maxY - minY) / N }
            if (!pointInPolygonXY(p, poly)) continue
            var ds = distToSources(p)
            if (ds > bufM) continue
            // Запас до края участка и до внешней границы буфера.
            var score = Math.min(distToPolygonEdgeXY(p, poly), bufM - ds)
            if (score > bestScore) { bestScore = score; best = p }
        }
    }
    if (!best) {
        var bestD = Infinity
        for (i = 0; i < poly.length; i++) {
            var a = poly[i], b = poly[(i + 1) % poly.length]
            var cands = [a, { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }]
            for (var k = 0; k < cands.length; k++) {
                var d = distToSources(cands[k])
                if (d < bestD) { bestD = d; best = cands[k] }
            }
        }
    }
    return unprojectLocal(best.x, best.y, c.lat, c.lon)
}
