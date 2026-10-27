'use strict';
// Прототип настоящей буферной зоны для kadaster-buffer.
// Поле расстояний + marching squares: переживает невыпуклые контуры,
// в отличие от смещения вершин по бисектрисам.

function projectLocal(lat, lon, lat0, lon0) {
    var mPerDegLat = 111320.0;
    var mPerDegLon = 111320.0 * Math.cos(lat0 * Math.PI / 180);
    return { x: (lon - lon0) * mPerDegLon, y: (lat - lat0) * mPerDegLat };
}
function unprojectLocal(x, y, lat0, lon0) {
    var mPerDegLat = 111320.0;
    var mPerDegLon = 111320.0 * Math.cos(lat0 * Math.PI / 180);
    return { lat: lat0 + y / mPerDegLat, lon: lon0 + x / mPerDegLon };
}
function pointInPolygonXY(point, polygon) {
    if (!point || !polygon || polygon.length < 3) return false;
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
        var pi = polygon[i], pj = polygon[j];
        var crosses = ((pi.y > point.y) !== (pj.y > point.y))
                && (point.x < (pj.x - pi.x) * (point.y - pi.y) / ((pj.y - pi.y) || 1e-9) + pi.x);
        if (crosses) inside = !inside;
    }
    return inside;
}
function distToSegmentXY(p, a, b) {
    var dx = b.x - a.x, dy = b.y - a.y;
    var len2 = dx * dx + dy * dy;
    var t = len2 > 1e-12 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0;
    t = Math.max(0, Math.min(1, t));
    var cx = a.x + dx * t, cy = a.y + dy * t;
    var ddx = p.x - cx, ddy = p.y - cy;
    return Math.sqrt(ddx * ddx + ddy * ddy);
}
function distToPolygonEdgeXY(p, polygon) {
    var best = Infinity;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
        var d = distToSegmentXY(p, polygon[j], polygon[i]);
        if (d < best) best = d;
    }
    return best;
}


// Упрощение контура (Дугласа-Пекера). Marching squares даёт вершину на
// каждой ячейке сетки - для отрисовки это сотни точек впустую.
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

// ---- буфер ----
function bufferRingM(ring, meters, maxNodes) {
    if (!ring || ring.length < 3 || !(meters > 0)) return null;
    maxNodes = maxNodes || 40000;

    var lat0 = 0, lon0 = 0, i;
    for (i = 0; i < ring.length; i++) { lat0 += ring[i].lat; lon0 += ring[i].lon; }
    lat0 /= ring.length; lon0 /= ring.length;

    var poly = [];
    for (i = 0; i < ring.length; i++)
        poly.push(projectLocal(ring[i].lat, ring[i].lon, lat0, lon0));

    var minx = poly[0].x, maxx = poly[0].x, miny = poly[0].y, maxy = poly[0].y;
    for (i = 1; i < poly.length; i++) {
        if (poly[i].x < minx) minx = poly[i].x;
        if (poly[i].x > maxx) maxx = poly[i].x;
        if (poly[i].y < miny) miny = poly[i].y;
        if (poly[i].y > maxy) maxy = poly[i].y;
    }
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
            var d = distToPolygonEdgeXY(p, poly);
            fld[iy * nx + ix] = pointInPolygonXY(p, poly) ? -d : d;
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
    if (!segs.length) return null;

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
    var best = null;
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
        if (!best || chain.length > best.length) best = chain;
    }
    if (!best || best.length < 4) return null;

    // Убираем дубль замыкающей вершины: контуры в этом модуле хранятся
    // без него (как boundsToRing).
    if (key(best[best.length - 1]) === key(best[0])) best.pop();

    // Замыкаем на время упрощения, чтобы первая вершина не стала изломом.
    best.push({ x: best[0].x, y: best[0].y });
    best = simplifyXY(best, Math.max(0.2, step / 3));
    best.pop();

    var out = [];
    for (i = 0; i < best.length; i++)
        out.push(unprojectLocal(best[i].x, best[i].y, lat0, lon0));
    return out;
}

// ---- проверка ----
function polygonAreaXY(poly) {
    var a = 0;
    for (var i = 0; i < poly.length; i++) {
        var p = poly[i], q = poly[(i + 1) % poly.length];
        a += p.x * q.y - q.x * p.y;
    }
    return Math.abs(a) / 2;
}
function toXY(ring, lat0, lon0) {
    return ring.map(function (p) { return projectLocal(p.lat, p.lon, lat0, lon0); });
}
function perim(poly) {
    var s = 0;
    for (var i = 0; i < poly.length; i++) {
        var p = poly[i], q = poly[(i + 1) % poly.length];
        s += Math.hypot(q.x - p.x, q.y - p.y);
    }
    return s;
}

var LAT = 52.2893, LON = 104.3389;
var mLat = 111320, mLon = 111320 * Math.cos(LAT * Math.PI / 180);
function rect(wm, hm) {                        // прямоугольник w×h метров
    return [
        { lat: LAT - hm / 2 / mLat, lon: LON - wm / 2 / mLon },
        { lat: LAT - hm / 2 / mLat, lon: LON + wm / 2 / mLon },
        { lat: LAT + hm / 2 / mLat, lon: LON + wm / 2 / mLon },
        { lat: LAT + hm / 2 / mLat, lon: LON - wm / 2 / mLon }
    ];
}
function lshape() {                            // Г-образный, вогнутый
    var p = [[0,0],[80,0],[80,30],[30,30],[30,90],[0,90]];
    return p.map(function (c) {
        return { lat: LAT + c[1] / mLat, lon: LON + c[0] / mLon };
    });
}

console.log("метод: поле расстояний + marching squares\n");
[[60, 40], [120, 25]].forEach(function (wh) {
    var r = rect(wh[0], wh[1]);
    [10, 50].forEach(function (buf) {
        var b = bufferRingM(r, buf);
        var xy = toXY(b, LAT, LON), rxy = toXY(r, LAT, LON);
        var got = polygonAreaXY(xy);
        var want = polygonAreaXY(rxy) + perim(rxy) * buf + Math.PI * buf * buf;
        console.log("прямоугольник " + wh[0] + "x" + wh[1] + " м, буфер " + buf
            + " м: вершин " + b.length
            + ", площадь " + got.toFixed(0) + " м2, аналитически " + want.toFixed(0)
            + " м2, расхождение " + (100 * (got - want) / want).toFixed(2) + "%");
    });
});
var L = lshape(), lb = bufferRingM(L, 20);
var lxy = toXY(lb, LAT, LON), Lxy = toXY(L, LAT, LON);
var gotL = polygonAreaXY(lxy);
var wantL = polygonAreaXY(Lxy) + perim(Lxy) * 20 + Math.PI * 400;
console.log("\nГ-образный, буфер 20 м: вершин " + lb.length
    + ", площадь " + gotL.toFixed(0) + " м2, аналитически (как для выпуклого) "
    + wantL.toFixed(0) + " м2");
console.log("для вогнутого контура аналитическая формула завышает — вогнутые углы");
console.log("не дают полного кольца; меньшее значение здесь ожидаемо и правильно.");

// U-образный контур: при достаточном буфере зоны от двух плеч смыкаются,
// в поле расстояний появляются седловые точки (случаи 5 и 10).
function ushape() {
    var p = [[0,0],[70,0],[70,80],[50,80],[50,25],[20,25],[20,80],[0,80]];
    return p.map(function (c) { return { lat: LAT + c[1] / mLat, lon: LON + c[0] / mLon }; });
}
var U = ushape();
[6, 18, 30].forEach(function (buf) {
    var ub = bufferRingM(U, buf);
    if (!ub) { console.log("U-образный, буфер " + buf + " м: НЕ ПОСТРОЕН"); return; }
    var uxy = toXY(ub, LAT, LON);
    // кольцо не должно самопересекаться: площадь по шнуру > 0 и близка к габариту
    var a = polygonAreaXY(uxy);
    var xs = uxy.map(function(q){return q.x;}), ys = uxy.map(function(q){return q.y;});
    var bboxA = (Math.max.apply(null,xs)-Math.min.apply(null,xs)) * (Math.max.apply(null,ys)-Math.min.apply(null,ys));
    console.log("U-образный, буфер " + buf + " м: вершин " + ub.length
      + ", площадь " + a.toFixed(0) + " м2, габарит " + bboxA.toFixed(0)
      + " м2, заполнение " + (100*a/bboxA).toFixed(0) + "%");
});

var t0 = process.hrtime.bigint();
for (var k = 0; k < 20; k++) bufferRingM(rect(60, 40), 50);
console.log("\nвремя построения: " + (Number(process.hrtime.bigint() - t0) / 1e6 / 20).toFixed(1) + " мс (V8)");
