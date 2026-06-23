// 类型徽标 + 运行状态合一的动效，严格对齐 StatusIconsPreview.jsx（逐帧口径）：
//   Claude = 12 瓣锥形花瓣星芒（rayPath 几何）
//     working  = 4s 整转 + ±4% 呼吸 + 每循环一次爆散（花瓣收缩进核心、
//                12 颗粒子外漂回收、辉光随爆散下沉）—— jsx burst/drift
//     thinking = 变紫 ±10° 摆动 + ±9% 呼吸 + 花瓣按角度错相微光(shimmer)
//     done     = 42°惯性刹停 + 0.93→1 回弹落定 + 庆祝粒子外放 + 辉光闪落
//                + 绿角标延迟弹出画勾（jsx 26-44/38-56 帧时序）
//   Codex  = 蓝紫三段渐变云朵 + 白 > + 下划线光标
//     working  = 光标阶跃闪烁 + ±2.5% 呼吸；thinking = ±6° 摆动 + ±5% 呼吸
//                + 光标呼吸式明暗；done = 回弹落定 + 辉光闪落 + 角标
//   本地终端 = 灰白 ❯ + 琥珀竖线光标闪烁 + 静态柔光
//   远程 SSH = 蓝 ❯ + 竖线光标 + 底部流动虚线（lineDashPhase 行军）
//
// 性能架构（三轮实测教训）：
//   1) SwiftUI repeatForever：ProMotion 下 120Hz 重求值视图 → 10%+ CPU。
//   2) TimelineView 12fps + SwiftUI shape：每 tick 完整更新事务 → 仍 10%+。
//   3) TimelineView 12fps + Canvas：每帧一次事务照样 ~5ms。
//   结论：持续动画必须交给 Core Animation —— repeatForever 的 CAAnimation
//   提交一次后由 render server 执行，app 进程 0 CPU。爆散/粒子也全部是
//   预排 keyframe，进程内没有逐帧工作。
import AppKit
import SwiftUI

struct EmblemView: NSViewRepresentable {
    let kind: WindowType
    let phase: DisplayPhase
    var size: CGFloat = 18

    func makeNSView(context: Context) -> EmblemBackingView { EmblemBackingView() }

    func updateNSView(_ v: EmblemBackingView, context: Context) {
        v.configure(kind: kind, phase: phase, size: size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EmblemBackingView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

/// CALayer 徽标实体。配置（kind/phase/size）变化时整树重建——状态切换是
/// 低频事件，重建一棵 19px 的小树可忽略；动画全部 repeatForever / 一次性
/// keyframe，由 render server 跑，进程内不再有逐帧工作。
final class EmblemBackingView: NSView {
    private var current: (WindowType, DisplayPhase, CGFloat)?

    override var isFlipped: Bool { true } // 与 SwiftUI/jsx 同向（y 向下）

    /// jsx LOOP=120 帧 @30fps = 4 秒；burst/drift/celebrate 的帧号都换算成
    /// 该周期内的相对时刻（keyTimes = 帧号/120）。
    private static let loopDur: Double = 4

    func configure(kind: WindowType, phase: DisplayPhase, size: CGFloat) {
        let cfg = (kind, phase, size)
        if let c = current, c == cfg { return }
        current = cfg
        rebuild()
    }

    /// CALayer 持有的是构建时解析的静态 CGColor —— Theme 动态色必须在
    /// 本视图的有效外观下取值，且外观（日间/夜间壳层）切换时整树重建。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    private func rebuild() {
        guard let (kind, phase, size) = current else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            buildTree(kind: kind, phase: phase, size: size)
        }
    }

    private func buildTree(kind: WindowType, phase: DisplayPhase, size: CGFloat) {
        wantsLayer = true
        guard let root = layer else { return }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }

        let S = size
        let active = phase == .waiting || phase == .working || phase == .thinking

        // 核心容器：thinking 缩小上移给三点腾位；idle 整体减淡。
        let core = CALayer()
        core.frame = CGRect(x: 0, y: 0, width: S, height: S)
        root.addSublayer(core)
        if phase == .idle { root.opacity = 0.45 }
        if phase == .thinking {
            core.setAffineTransform(
                CGAffineTransform(translationX: 0, y: -S * 0.12).scaledBy(x: 0.74, y: 0.74)
            )
        }

        switch kind {
        case .claude: buildSpark(in: core, S: S, phase: phase, active: active)
        case .codex: buildCloud(in: core, S: S, phase: phase, active: active)
        case .shell: buildTerm(in: core, S: S, phase: phase, active: active)
        case .ssh: buildSSH(in: core, S: S, phase: phase, active: active)
        }

        if phase == .thinking {
            buildDots(in: root, S: S, kind: kind, active: active)
        }
        if phase == .waiting, active {
            // 等待输入：整体脉冲（缩放 + 透明度，2s 周期）。
            core.add(loop(key: "transform.scale", from: 1, to: 1.12, dur: 1), forKey: "pulseS")
            core.add(loop(key: "opacity", from: 1, to: 0.75, dur: 1), forKey: "pulseO")
        }
        if phase == .done || phase == .error {
            buildBadge(in: root, S: S, ok: phase == .done)
        }
    }

    // MARK: 动画工厂

    /// 往返循环（autoreverse + repeatForever）。
    private func loop(key: String, from: CGFloat, to: CGFloat, dur: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.duration = dur
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = false
        return a
    }

    /// 匀速整转（jsx working：每 LOOP 一圈 => 无缝）。
    private func spin(dur: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = CGFloat.pi * 2
        a.duration = dur
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        return a
    }

    /// 光标阶跃闪烁（jsx：每 15 帧翻转 = 0.5s，discrete 不插值）。
    private func blink() -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 1, 0.13, 0.13]
        a.keyTimes = [0, 0.5, 0.5, 1]
        a.duration = 1
        a.calculationMode = .discrete
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        return a
    }

    /// 爆散周期 keyframe（jsx burst：60-76 帧升、96-114 帧落，4s 循环）。
    /// keyTimes = [0, 60, 76, 96, 114, 120]/120。
    private func burstCycle(key: String, idleV: CGFloat, burstV: CGFloat) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: key)
        a.values = [idleV, idleV, burstV, burstV, idleV, idleV]
        a.keyTimes = [0, 0.5, 0.633, 0.8, 0.95, 1]
        a.duration = Self.loopDur
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        return a
    }

    /// 一次性动画公共参数。
    private func once(_ a: CAAnimation, delay: Double = 0) -> CAAnimation {
        a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        return a
    }

    /// easeOutBack（jsx 落定回弹），控制点带过冲。
    private static let easeOutBack = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)

    // MARK: 形状构建

    private func shape(_ path: CGPath, stroke: NSColor? = nil, fill: NSColor? = nil,
                       lineWidth: CGFloat = 0, frame: CGRect) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.frame = frame
        l.path = path
        l.strokeColor = stroke?.cgColor
        l.fillColor = fill?.cgColor ?? NSColor.clear.cgColor
        l.lineWidth = lineWidth
        l.lineCap = .round
        l.lineJoin = .round
        return l
    }

    /// 辉光：预渲染的径向渐变位图 + 呼吸透明度。
    /// 不用 CAGradientLayer(.radial)——它挂 opacity 动画时合成路径回落到
    /// 进程内逐帧重绘（实测 glow 开/关 = 4% vs 0% CPU）；位图纹理只上传
    /// 一次，opacity 动画在 render server 合成，进程 0 开销。
    private func glowLayer(S: CGFloat, color: NSColor, base: Float, amp: Float, active: Bool) -> CALayer {
        let l = CALayer()
        l.frame = CGRect(x: 0, y: 0, width: S, height: S)
        l.contents = Self.glowImage(size: S, color: color)
        l.opacity = base
        if active, amp > 0 {
            l.add(loop(key: "opacity", from: CGFloat(base - amp), to: CGFloat(base + amp), dur: 1), forKey: "breathe")
        }
        return l
    }

    private static func glowImage(size S: CGFloat, color: NSColor) -> CGImage? {
        let px = Int(S * 2) // 2x 备份比例足够（小尺寸柔光）
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let colors = [color.withAlphaComponent(0.55).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
        guard let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return nil }
        let c = CGPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
        ctx.drawRadialGradient(
            grad, startCenter: c, startRadius: CGFloat(px) * 0.08,
            endCenter: c, endRadius: CGFloat(px) * 0.52, options: []
        )
        return ctx.makeImage()
    }

    // MARK: Claude 星芒（jsx RAYS 角度/长度表 + rayPath 锥形花瓣几何）

    /// (角度°, 长度比例)。
    private static let rays: [(CGFloat, CGFloat)] = [
        (17, 0.91), (40, 0.87), (59, 0.90), (95, 0.95),
        (120, 0.90), (142, 0.89), (174, 0.89), (213, 0.93),
        (239, 1.00), (279, 0.84), (310, 0.87), (354, 0.83),
    ]

    /// jsx rayPath：底宽 wb 收到尖宽 wt 的锥形花瓣，尖端二次曲线圆帽。
    private static func petalPath(cx: CGFloat, cy: CGFloat, angleDeg: CGFloat,
                                  r0: CGFloat, r1: CGFloat, wb: CGFloat, wt: CGFloat) -> CGPath {
        let a = angleDeg * .pi / 180
        let dx = cos(a), dy = sin(a)
        let px = -dy, py = dx
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx + dx * r0 + px * wb, y: cy + dy * r0 + py * wb))
        p.addLine(to: CGPoint(x: cx + dx * r1 + px * wt, y: cy + dy * r1 + py * wt))
        p.addQuadCurve(
            to: CGPoint(x: cx + dx * r1 - px * wt, y: cy + dy * r1 - py * wt),
            control: CGPoint(x: cx + dx * (r1 + wt * 1.4), y: cy + dy * (r1 + wt * 1.4))
        )
        p.addLine(to: CGPoint(x: cx + dx * r0 - px * wb, y: cy + dy * r0 - py * wb))
        p.closeSubpath()
        return p
    }

    private func buildSpark(in parent: CALayer, S: CGFloat, phase: DisplayPhase, active: Bool) {
        let tint = phase == .thinking ? NSColor(Theme.think) : NSColor(Theme.claude)
        let working = active && phase == .working
        let thinking = active && phase == .thinking
        let done = phase == .done

        // jsx 几何：R=0.46S，core=0.19R，花瓣底半宽 0.1R / 尖半宽 0.072R。
        let c = S / 2
        let R = S * 0.46
        let coreR = R * 0.19
        let wb = R * 0.10
        let wt = R * 0.072
        let full = CGRect(x: 0, y: 0, width: S, height: S)

        // 辉光容器：子层跑呼吸，容器跑爆散下沉（两层 opacity 相乘，互不冲突）。
        if working || thinking || done {
            let glowWrap = CALayer()
            glowWrap.frame = full
            let glow = glowLayer(
                S: S, color: tint,
                base: done ? 0.32 : (thinking ? 0.5 : 0.55),
                amp: thinking ? 0.35 : 0.25,
                active: working || thinking
            )
            glowWrap.addSublayer(glow)
            if working {
                // glowOpacity=(0.55+呼吸)·(1-burst)+0.45·burst → 容器近似乘 0.75。
                glowWrap.add(burstCycle(key: "opacity", idleV: 1, burstV: 0.75), forKey: "burstDim")
            }
            if done {
                // jsx：14-26 帧闪起到 0.8，30-72 帧衰到 0.32 收住。
                let flash = CAKeyframeAnimation(keyPath: "opacity")
                flash.values = [0, 0, 0.8, 0.32]
                flash.keyTimes = [0, 0.16, 0.29, 0.8]
                flash.duration = 3
                glow.opacity = 0.32
                glow.add(once(flash), forKey: "flash")
            }
            parent.addSublayer(glowWrap)
        }

        // 星芒容器：整转/摆动/呼吸/刹停都挂在这里。
        let spark = CALayer()
        spark.frame = full
        parent.addSublayer(spark)

        for ray in Self.rays {
            let r1 = coreR + (R * ray.1 - wt - coreR)
            let petal = CAShapeLayer()
            petal.frame = full
            petal.path = Self.petalPath(cx: c, cy: c, angleDeg: ray.0, r0: coreR * 0.4, r1: r1, wb: wb, wt: wt)
            petal.fillColor = tint.cgColor
            spark.addSublayer(petal)

            if working {
                // 爆散：花瓣收缩进核心 + 隐去（层级缩放近似 jsx 的长度坍缩）。
                petal.add(burstCycle(key: "transform.scale", idleV: 1, burstV: 0.15), forKey: "burstS")
                petal.add(burstCycle(key: "opacity", idleV: 1, burstV: 0), forKey: "burstO")
            } else if thinking {
                // 微光：0.5↔1.0，4s 周期，按花瓣角度错相绕圈（jsx shimmer）。
                let sh = loop(key: "opacity", from: 0.5, to: 1.0, dur: Self.loopDur / 2)
                sh.timeOffset = Double(ray.0 / 360) * Self.loopDur
                petal.add(sh, forKey: "shimmer")
            }
        }

        // 核心圆点（爆散时缩没）。
        let dot = CAShapeLayer()
        dot.frame = full
        dot.path = CGPath(ellipseIn: CGRect(x: c - coreR, y: c - coreR, width: coreR * 2, height: coreR * 2), transform: nil)
        dot.fillColor = tint.cgColor
        spark.addSublayer(dot)
        if working {
            dot.add(burstCycle(key: "transform.scale", idleV: 1, burstV: 0.04), forKey: "burstS")
        }

        // 粒子：working = 周期外漂回收（drift）；done = 一次性庆祝外放。
        if working || done {
            buildParticles(in: spark, S: S, R: R, wt: wt, tint: tint, celebrate: done)
        }

        if working {
            spark.add(spin(dur: Self.loopDur), forKey: "spin")
            spark.add(loop(key: "transform.scale", from: 0.96, to: 1.04, dur: 1), forKey: "breathe")
        } else if thinking {
            // jsx：±10° 摆动（4s 全周期）+ ±9% 呼吸（2s）。
            spark.add(loop(key: "transform.rotation.z", from: -.pi / 18, to: .pi / 18, dur: 2), forKey: "sway")
            spark.add(loop(key: "transform.scale", from: 0.91, to: 1.09, dur: 1), forKey: "breathe")
        } else if done {
            // jsx：42° 带惯性刹停（0-20 帧）+ 0.93→1 回弹落定（6-28 帧）。
            let brake = CABasicAnimation(keyPath: "transform.rotation.z")
            brake.fromValue = 42 * CGFloat.pi / 180
            brake.toValue = 0
            brake.duration = 0.67
            brake.timingFunction = CAMediaTimingFunction(name: .easeOut)
            spark.add(once(brake), forKey: "brake")
            let settle = CABasicAnimation(keyPath: "transform.scale")
            settle.fromValue = 0.93
            settle.toValue = 1
            settle.duration = 0.73
            settle.timingFunction = Self.easeOutBack
            spark.add(once(settle, delay: 0.2), forKey: "settle")
        }
    }

    /// 12 颗粒子（jsx：角度抖动 + 亮度梯度）。working 周期 keyframe 外漂回收；
    /// done 一次性外放衰隐（celebrate 14-44 帧）。
    private func buildParticles(in parent: CALayer, S: CGFloat, R: CGFloat, wt: CGFloat,
                                tint: NSColor, celebrate: Bool) {
        let c = S / 2
        for (i, ray) in Self.rays.enumerated() {
            let jitter = (CGFloat((i * 5) % 12) - 5.5) * 1.4
            let a = (ray.0 + jitter) * .pi / 180
            let brightness = 0.55 + 0.45 * (CGFloat((i * 7) % 12) / 11)
            let ps = wt * 1.45 * (0.7 + 0.3 * brightness)
            let p = CALayer()
            p.bounds = CGRect(x: 0, y: 0, width: ps * 2, height: ps * 2)
            p.cornerRadius = ps
            p.backgroundColor = tint.cgColor
            p.opacity = 0
            parent.addSublayer(p)

            let inner = CGPoint(x: c + cos(a) * R * ray.1 * 0.45, y: c + sin(a) * R * ray.1 * 0.45)
            if celebrate {
                // 外放：0.95R→1.5R，透明度 0.9→0，半径收一半。
                let from = CGPoint(x: c + cos(a) * R * ray.1 * 0.95, y: c + sin(a) * R * ray.1 * 0.95)
                let to = CGPoint(x: c + cos(a) * R * ray.1 * 1.5, y: c + sin(a) * R * ray.1 * 1.5)
                p.position = to
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = from
                move.toValue = to
                move.duration = 1.0
                move.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.add(once(move, delay: 0.47), forKey: "fly")
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.9 * brightness
                fade.toValue = 0
                fade.duration = 1.0
                p.add(once(fade, delay: 0.47), forKey: "fade")
                let shrink = CABasicAnimation(keyPath: "transform.scale")
                shrink.fromValue = 1
                shrink.toValue = 0.5
                shrink.duration = 1.0
                p.add(once(shrink, delay: 0.47), forKey: "shrink")
            } else {
                // 周期外漂：drift 60-88 帧升、88-114 帧回（位置）；透明度随 burst。
                let outer = CGPoint(x: c + cos(a) * R * ray.1 * 0.85, y: c + sin(a) * R * ray.1 * 0.85)
                p.position = inner
                let move = CAKeyframeAnimation(keyPath: "position")
                move.values = [inner, inner, outer, inner, inner]
                move.keyTimes = [0, 0.5, 0.733, 0.95, 1]
                move.duration = Self.loopDur
                move.repeatCount = .infinity
                move.isRemovedOnCompletion = false
                p.add(move, forKey: "drift")
                p.add(burstCycle(key: "opacity", idleV: 0, burstV: brightness), forKey: "burstO")
            }
        }
    }

    // MARK: Codex 云朵（jsx blobPath 8 瓣 + 三段蓝紫渐变 + 白 > + 下划线光标）

    private static func blobPath(cx: CGFloat, cy: CGFloat, R: CGFloat, bumps: Int, amp: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let pts = 96
        for k in 0...pts {
            let th = CGFloat(k) / CGFloat(pts) * .pi * 2
            let r = R * (1 + amp * cos(CGFloat(bumps) * th))
            let pt = CGPoint(x: cx + cos(th) * r, y: cy + sin(th) * r)
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    private func buildCloud(in parent: CALayer, S: CGFloat, phase: DisplayPhase, active: Bool) {
        let working = phase == .working || phase == .waiting
        let thinking = phase == .thinking
        let done = phase == .done
        let c = S / 2
        let R = S * 0.37
        let full = CGRect(x: 0, y: 0, width: S, height: S)

        if active || done {
            let glow = glowLayer(
                S: S, color: NSColor(hexv: 0x6C58EF),
                base: done ? 0.28 : (thinking ? 0.34 : 0.32),
                amp: thinking ? 0.18 : 0.12, active: active
            )
            if done {
                // jsx：8-22 帧闪起到 0.55，30-72 帧衰减一半收住。
                let flash = CAKeyframeAnimation(keyPath: "opacity")
                flash.values = [0, 0, 0.55, 0.28]
                flash.keyTimes = [0, 0.09, 0.24, 0.8]
                flash.duration = 3
                glow.opacity = 0.28
                glow.add(once(flash), forKey: "flash")
            }
            parent.addSublayer(glow)
        }

        let body = CALayer()
        body.frame = full
        parent.addSublayer(body)

        // 渐变云朵本体：axial 渐变 + blob 蒙版。纹理只栅格化一次，
        // 后续动画全在 body 的 transform 上（render server 合成）。
        let grad = CAGradientLayer()
        grad.frame = full
        grad.colors = [
            NSColor(hexv: 0xACA0F6).cgColor,
            NSColor(hexv: 0x6C58EF).cgColor,
            NSColor(hexv: 0x4A38E2).cgColor,
        ]
        grad.locations = [0, 0.55, 1]
        grad.startPoint = CGPoint(x: 0, y: 0)
        grad.endPoint = CGPoint(x: 0.65, y: 1)
        let mask = CAShapeLayer()
        mask.path = Self.blobPath(cx: c, cy: c, R: R, bumps: 8, amp: 0.075)
        grad.mask = mask
        body.addSublayer(grad)

        // 顶部柔和高光（jsx：白 16% 椭圆）。
        let hl = shape(
            CGPath(ellipseIn: CGRect(x: c - R * 0.78, y: c - R * 0.74, width: R, height: R * 0.52), transform: nil),
            fill: NSColor.white.withAlphaComponent(0.16), frame: full
        )
        body.addSublayer(hl)

        // > 提示符
        let chev = CGMutablePath()
        chev.move(to: CGPoint(x: S * 0.345, y: S * 0.4))
        chev.addLine(to: CGPoint(x: S * 0.475, y: S * 0.5))
        chev.addLine(to: CGPoint(x: S * 0.345, y: S * 0.6))
        body.addSublayer(shape(chev, stroke: .white, lineWidth: S * 0.072, frame: full))

        // _ 下划线光标
        let cur = CALayer()
        cur.frame = CGRect(x: S * 0.535, y: S * 0.578, width: S * 0.14, height: S * 0.055)
        cur.cornerRadius = S * 0.027
        cur.backgroundColor = NSColor.white.cgColor
        body.addSublayer(cur)

        if working, active {
            body.add(loop(key: "transform.scale", from: 0.975, to: 1.025, dur: 1), forKey: "breathe")
            cur.add(blink(), forKey: "blink")
        } else if thinking {
            // jsx：±6° 摆动（4s 全周期）+ ±5% 呼吸 + 光标呼吸式明暗。
            body.add(loop(key: "transform.rotation.z", from: -.pi / 30, to: .pi / 30, dur: 2), forKey: "sway")
            body.add(loop(key: "transform.scale", from: 0.95, to: 1.05, dur: 1), forKey: "breathe")
            cur.add(loop(key: "opacity", from: 0.55, to: 1, dur: 1), forKey: "breatheCur")
        } else if done {
            // jsx：0.93→1 回弹落定（6-28 帧）。
            let settle = CABasicAnimation(keyPath: "transform.scale")
            settle.fromValue = 0.93
            settle.toValue = 1
            settle.duration = 0.73
            settle.timingFunction = Self.easeOutBack
            body.add(once(settle, delay: 0.2), forKey: "settle")
        }
    }

    // MARK: 本地终端（jsx：灰白 ❯ + 琥珀竖线光标 + 静态柔光）

    private func buildTerm(in parent: CALayer, S: CGFloat, phase: DisplayPhase, active: Bool) {
        let full = CGRect(x: 0, y: 0, width: S, height: S)
        // jsx termGlow 0.18α · 0.8 ≈ 位图基准 0.26，常亮不呼吸。
        parent.addSublayer(glowLayer(S: S, color: NSColor(Theme.termAccent), base: 0.26, amp: 0, active: false))

        let chev = CGMutablePath()
        chev.move(to: CGPoint(x: S * 0.26, y: S * 0.32))
        chev.addLine(to: CGPoint(x: S * 0.5, y: S * 0.5))
        chev.addLine(to: CGPoint(x: S * 0.26, y: S * 0.68))
        parent.addSublayer(shape(chev, stroke: NSColor(Theme.term), lineWidth: S * 0.085, frame: full))

        let cur = CALayer()
        cur.frame = CGRect(x: S * 0.6, y: S * 0.32, width: S * 0.052, height: S * 0.36)
        cur.cornerRadius = S * 0.026
        cur.backgroundColor = NSColor(Theme.termAccent).cgColor
        parent.addSublayer(cur)
        if active { cur.add(blink(), forKey: "blink") }
    }

    // MARK: 远程 SSH（jsx：辉光呼吸 + 光标闪烁 + 底部流动虚线行军）

    private func buildSSH(in parent: CALayer, S: CGFloat, phase: DisplayPhase, active: Bool) {
        let full = CGRect(x: 0, y: 0, width: S, height: S)
        // jsx sshGlow 0.6±0.25 → 位图基准折算。
        parent.addSublayer(glowLayer(
            S: S, color: NSColor(Theme.ssh),
            base: 0.45, amp: active ? 0.18 : 0, active: active
        ))

        // ❯ + 竖线光标整体上移，给底部虚线留位。
        let chev = CGMutablePath()
        chev.move(to: CGPoint(x: S * 0.26, y: S * 0.24))
        chev.addLine(to: CGPoint(x: S * 0.48, y: S * 0.41))
        chev.addLine(to: CGPoint(x: S * 0.26, y: S * 0.58))
        parent.addSublayer(shape(chev, stroke: NSColor(Theme.ssh), lineWidth: S * 0.08, frame: full))

        let cur = CALayer()
        cur.frame = CGRect(x: S * 0.58, y: S * 0.25, width: S * 0.05, height: S * 0.33)
        cur.cornerRadius = S * 0.025
        cur.backgroundColor = NSColor(Theme.ssh).cgColor
        parent.addSublayer(cur)
        if active { cur.add(blink(), forKey: "blink") }

        // 流动虚线（jsx SshFlowLine：每循环行进 4 个 dash 周期 => 无缝）。
        let dashPath = CGMutablePath()
        dashPath.move(to: CGPoint(x: S * 0.18, y: S * 0.82))
        dashPath.addLine(to: CGPoint(x: S * 0.82, y: S * 0.82))
        let dashLine = shape(dashPath, stroke: NSColor(Theme.ssh), lineWidth: S * 0.07, frame: full)
        dashLine.lineDashPattern = [NSNumber(value: Double(S * 0.12)), NSNumber(value: Double(S * 0.10))]
        dashLine.opacity = 0.55
        parent.addSublayer(dashLine)
        if active {
            let flow = CABasicAnimation(keyPath: "lineDashPhase")
            flow.fromValue = 0
            flow.toValue = -(S * 0.12 + S * 0.10) * 4
            flow.duration = Self.loopDur
            flow.repeatCount = .infinity
            flow.isRemovedOnCompletion = false
            dashLine.add(flow, forKey: "flow")
        }
    }

    // MARK: 思考三点（jsx ThinkingDots：半正弦抬起 + 相位差 0.9rad）

    private func buildDots(in parent: CALayer, S: CGFloat, kind: WindowType, active: Bool) {
        let color = NSColor(Theme.think).cgColor
        let r = S * 0.07
        let gap = S * 0.24
        for i in 0..<3 {
            let d = CALayer()
            d.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            d.cornerRadius = r
            d.position = CGPoint(x: S / 2 + gap * CGFloat(i - 1), y: S * 0.88)
            d.backgroundColor = color
            d.opacity = 0.45
            parent.addSublayer(d)
            guard active else { continue }
            // 周期 2s，逐点错相 0.9rad（≈0.286s）。
            let off = Double(i) * 0.286
            let lift = loop(key: "transform.translation.y", from: 0, to: -S * 0.10, dur: 1)
            lift.timeOffset = off
            d.add(lift, forKey: "lift")
            let fade = loop(key: "opacity", from: 0.45, to: 1, dur: 1)
            fade.timeOffset = off
            d.add(fade, forKey: "fade")
        }
    }

    // MARK: 完成/出错角标（jsx DoneBadge：pop 26-44 帧 + 画勾 38-56 帧）

    private func buildBadge(in parent: CALayer, S: CGFloat, ok: Bool) {
        let bx = S * 0.8, by = S * 0.8, br = S * 0.155
        let full = CGRect(x: 0, y: 0, width: S, height: S)

        let badge = CALayer()
        badge.bounds = full
        // 锚点设在角标圆心：pop 缩放围绕角标自身（jsx translate-scale-translate）。
        badge.anchorPoint = CGPoint(x: 0.8, y: 0.8)
        badge.position = CGPoint(x: bx, y: by)
        parent.addSublayer(badge)

        let circle = shape(
            CGPath(ellipseIn: CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2), transform: nil),
            stroke: NSColor(Theme.bg0),
            fill: ok ? NSColor(Theme.done) : NSColor(Theme.red),
            lineWidth: S * 0.028, frame: full
        )
        badge.addSublayer(circle)

        let markPath = CGMutablePath()
        if ok {
            markPath.move(to: CGPoint(x: bx - br * 0.45, y: by + br * 0.02))
            markPath.addLine(to: CGPoint(x: bx - br * 0.1, y: by + br * 0.38))
            markPath.addLine(to: CGPoint(x: bx + br * 0.48, y: by - br * 0.32))
        } else {
            markPath.move(to: CGPoint(x: bx, y: by - br * 0.5))
            markPath.addLine(to: CGPoint(x: bx, y: by + br * 0.08))
            markPath.move(to: CGPoint(x: bx, y: by + br * 0.45))
            markPath.addLine(to: CGPoint(x: bx, y: by + br * 0.46))
        }
        let mark = shape(markPath, stroke: NSColor(Theme.bg0), lineWidth: S * 0.045, frame: full)
        badge.addSublayer(mark)

        // 时序：done 走 jsx 帧号（0.87s pop / 1.27s 画勾）；error 立即弹出。
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.001
        pop.toValue = 1
        pop.duration = 0.6
        pop.timingFunction = Self.easeOutBack
        badge.add(once(pop, delay: ok ? 0.87 : 0.1), forKey: "pop")

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.6
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mark.add(once(draw, delay: ok ? 1.27 : 0.35), forKey: "draw")
    }
}

private extension NSColor {
    convenience init(hexv: UInt32) {
        self.init(
            srgbRed: CGFloat((hexv >> 16) & 0xFF) / 255,
            green: CGFloat((hexv >> 8) & 0xFF) / 255,
            blue: CGFloat(hexv & 0xFF) / 255,
            alpha: 1
        )
    }
}
