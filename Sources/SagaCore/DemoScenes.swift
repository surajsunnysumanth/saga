import Foundation
import CoreGraphics

/// The drawn scenes behind the generated photos.
///
/// Each one is composed like a photograph: a horizon or a light source, a foreground with
/// texture, and haze between the layers. The palette is the app's own — teal, green, sand,
/// paper — with warm light, so a gallery of them reads as pictures someone shared rather than
/// as colour swatches. Ten compositions, each with its own internal variation, plus a random
/// crop per image; nothing here is copied from a phone and no real person or place is depicted.
enum DemoScenes {
    // MARK: drawing helpers

    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(red: CGFloat(r / 255), green: CGFloat(g / 255), blue: CGFloat(b / 255), alpha: CGFloat(a))
    }

    static func vertical(_ ctx: CGContext, _ rect: CGRect, _ stops: [CGColor]) {
        let space = CGColorSpaceCreateDeviceRGB()
        let n = max(2, stops.count)
        let locations = (0..<n).map { CGFloat($0) / CGFloat(n - 1) }
        guard let g = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: locations) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY),
                               end: CGPoint(x: rect.minX, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    static func glow(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, _ c: CGColor) {
        let space = CGColorSpaceCreateDeviceRGB()
        let clear = c.copy(alpha: 0) ?? c
        guard let g = CGGradient(colorsSpace: space, colors: [c, clear] as CFArray, locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
    }

    static func ellipse(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                        _ c: CGColor, rotation: CGFloat = 0) {
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        if rotation != 0 { ctx.rotate(by: rotation) }
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    static func rect(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    /// A soft-edged blob: several translucent passes, each a little smaller. Reads as a
    /// shadow or a cloud, and costs nothing next to a real blur.
    static func soft(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     _ c: CGColor, layers: Int = 5) {
        for i in 0..<layers {
            let k = 1 - CGFloat(i) * (0.9 / CGFloat(layers * 2))
            let a = 0.20 + Double(i) * (0.55 / Double(layers))
            ellipse(ctx, x, y, w * k, h * k, c.copy(alpha: a) ?? c)
        }
    }

    /// Fine texture — sand, gravel, grain, crumbs. Small, low-contrast, many.
    static func scatter(_ ctx: CGContext, _ rng: inout DemoRandom, count: Int, in r: CGRect,
                        _ c: CGColor, size: ClosedRange<CGFloat>, alpha: ClosedRange<Double>) {
        for _ in 0..<count {
            let s = size.lowerBound + CGFloat(rng.double()) * (size.upperBound - size.lowerBound)
            let x = r.minX + CGFloat(rng.double()) * r.width
            let y = r.minY + CGFloat(rng.double()) * r.height
            let a = alpha.lowerBound + rng.double() * (alpha.upperBound - alpha.lowerBound)
            ellipse(ctx, x, y, s, s * (0.55 + rng.double() * 0.9), c.copy(alpha: a) ?? c)
        }
    }

    static func leaf(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ len: CGFloat, _ wide: CGFloat,
                     _ angle: CGFloat, _ c: CGColor) {
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        ctx.rotate(by: angle)
        ctx.setFillColor(c)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: -len / 2, y: 0))
        ctx.addQuadCurve(to: CGPoint(x: len / 2, y: 0), control: CGPoint(x: 0, y: -wide))
        ctx.addQuadCurve(to: CGPoint(x: -len / 2, y: 0), control: CGPoint(x: 0, y: wide))
        ctx.closePath()
        ctx.fillPath()
        ctx.setStrokeColor(rgb(210, 236, 200, 0.20))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: -len / 2, y: 0))
        ctx.addLine(to: CGPoint(x: len / 2, y: 0))
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func building(_ ctx: CGContext, _ rng: inout DemoRandom, x: CGFloat, ground: CGFloat,
                         w: CGFloat, h: CGFloat, tone: Double) {
        rect(ctx, x, ground - h, w, h + 3, rgb(tone, tone + 16, tone + 15))
        rect(ctx, x, ground - h, w, 2.5, rgb(tone + 30, tone + 44, tone + 40, 0.5))
        var wy = ground - h + 6
        while wy < ground - 8 {
            var wx = x + 4
            while wx < x + w - 7 {
                if rng.chance(0.42) {
                    rect(ctx, wx, wy, 3.2, 4.4, rgb(250, 220, 158, 0.18 + rng.double() * 0.6))
                }
                wx += 7.5
            }
            wy += 10.5
        }
    }

    // MARK: scenes

    /// A coastline at midday: sky, low sun, headland, lit water, wet sand.
    static func coast(_ ctx: CGContext, _ s: CGSize, _ rng: inout DemoRandom) {
        let W = s.width, H = s.height
        let horizon = H * (0.52 + CGFloat(rng.double()) * 0.08)
        let skies: [[CGColor]] = [
            [rgb(44, 110, 118), rgb(128, 184, 182), rgb(214, 230, 208)],   // bright midday
            [rgb(36, 84, 92), rgb(188, 190, 164), rgb(252, 228, 190)],     // hazy late light
            [rgb(30, 78, 84), rgb(104, 156, 150), rgb(196, 216, 204)],     // overcast
        ]
        vertical(ctx, CGRect(x: 0, y: 0, width: W, height: horizon), skies[rng.int(skies.count)])
        let sunX = W * (0.55 + CGFloat(rng.double()) * 0.3)
        let sun = CGPoint(x: sunX, y: horizon * (0.22 + CGFloat(rng.double()) * 0.30))
        glow(ctx, at: sun, radius: W * 0.40, rgb(252, 240, 200, 0.45))
        ellipse(ctx, sun.x, sun.y, W * 0.075, W * 0.075, rgb(253, 249, 228))
        for _ in 0..<5 {
            let y = CGFloat(rng.range(8, Int(horizon * 0.60)))
            let w = CGFloat(rng.range(Int(W * 0.20), Int(W * 0.55)))
            let x = CGFloat(rng.range(0, Int(W - w)))
            soft(ctx, x + w / 2, y, w, H * 0.045, rgb(255, 255, 255, 0.55), layers: 4)
        }
        // Headland, with a scrubby edge so it is not a smooth wedge.
        ctx.setFillColor(rgb(34, 74, 66))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: -10, y: horizon + 3))
        var hx: CGFloat = -10
        ctx.addLine(to: CGPoint(x: -10, y: horizon * 0.66))
        while hx < W * 0.42 {
            hx += CGFloat(rng.range(20, 50))
            ctx.addLine(to: CGPoint(x: hx, y: horizon * (0.70 + rng.double() * 0.20)))
        }
        ctx.addLine(to: CGPoint(x: max(hx, W * 0.35), y: horizon + 3))
        ctx.closePath()
        ctx.fillPath()
        vertical(ctx, CGRect(x: 0, y: horizon, width: W, height: H * 0.34),
                 [rgb(64, 132, 114), rgb(46, 108, 100), rgb(126, 176, 158)])
        // Sun path on the water.
        for _ in 0..<26 {
            let y = horizon + CGFloat(rng.range(2, Int(H * 0.30)))
            let w = CGFloat(rng.range(10, 70)) * (1 - (y - horizon) / (H * 0.34) * 0.4)
            let x = sunX - w / 2 + CGFloat(rng.double() - 0.5) * W * 0.10
            rect(ctx, x, y, w, CGFloat(rng.range(1, 3)), rgb(255, 250, 226, 0.10 + rng.double() * 0.25))
        }
        for _ in 0..<24 {
            let y = horizon + CGFloat(rng.range(4, Int(H * 0.30)))
            let w = CGFloat(rng.range(16, 90))
            rect(ctx, CGFloat(rng.range(0, Int(W - w))), y, w, CGFloat(rng.range(1, 2)),
                 rgb(255, 255, 255, 0.05 + rng.double() * 0.10))
        }
        let sandTop = H * (0.82 + CGFloat(rng.double()) * 0.06)
        vertical(ctx, CGRect(x: 0, y: sandTop, width: W, height: H - sandTop),
                 [rgb(236, 226, 200), rgb(208, 194, 164)])
        ctx.setStrokeColor(rgb(255, 255, 255, 0.55))
        ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: -10, y: sandTop + 2))
        ctx.addQuadCurve(to: CGPoint(x: W + 10, y: sandTop - 2), control: CGPoint(x: W * 0.5, y: sandTop + 10))
        ctx.strokePath()
        scatter(ctx, &rng, count: 260, in: CGRect(x: 0, y: sandTop, width: W, height: H - sandTop),
                rgb(120, 108, 88), size: 1.2...2.6, alpha: 0.10...0.30)
        for _ in 0..<2 {
            let rx = CGFloat(rng.range(20, Int(W - 40))), ry = sandTop + CGFloat(rng.range(10, Int(H - sandTop - 14)))
            let rw = CGFloat(rng.range(22, 52))
            ellipse(ctx, rx, ry + 4, rw, rw * 0.34, rgb(80, 74, 60, 0.25))
            ellipse(ctx, rx, ry, rw, rw * 0.30, rgb(122, 116, 100))
            ellipse(ctx, rx - rw * 0.15, ry - rw * 0.06, rw * 0.45, rw * 0.14, rgb(160, 154, 138, 0.7))
        }
        // Birds.
        ctx.setStrokeColor(rgb(60, 78, 76, 0.55))
        ctx.setLineWidth(1.4)
        for _ in 0..<3 {
            let bx = CGFloat(rng.range(30, Int(W - 30))), by = CGFloat(rng.range(20, Int(horizon * 0.55)))
            let d = CGFloat(rng.range(4, 9))
            ctx.move(to: CGPoint(x: bx - d, y: by))
            ctx.addQuadCurve(to: CGPoint(x: bx, y: by + d * 0.4), control: CGPoint(x: bx - d / 2, y: by - d * 0.5))
            ctx.addQuadCurve(to: CGPoint(x: bx + d, y: by), control: CGPoint(x: bx + d / 2, y: by - d * 0.5))
            ctx.strokePath()
        }
    }

    /// Ridges at dusk, five layers deep, with haze and trees on the near slope.
    static func ridges(_ ctx: CGContext, _ s: CGSize, _ rng: inout DemoRandom) {
        let W = s.width, H = s.height
        let palettes: [[CGColor]] = [
            [rgb(40, 96, 104), rgb(120, 160, 154), rgb(242, 220, 182)],
            [rgb(54, 92, 96), rgb(226, 198, 160), rgb(250, 230, 196)],
            [rgb(86, 140, 134), rgb(206, 224, 204), rgb(244, 242, 226)],
        ]
        vertical(ctx, CGRect(x: 0, y: 0, width: W, height: H * 0.70), palettes[rng.int(palettes.count)])
        let sun = CGPoint(x: W * (0.22 + CGFloat(rng.double()) * 0.4), y: H * (0.34 + CGFloat(rng.double()) * 0.12))
        glow(ctx, at: sun, radius: W * 0.34, rgb(252, 228, 176, 0.5))
        ellipse(ctx, sun.x, sun.y, W * 0.06, W * 0.06, rgb(253, 246, 214))
        for _ in 0..<3 {
            let y = sun.y + CGFloat(rng.range(6, 40))
            rect(ctx, 0, y, W, H * 0.02 + CGFloat(rng.range(0, 8)), rgb(250, 236, 206, 0.16))
        }
        let tones = [rgb(38, 72, 76), rgb(48, 88, 86), rgb(64, 110, 100), rgb(84, 136, 116), rgb(104, 158, 128)]
        for k in 0..<5 {
            let base = H * (0.36 + CGFloat(k) * 0.105)
            ctx.setFillColor(tones[k])
            ctx.beginPath()
            ctx.move(to: CGPoint(x: -10, y: H + 10))
            ctx.addLine(to: CGPoint(x: -10, y: base))
            var x: CGFloat = -10
            while x < W + 10 {
                let w = CGFloat(rng.range(Int(W * 0.10), Int(W * 0.26)))
                let peak = base - CGFloat(rng.range(8, Int(H * 0.14)))
                ctx.addQuadCurve(to: CGPoint(x: min(W + 10, x + w), y: base + CGFloat(rng.range(-4, 6))),
                                 control: CGPoint(x: x + w / 2, y: peak))
                x += w
            }
            ctx.addLine(to: CGPoint(x: W + 10, y: H + 10))
            ctx.closePath()
            ctx.fillPath()
            if k < 4 { rect(ctx, 0, base - 3, W, H * 0.032, rgb(246, 240, 218, 0.09)) }
        }
        // Trees on the nearest ridge, and grass in front.
        for _ in 0..<14 {
            let tx = CGFloat(rng.range(0, Int(W)))
            let ty = H * (0.90 + rng.double() * 0.06)
            let th = CGFloat(rng.range(10, 26))
            rect(ctx, tx - 1, ty - th * 0.3, 2, th * 0.5, rgb(26, 54, 46))
            ellipse(ctx, tx, ty - th * 0.6, th * 0.55, th, rgb(24, 56, 46))
        }
        ctx.setStrokeColor(rgb(30, 64, 50, 0.8))
        ctx.setLineWidth(1.6)
        for _ in 0..<42 {
            let gx = CGFloat(rng.range(0, Int(W)))
            let gh = CGFloat(rng.range(8, 26))
            ctx.move(to: CGPoint(x: gx, y: H + 2))
            ctx.addQuadCurve(to: CGPoint(x: gx + CGFloat(rng.double() * 8 - 4), y: H - gh),
                             control: CGPoint(x: gx + 3, y: H - gh / 2))
        }
        ctx.strokePath()
    }

    /// Under trees: bokeh, light shafts, layered leaves.
    static func forest(_ ctx: CGContext, _ s: CGSize, _ rng: inout DemoRandom) {
        let W = s.width, H = s.height
        vertical(ctx, CGRect(x: 0, y: 0, width: W, height: H), [rgb(14, 36, 32), rgb(48, 96, 70), rgb(24, 54, 42)])
        for _ in 0..<44 {
            let r = CGFloat(rng.range(6, 52))
            ellipse(ctx, CGFloat(rng.range(0, Int(W))), CGFloat(rng.range(0, Int(H))), r, r,
                    rgb(168, 216, 158, 0.04 + rng.double() * 0.16))
        }
        for _ in 0..<5 {
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(rng.range(-20, Int(W))), y: -H * 0.2)
            ctx.rotate(by: 0.22 + CGFloat(rng.double()) * 0.16)
            rect(ctx, 0, 0, CGFloat(rng.range(20, 60)), H * 1.5, rgb(255, 250, 218, 0.04))
            ctx.restoreGState()
        }
        for _ in 0..<26 {
            let x = CGFloat(rng.range(-20, Int(W + 20))), y = CGFloat(rng.range(-10, Int(H + 10)))
            let l = CGFloat(rng.range(50, 140)), d = CGFloat(rng.range(20, 48))
            let a = CGFloat(rng.double() * .pi * 2)
            leaf(ctx, x, y, l, d, a, rgb(30 + rng.double() * 16, 74 + rng.double() * 26, 50 + rng.double() * 16, 0.85))
        }
        for _ in 0..<40 {
            ellipse(ctx, CGFloat(rng.range(0, Int(W))), CGFloat(rng.range(0, Int(H))),
                    CGFloat(rng.range(10, 26)), CGFloat(rng.range(6, 16)), rgb(220, 240, 190, 0.05))
        }
        for _ in 0..<4 {
            ctx.setStrokeColor(rgb(18, 40, 32, 0.9))
            ctx.setLineWidth(CGFloat(rng.range(2, 5)))
            let x = CGFloat(rng.range(0, Int(W)))
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addQuadCurve(to: CGPoint(x: x + CGFloat(rng.double() * 60 - 30), y: H),
                             control: CGPoint(x: x + CGFloat(rng.double() * 80 - 40), y: H * 0.5))
            ctx.strokePath()
        }
    }

    /// A skyline at dusk across water.
    static func skyline(_ ctx: CGContext, _ s: CGSize, _ rng: inout DemoRandom) {
        let W = s.width, H = s.height
        let ground = H * (0.66 + CGFloat(rng.double()) * 0.06)
        vertical(ctx, CGRect(x: 0, y: 0, width: W, height: ground + 4),
                 [rgb(30, 62, 74), rgb(128, 138, 132), rgb(244, 208, 160)])
        let sun = CGPoint(x: W * (0.4 + CGFloat(rng.double()) * 0.35), y: ground - H * 0.10)
        glow(ctx, at: sun, radius: W * 0.36, rgb(252, 214, 150, 0.45))
        ellipse(ctx, sun.x, sun.y, W * 0.065, W * 0.065, rgb(253, 232, 184, 0.85))
        for _ in 0..<4 {
            let y = CGFloat(rng.range(20, Int(ground * 0.55)))
            rect(ctx, 0, y, W, CGFloat(rng.range(2, 7)), rgb(250, 222, 184, 0.10))
        }
        // Far row, hazy.
        var x: CGFloat = -20
        while x < W {
            let w = CGFloat(rng.range(24, 58))
            let h = CGFloat(rng.range(Int(H * 0.10), Int(H * 0.28)))
            rect(ctx, x, ground - h, w - 2, h, rgb(66, 96, 98, 0.55))
            x += w
        }
        rect(ctx, 0, ground - H * 0.30, W, H * 0.30, rgb(250, 220, 176, 0.10))
        // Near row with details.
        x = -14
        while x < W {
            let w = CGFloat(rng.range(28, 66))
            let h = CGFloat(rng.range(Int(H * 0.14), Int(H * 0.44)))
            building(ctx, &rng, x: x, ground: ground, w: w - 3, h: h, tone: 14 + rng.double() * 12)
            if rng.chance(0.25) {
                rect(ctx, x + w * 0.4, ground - h - CGFloat(rng.range(6, 22)), 2, CGFloat(rng.range(6, 22)),
                     rgb(24, 44, 46))
            }
            x += w
        }
        vertical(ctx, CGRect(x: 0, y: ground, width: W, height: H - ground),
                 [rgb(46, 84, 82), rgb(10, 26, 30)])
        for _ in 0..<40 {
            let wx = CGFloat(rng.range(0, Int(W)))
            rect(ctx, wx, ground + CGFloat(rng.range(2, Int(H - ground))), CGFloat(rng.range(15, 60)) / 10,
                 CGFloat(rng.range(6, 26)), rgb(250, 216, 158, 0.06 + rng.double() * 0.16))
        }
        ctx.setStrokeColor(rgb(250, 230, 190, 0.14))
        ctx.setLineWidth(1.2)
        for _ in 0..<18 {
            let ry = ground + CGFloat(rng.range(6, Int(H - ground - 6)))
            ctx.move(to: CGPoint(x: 0, y: ry))
            ctx.addQuadCurve(to: CGPoint(x: W, y: ry), control: CGPoint(x: W / 2, y: ry + CGFloat(rng.double() * 6 - 3)))
        }
        ctx.strokePath()
    }

    /// A café table from the seat: wood, saucer, cup, steam, spoon, a cloth.
    static func cafe(_ ctx: CGContext, _ s: CGSize, _ rng: inout DemoRandom) {
        let W = s.width, H = s.height
        vertical(ctx, CGRect(x: 0, y: 0, width: W, height: H), [rgb(240, 234, 218), rgb(206, 194, 170)])
        for _ in 0..<22 {
            ctx.setStrokeColor(rgb(120, 100, 78, 0.05 + rng.double() * 0.06))
            ctx.setLineWidth(1 + CGFloat(rng.double()) * 1.6)
            let y = CGFloat(rng.range(0, Int(H)))
            ctx.move(to: CGPoint(x: -10, y: y))
            ctx.addQuadCurve(to: CGPoint(x: W + 10, y: y + CGFloat(rng.double() * 16 - 8)),
                             control: CGPoint(x: W / 2, y: y + CGFloat(rng.double() * 20 - 10)))
            ctx.strokePath()
        }
        rect(ctx, 0, H * 0.62, W, 2, rgb(120, 100, 78, 0.10))
        // Cloth, folded, to the right.
        ctx.saveGState()
        ctx.translateBy(x: W * 0.82, y: H * 0.74)
        ctx.rotate(by: -0.16)
        rect(ctx, -W * 0.11, -H * 0.10, W * 0.24, H * 0.22, rgb(96, 130, 112, 0.55))
        rect(ctx, -W * 0.10, -H * 0.09, W * 0.22, H * 0.20, rgb(250, 248, 240))
        for i in 0..<4 {
            rect(ctx, -W * 0.10, -H * 0.06 + CGFloat(i) * H * 0.045, W * 0.22, 2, rgb(150, 176, 158, 0.45))
        }
        ctx.restoreGState()
        let cx = W * (0.36 + CGFloat(rng.double()) * 0.18)
        ellipse(ctx, cx, H * 0.63, W * 0.60, H * 0.30, rgb(96, 84, 62, 0.18))
        ellipse(ctx, cx + 4, H * 0.60, W * 0.55, H * 0.28, rgb(250, 249, 242))
        ellipse(ctx, cx + 4, H * 0.60, W * 0.40, H * 0.19, rgb(232, 229, 217))
        // Cup body, slightly tapered.
        let cupW = W * 0.17, cupTop = H * 0.36, cupBottom = H * 0.57
        ctx.setFillColor(rgb(251, 251, 247))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx - W * 0.06, y: cupTop + 2))
        ctx.addLine(to: CGPoint(x: cx + W * 0.11, y: cupTop + 2))
        ctx.addLine(to: CGPoint(x: cx + W * 0.085, y: cupBottom))
        ctx.addQuadCurve(to: CGPoint(x: cx - W * 0.035, y: cupBottom),
                         control: CGPoint(x: cx + W * 0.025, y: cupBottom + 9))
        ctx.closePath()
        ctx.fillPath()
        ctx.setStrokeColor(rgb(246, 246, 240))
        ctx.setLineWidth(6.5)
        ctx.strokeEllipse(in: CGRect(x: cx + W * 0.075, y: H * 0.40, width: cupW * 0.42, height: H * 0.095))
        ellipse(ctx, cx + cupW * 0.14, cupTop + 1, cupW, H * 0.055, rgb(248, 248, 242))
        ellipse(ctx, cx + cupW * 0.14, cupTop + 3, cupW * 0.86, H * 0.042, rgb(96, 60, 38))
        ellipse(ctx, cx + cupW * 0.14, cupTop + 3, cupW * 0.58, H * 0.026, rgb(164, 122, 80))
        soft(ctx, cx + cupW * 0.08, cupTop + 3, cupW * 0.22, H * 0.012, rgb(226, 200, 160, 0.6), layers: 3)
        ellipse(ctx, cx + cupW * 0.14, cupBottom + 1, cupW, H * 0.045, rgb(240, 238, 230))
        // Steam.
        for i in 0..<3 {
            let dx = (CGFloat(i) - 1) * W * 0.045
            ctx.setStrokeColor(rgb(255, 255, 255, 0.30))
            ctx.setLineWidth(3)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: cx + cupW * 0.14 + dx, y: cupTop - 6))
            ctx.addCurve(to: CGPoint(x: cx + cupW * 0.14 + dx, y: cupTop - H * 0.17),
                         control1: CGPoint(x: cx + cupW * 0.14 + dx - W * 0.035, y: cupTop - H * 0.07),
                         control2: CGPoint(x: cx + cupW * 0.14 + dx + W * 0.035, y: cupTop - H * 0.11))
            ctx.strokePath()
        }
        // Spoon and a few crumbs.
        ctx.setStrokeColor(rgb(148, 152, 150, 0.9))
        ctx.setLineWidth(3.2)
        ctx.move(to: CGPoint(x: cx + W * 0.19, y: H * 0.55))
        ctx.addLine(to: CGPoint(x: cx + W * 0.34, y: H * 0.48))
        ctx.strokePath()
        ellipse(ctx, cx + W * 0.175, H * 0.556, W * 0.036, H * 0.015, rgb(166, 170, 168, 0.95), rotation: -0.24)
        scatter(ctx, &rng, count: 40, in: CGRect(x: cx - W * 0.2, y: H * 0.68, width: W * 0.5, height: H * 0.12),
                rgb(120, 100, 72), size: 1...3.2, alpha: 0.12...0.4)
    }

    /// A windowsill plant — three kinds, so the gallery is not one photo repeated.
    static func windowPlant(_ ctx: CGContext, _ s: CGSize, _ rng: inout DemoRandom) {
        let W = s.width, H = s.height
        vertical(ctx, CGRect(x: 0, y: 0, width: W, height: H), [rgb(242, 240, 230), rgb(218, 220, 210)])
        let pane = CGRect(x: W * (0.42 + CGFloat(rng.double()) * 0.10), y: H * (0.04 + CGFloat(rng.double()) * 0.06),
                          width: W * (0.42 + CGFloat(rng.double()) * 0.10), height: H * (0.46 + CGFloat(rng.double()) * 0.10))
        glow(ctx, at: CGPoint(x: pane.midX, y: pane.midY), radius: W * 0.6, rgb(255, 250, 222, 0.5))
        ctx.setFillColor(rgb(247, 246, 238))
        ctx.fill(pane.insetBy(dx: -7, dy: -7))
        vertical(ctx, pane, [rgb(178, 214, 208), rgb(232, 242, 232)])
        glow(ctx, at: CGPoint(x: pane.midX, y: pane.minY + pane.height * 0.3), radius: W * 0.34, rgb(255, 253, 238, 0.6))
        rect(ctx, pane.midX - 3, pane.minY, 6, pane.height, rgb(247, 246, 238))
        rect(ctx, pane.minX, pane.midY - 3, pane.width, 6, rgb(247, 246, 238))
        rect(ctx, pane.minX - 14, pane.maxY + 4, pane.width + 28, H * 0.035, rgb(238, 236, 226))
        rect(ctx, pane.minX - 14, pane.maxY + 4 + H * 0.035, pane.width + 28, 3, rgb(170, 172, 162, 0.5))
        let sillY = pane.maxY + H * 0.03
        let potX = W * (0.24 + CGFloat(rng.double()) * 0.16)
        let kind = rng.int(3)
        ellipse(ctx, potX, sillY + H * 0.055, W * 0.30, H * 0.04, rgb(80, 74, 58, 0.25))
        // Pot.
        let potW: CGFloat = W * (0.20 + CGFloat(rng.double()) * 0.06)
        let potTop = sillY - H * 0.20, potBottom = sillY + H * 0.02
        let pot = [rgb(40, 98, 84), rgb(196, 186, 164), rgb(150, 106, 84)][rng.int(3)]
        ctx.setFillColor(pot)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: potX - potW / 2, y: potTop))
        ctx.addLine(to: CGPoint(x: potX + potW / 2, y: potTop))
        ctx.addLine(to: CGPoint(x: potX + potW * 0.40, y: potBottom))
        ctx.addLine(to: CGPoint(x: potX - potW * 0.40, y: potBottom))
        ctx.closePath()
        ctx.fillPath()
        ellipse(ctx, potX, potTop, potW, H * 0.035, pot.copy(alpha: 0.9) ?? pot)
        ctx.setStrokeColor(rgb(255, 255, 255, 0.22))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: potX - potW * 0.44, y: potTop + 4))
        ctx.addLine(to: CGPoint(x: potX - potW * 0.34, y: potBottom - 4))
        ctx.strokePath()
        let green = rgb(58 + rng.double() * 18, 114 + rng.double() * 22, 70 + rng.double() * 14)
        switch kind {
        case 0:  // Broad leaves on long stalks.
            for i in 0..<6 {
                let dx = CGFloat(rng.double() - 0.5) * W * 0.22
                let top = potTop - H * (0.10 + rng.double() * 0.16)
                ctx.setStrokeColor(rgb(64, 122, 78))
                ctx.setLineWidth(2.6)
                ctx.move(to: CGPoint(x: potX, y: potTop))
                ctx.addQuadCurve(to: CGPoint(x: potX + dx, y: top),
                                 control: CGPoint(x: potX + dx * 1.5, y: potTop - H * 0.12))
                ctx.strokePath()
                leaf(ctx, potX + dx, top, W * (0.10 + rng.double() * 0.06), H * (0.055 + rng.double() * 0.03),
                     CGFloat(rng.double() * 1.2 - 0.6) + (i % 2 == 0 ? 0.5 : -0.5), green)
            }
        case 1:  // A trailing vine over the sill.
            for i in 0..<3 {
                let dx = CGFloat(rng.double() - 0.5) * W * 0.12
                let top = potTop - H * (0.06 + rng.double() * 0.10)
                ctx.setStrokeColor(rgb(74, 130, 84))
                ctx.setLineWidth(2)
                ctx.move(to: CGPoint(x: potX + dx, y: potTop))
                ctx.addQuadCurve(to: CGPoint(x: potX + dx * 2.4, y: potBottom + H * 0.12),
                                 control: CGPoint(x: potX + dx * 3.2, y: potTop - H * 0.10))
                ctx.strokePath()
                for k in 0..<6 {
                    let t = CGFloat(k) / 6
                    leaf(ctx, potX + dx * (1 + t * 2.2), potTop - H * 0.05 + t * H * 0.16,
                         W * 0.055, H * 0.026, CGFloat(k) * 0.9, green)
                }
            }
        default:  // A cactus with a flower.
            ctx.setFillColor(rgb(78, 132, 92))
            ctx.fill(CGRect(x: potX - potW * 0.16, y: potTop - H * 0.16, width: potW * 0.32, height: H * 0.17))
            ellipse(ctx, potX, potTop - H * 0.16, potW * 0.32, H * 0.05, rgb(88, 146, 102))
            ellipse(ctx, potX + potW * 0.16, potTop - H * 0.09, potW * 0.16, H * 0.06, rgb(78, 132, 92))
            for _ in 0..<14 {
                let sy = potTop - H * (0.02 + rng.double() * 0.13)
                ellipse(ctx, potX + CGFloat(rng.double() * 0.24 - 0.12) * potW, sy,
                        CGFloat(rng.range(2, 5)), CGFloat(rng.range(2, 6)), rgb(220, 240, 210, 0.5))
            }
            ellipse(ctx, potX + potW * 0.03, potTop - H * 0.19, W * 0.035, W * 0.035, rgb(226, 132, 108))
        }
        scatter(ctx, &rng, count: 90, in: CGRect(x: 0, y: sillY + H * 0.02, width: W, height: H * 0.10),
                rgb(120, 112, 92), size: 1...2.4, alpha: 0.08...0.22)
    }

    /// A street at night: one lamp, a wet road, warm points of light.
    static func street(_ ctx: CGContext, _ s: CGSize, _ rng: inout DemoRandom) {
        let W = s.width, H = s.height
        vertical(ctx, CGRect(x: 0, y: 0, width: W, height: H), [rgb(10, 26, 30), rgb(26, 52, 52), rgb(40, 62, 58)])
        let lamp = CGPoint(x: W * (0.22 + CGFloat(rng.double()) * 0.16), y: H * 0.24)
        glow(ctx, at: lamp, radius: W * 0.45, rgb(252, 214, 152, 0.45))
        rect(ctx, lamp.x - 2.5, lamp.y, 5, H * 0.72, rgb(8, 18, 20))
        ellipse(ctx, lamp.x, lamp.y - 5, W * 0.085, H * 0.022, rgb(254, 232, 178))
        ellipse(ctx, lamp.x, lamp.y - 2, W * 0.04, H * 0.012, rgb(255, 248, 214))
        let roadTop = H * 0.72
        vertical(ctx, CGRect(x: 0, y: roadTop, width: W, height: H - roadTop), [rgb(26, 38, 38), rgb(10, 20, 22)])
        // Wet sheen under the lamp.
        for _ in 0..<18 {
            let y = roadTop + CGFloat(rng.range(0, Int(H - roadTop)))
            let w = CGFloat(rng.range(6, 40))
            rect(ctx, lamp.x - w / 2 + CGFloat(rng.double() * 30 - 15), y, w, CGFloat(rng.range(2, 7)),
                 rgb(250, 214, 156, 0.08 + rng.double() * 0.14))
        }
        ctx.setFillColor(rgb(200, 190, 164, 0.28))
        var x: CGFloat = -20
        while x < W {
            let w = CGFloat(rng.range(18, 40))
            ctx.fill(CGRect(x: x, y: H * 0.90, width: w, height: 3))
            x += w + 20
        }
        // Second, distant lamp and light points.
        let far = CGPoint(x: W * 0.78, y: H * 0.42)
        glow(ctx, at: far, radius: W * 0.16, rgb(250, 212, 150, 0.30))
        ellipse(ctx, far.x, far.y, W * 0.022, W * 0.022, rgb(253, 236, 190))
        for _ in 0..<10 {
            ellipse(ctx, CGFloat(rng.range(0, Int(W))), CGFloat(rng.range(Int(H * 0.30), Int(H * 0.72))),
                    CGFloat(rng.range(3, 9)), CGFloat(rng.range(3, 9)), rgb(250, 214, 158, 0.10 + rng.double() * 0.2))
        }
        // Rain.
        ctx.setStrokeColor(rgb(230, 240, 236, 0.10))
        ctx.setLineWidth(1)
        for _ in 0..<60 {
            let rx = CGFloat(rng.range(-20, Int(W + 20))), ry = CGFloat(rng.range(0, Int(H)))
            ctx.move(to: CGPoint(x: rx, y: ry))
            ctx.addLine(to: CGPoint(x: rx - 5, y: ry + CGFloat(rng.range(14, 30))))
        }
        ctx.strokePath()
        for _ in 0..<3 {
            ellipse(ctx, CGFloat(rng.range(0, Int(W))), H * (0.66 + rng.double() * 0.04),
                    W * 0.12, H * 0.07, rgb(8, 18, 20, 0.85))
        }
    }

    /// Lunch from above: plate, four things on it, cutlery, a glass.
    static func plate(_ ctx: CGContext, _ s: CGSize, _ rng: inout DemoRandom) {
        let W = s.width, H = s.height
        vertical(ctx, CGRect(x: 0, y: 0, width: W, height: H), [rgb(74, 92, 76), rgb(38, 52, 46)])
        for _ in 0..<26 {
            ctx.setStrokeColor(rgb(20, 32, 28, 0.12))
            ctx.setLineWidth(1.4)
            let y = CGFloat(rng.range(0, Int(H)))
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addQuadCurve(to: CGPoint(x: W, y: y + CGFloat(rng.double() * 10 - 5)),
                             control: CGPoint(x: W / 2, y: y + CGFloat(rng.double() * 14 - 7)))
            ctx.strokePath()
        }
        let cx = W * 0.5, cy = H * (0.50 + CGFloat(rng.double()) * 0.04)
        ellipse(ctx, cx + 5, cy + 9, W * 0.66, H * 0.62, rgb(0, 0, 0, 0.30))
        ellipse(ctx, cx, cy, W * 0.62, H * 0.58, rgb(246, 244, 236))
        ellipse(ctx, cx, cy, W * 0.56, H * 0.52, rgb(238, 236, 226))
        ctx.setStrokeColor(rgb(255, 255, 255, 0.55))
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: cx - W * 0.28, y: cy - H * 0.26, width: W * 0.56, height: H * 0.52))
        ellipse(ctx, cx - W * 0.09, cy - H * 0.05, W * 0.22, H * 0.17, rgb(108, 142, 88))
        ellipse(ctx, cx + W * 0.07, cy - H * 0.06, W * 0.17, H * 0.13, rgb(208, 184, 124))
        ellipse(ctx, cx - W * 0.02, cy + H * 0.09, W * 0.19, H * 0.11, rgb(148, 92, 68))
        ellipse(ctx, cx + W * 0.16, cy + H * 0.10, W * 0.10, H * 0.08, rgb(232, 220, 178))
        for _ in 0..<46 {
            let fx = cx + CGFloat(rng.double() - 0.5) * W * 0.34
            let fy = cy + CGFloat(rng.double() - 0.5) * H * 0.26
            ellipse(ctx, fx, fy, CGFloat(rng.range(3, 10)), CGFloat(rng.range(2, 6)),
                    [rgb(86, 128, 64, 0.8), rgb(236, 212, 152, 0.7), rgb(122, 74, 54, 0.7)][rng.int(3)])
        }
        // Garnish and a dusting.
        for _ in 0..<9 {
            leaf(ctx, cx + CGFloat(rng.double() - 0.5) * W * 0.3, cy + CGFloat(rng.double() - 0.5) * H * 0.22,
                 CGFloat(rng.range(10, 22)), CGFloat(rng.range(4, 8)), CGFloat(rng.double() * .pi * 2),
                 rgb(64, 118, 58, 0.9))
        }
        scatter(ctx, &rng, count: 70, in: CGRect(x: cx - W * 0.26, y: cy - H * 0.24, width: W * 0.52, height: H * 0.48),
                rgb(70, 60, 40), size: 1...2.2, alpha: 0.08...0.3)
        // Cutlery and a glass.
        rect(ctx, W * 0.13, H * 0.24, W * 0.018, H * 0.50, rgb(180, 184, 182, 0.9))
        rect(ctx, W * 0.10, H * 0.22, W * 0.055, H * 0.055, rgb(192, 196, 194, 0.9))
        for i in 0..<4 {
            rect(ctx, W * 0.104 + CGFloat(i) * W * 0.013, H * 0.22, 3, H * 0.07, rgb(180, 184, 182, 0.9))
        }
        rect(ctx, W * 0.85, H * 0.26, W * 0.016, H * 0.48, rgb(180, 184, 182, 0.9))
        ellipse(ctx, W * 0.855, H * 0.78, W * 0.16, H * 0.16, rgb(216, 234, 228, 0.22))
        ctx.setStrokeColor(rgb(244, 250, 246, 0.55))
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: W * 0.775, y: H * 0.70, width: W * 0.16, height: H * 0.16))
        ctx.setStrokeColor(rgb(255, 255, 255, 0.4))
        ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: W * 0.80, y: H * 0.76))
        ctx.addLine(to: CGPoint(x: W * 0.83, y: H * 0.86))
        ctx.strokePath()
    }

    /// A jar of stems on a bright table.
    static func flowers(_ ctx: CGContext, _ s: CGSize, _ rng: inout DemoRandom) {
        let W = s.width, H = s.height
        vertical(ctx, CGRect(x: 0, y: 0, width: W, height: H), [rgb(244, 242, 232), rgb(212, 214, 202)])
        glow(ctx, at: CGPoint(x: W * 0.72, y: H * 0.16), radius: W * 0.7, rgb(255, 250, 226, 0.55))
        rect(ctx, 0, H * 0.72, W, 2, rgb(150, 148, 132, 0.25))
        let jx = W * (0.34 + CGFloat(rng.double()) * 0.28)
        ellipse(ctx, jx + 6, H * 0.84, W * 0.26, H * 0.05, rgb(90, 82, 64, 0.22))
        // Stems first, behind the glass.
        for _ in 0..<7 {
            let top = H * (0.20 + rng.double() * 0.18)
            let dx = CGFloat(rng.double() - 0.5) * W * 0.26
            ctx.setStrokeColor(rgb(86, 124, 74))
            ctx.setLineWidth(2.2)
            ctx.move(to: CGPoint(x: jx, y: H * 0.78))
            ctx.addQuadCurve(to: CGPoint(x: jx + dx, y: top),
                             control: CGPoint(x: jx + dx * 1.4, y: H * 0.52))
            ctx.strokePath()
            leaf(ctx, jx + dx * 1.15, top + (H * 0.78 - top) * 0.42, W * 0.09, H * 0.035,
                 CGFloat(rng.double() * 1.4 - 0.7), rgb(96, 138, 82))
            let petals = 5 + rng.int(3)
            let bloom = [rgb(244, 236, 214), rgb(230, 200, 150), rgb(214, 152, 140)][rng.int(3)]
            for p in 0..<petals {
                let a = CGFloat(p) / CGFloat(petals) * 2 * .pi
                ellipse(ctx, jx + dx + cos(a) * W * 0.026, top + sin(a) * W * 0.026,
                        W * 0.034, W * 0.026, bloom.copy(alpha: 0.92) ?? bloom, rotation: a)
            }
            ellipse(ctx, jx + dx, top, W * 0.018, W * 0.018, rgb(196, 168, 88))
        }
        // The glass jar, translucent.
        vertical(ctx, CGRect(x: jx - W * 0.10, y: H * 0.66, width: W * 0.20, height: H * 0.18),
                 [rgb(226, 238, 232, 0.35), rgb(198, 218, 214, 0.45)])
        ctx.setStrokeColor(rgb(248, 252, 248, 0.6))
        ctx.setLineWidth(2.4)
        ctx.strokeEllipse(in: CGRect(x: jx - W * 0.10, y: H * 0.645, width: W * 0.20, height: H * 0.05))
        ctx.move(to: CGPoint(x: jx - W * 0.10, y: H * 0.67))
        ctx.addLine(to: CGPoint(x: jx - W * 0.09, y: H * 0.83))
        ctx.addQuadCurve(to: CGPoint(x: jx + W * 0.09, y: H * 0.83), control: CGPoint(x: jx, y: H * 0.86))
        ctx.addLine(to: CGPoint(x: jx + W * 0.10, y: H * 0.67))
        ctx.strokePath()
        ctx.setStrokeColor(rgb(255, 255, 255, 0.35))
        ctx.setLineWidth(4)
        ctx.move(to: CGPoint(x: jx - W * 0.06, y: H * 0.69))
        ctx.addLine(to: CGPoint(x: jx - W * 0.055, y: H * 0.80))
        ctx.strokePath()
        scatter(ctx, &rng, count: 60, in: CGRect(x: 0, y: H * 0.80, width: W, height: H * 0.20),
                rgb(110, 100, 80), size: 1...2.2, alpha: 0.06...0.2)
    }

    /// Still water: mountains and their reflection, stones in the foreground.
    static func lake(_ ctx: CGContext, _ s: CGSize, _ rng: inout DemoRandom) {
        let W = s.width, H = s.height
        let mirror = H * 0.58
        vertical(ctx, CGRect(x: 0, y: 0, width: W, height: mirror),
                 [rgb(56, 108, 118), rgb(150, 190, 186), rgb(228, 234, 214)])
        glow(ctx, at: CGPoint(x: W * 0.30, y: H * 0.22), radius: W * 0.34, rgb(255, 246, 214, 0.4))
        let tones = [rgb(48, 86, 88), rgb(62, 104, 98), rgb(78, 122, 108)]
        for k in 0..<3 {
            let base = mirror - H * (0.24 - CGFloat(k) * 0.07)
            ctx.setFillColor(tones[k])
            ctx.beginPath()
            ctx.move(to: CGPoint(x: -10, y: mirror))
            ctx.addLine(to: CGPoint(x: -10, y: base))
            var x: CGFloat = -10
            while x < W + 10 {
                let w = CGFloat(rng.range(Int(W * 0.20), Int(W * 0.42)))
                let peak = base - CGFloat(rng.range(20, Int(H * 0.30)))
                ctx.addQuadCurve(to: CGPoint(x: min(W + 10, x + w), y: base),
                                 control: CGPoint(x: x + w * 0.45, y: peak))
                x += w
            }
            ctx.addLine(to: CGPoint(x: W + 10, y: mirror))
            ctx.closePath()
            ctx.fillPath()
        }
        for _ in 0..<40 {
            ellipse(ctx, CGFloat(rng.range(0, Int(W))), mirror - CGFloat(rng.range(0, 90)),
                    CGFloat(rng.range(2, 6)), CGFloat(rng.range(2, 5)), rgb(226, 240, 232, 0.35))
        }
        // Water, with the ridge inverted into it.
        vertical(ctx, CGRect(x: 0, y: mirror, width: W, height: H - mirror),
                 [rgb(90, 138, 130), rgb(38, 72, 74), rgb(22, 46, 50)])
        ctx.saveGState()
        ctx.translateBy(x: 0, y: mirror * 2)
        ctx.scaleBy(x: 1, y: -1)
        for k in 0..<3 {
            let base = mirror - H * (0.24 - CGFloat(k) * 0.07)
            ctx.setFillColor(tones[k].copy(alpha: 0.22) ?? tones[k])
            ctx.beginPath()
            ctx.move(to: CGPoint(x: -10, y: mirror))
            ctx.addLine(to: CGPoint(x: -10, y: base))
            var x: CGFloat = -10
            while x < W + 10 {
                let w = CGFloat(rng.range(Int(W * 0.20), Int(W * 0.42)))
                ctx.addQuadCurve(to: CGPoint(x: min(W + 10, x + w), y: base),
                                 control: CGPoint(x: x + w * 0.45, y: base - CGFloat(rng.range(20, 60))))
                x += w
            }
            ctx.addLine(to: CGPoint(x: W + 10, y: mirror))
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.restoreGState()
        for _ in 0..<28 {
            let y = mirror + CGFloat(rng.range(0, Int(H - mirror)))
            let w = CGFloat(rng.range(20, 120))
            rect(ctx, CGFloat(rng.range(0, Int(W - w))), y, w, CGFloat(rng.range(1, 3)),
                 rgb(240, 246, 236, 0.06 + rng.double() * 0.12))
        }
        // Foreground stones.
        for _ in 0..<4 {
            let sx = CGFloat(rng.range(0, Int(W))), sy = H - CGFloat(rng.range(4, 34))
            let sw = CGFloat(rng.range(30, 78))
            ellipse(ctx, sx, sy, sw, sw * 0.42, rgb(48, 56, 54))
            ellipse(ctx, sx - sw * 0.12, sy - sw * 0.06, sw * 0.55, sw * 0.22, rgb(96, 106, 100, 0.7))
        }
    }

    /// Vignette, a tint of light, and grain: the last thing a phone camera does to a picture.
    static func finish(_ ctx: CGContext, _ s: CGSize, _ rng: inout DemoRandom) {
        let space = CGColorSpaceCreateDeviceRGB()
        // Time of day, varied per picture: warm late light, cool shade, or flat paper.
        let tints = [rgb(255, 206, 140, 0.16), rgb(186, 226, 220, 0.14), rgb(255, 246, 228, 0.12), rgb(96, 148, 142, 0.10)]
        let tint = tints[rng.int(tints.count)]
        if let g = CGGradient(colorsSpace: space, colors: [tint, tint.copy(alpha: 0) ?? tint] as CFArray, locations: [0, 1]) {
            let from = CGPoint(x: rng.chance(0.5) ? 0 : s.width, y: 0)
            ctx.drawLinearGradient(g, start: from, end: CGPoint(x: s.width - from.x, y: s.height), options: [])
        }
        if rng.chance(0.35) {
            rect(ctx, 0, 0, s.width, s.height, rgb(0, 0, 0, rng.double() * 0.10))
        }
        let c = CGPoint(x: s.width / 2, y: s.height / 2)
        if let g = CGGradient(colorsSpace: space, colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.34)] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: c, startRadius: s.width * 0.30, endCenter: c,
                                   endRadius: s.width * 0.82, options: [.drawsAfterEndLocation])
        }
        scatter(ctx, &rng, count: 1400, in: CGRect(origin: .zero, size: s), rgb(255, 255, 255),
                size: 1...1.6, alpha: 0.01...0.05)
    }
}
