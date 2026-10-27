import QtQuick 2.15

// Значок слоя в легенде карты: заливка и контур цветом слоя, по желанию —
// штриховка с теми же направлениями линий, что на карте (angles, градусы
// против часовой от востока, как в GeoMath.hatchSegments).
Canvas {
    id: sw
    property color swatchColor: "gray"
    property bool hatch: false
    property var angles: [45]
    property real fillOpacity: 0.25
    width: 16
    height: 16

    onSwatchColorChanged: requestPaint()
    onHatchChanged: requestPaint()
    onAnglesChanged: requestPaint()
    onFillOpacityChanged: requestPaint()

    function rgba(c, a) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + ","
                + Math.round(c.b * 255) + "," + a + ")"
    }

    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.fillStyle = "white"
        ctx.fillRect(0, 0, width, height)
        ctx.fillStyle = rgba(swatchColor, fillOpacity)
        ctx.fillRect(0, 0, width, height)
        if (hatch && angles) {
            ctx.save()
            ctx.beginPath()
            ctx.rect(0, 0, width, height)
            ctx.clip()
            ctx.strokeStyle = rgba(swatchColor, 1)
            // Шаг и толщина — от размера значка (легенда бывает крупной).
            ctx.lineWidth = Math.max(1.2, width / 13)
            var gap = Math.max(4, Math.round(width / 4))
            var r = Math.max(width, height)
            for (var i = 0; i < angles.length; i++) {
                ctx.save()
                ctx.translate(width / 2, height / 2)
                // На экране ось Y вниз — угол «против часовой» со знаком минус.
                ctx.rotate(-angles[i] * Math.PI / 180)
                ctx.beginPath()
                for (var d = -r; d <= r; d += gap) {
                    ctx.moveTo(-r, d)
                    ctx.lineTo(r, d)
                }
                ctx.stroke()
                ctx.restore()
            }
            ctx.restore()
        }
        ctx.strokeStyle = rgba(swatchColor, 1)
        var bw = Math.max(2, width / 10)
        ctx.lineWidth = bw
        ctx.strokeRect(bw / 2, bw / 2, width - bw, height - bw)
    }
}
