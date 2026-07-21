import SwiftUI

/// clawd-on-desk のピクセルアートを参考にした小さなClawd（カニ型キャラクター）。
/// 閉じたノッチバーの中を左右にゆっくり歩き回る。
struct ClawdWalker: View {
    /// 中心から左右に動ける幅（pt）
    let range: CGFloat
    /// 動いているエージェントがいるか（いなければ立ち止まる）
    let active: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let period = 18.0
            let angle = 2 * Double.pi * t / period
            let dx = active ? CGFloat(sin(angle)) * range : 0
            let velocity = cos(angle)
            let moving = active && abs(velocity) > 0.25
            let facingRight = velocity >= 0
            let stepFrame = Int(t / 0.28) % 2 == 0
            // 約4秒に一度まばたき
            let blink = t.truncatingRemainder(dividingBy: 4.2) < 0.18

            ClawdSprite(
                stepUp: moving ? stepFrame : false,
                blink: blink
            )
            .scaleEffect(x: facingRight ? 1 : -1, y: 1)
            .frame(width: 24, height: 17)
            .offset(x: dx)
        }
    }
}

/// Clawd本体のピクセル描画（1フレーム）
struct ClawdSprite: View {
    let stepUp: Bool
    let blink: Bool

    private let bodyColor = Color(red: 0xDE / 255.0, green: 0x88 / 255.0, blue: 0x6D / 255.0)

    var body: some View {
        Canvas { context, size in
            // ピクセルグリッド: x 0...15, y 6...15（clawd-on-deskの座標系を踏襲）
            let unit = min(size.width / 15.0, size.height / 10.0)
            let originY = 6.0

            func px(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
                let rect = CGRect(
                    x: x * unit,
                    y: (y - originY) * unit,
                    width: w * unit,
                    height: h * unit
                )
                context.fill(Path(rect), with: .color(color))
            }

            // 足4本（歩行フレームでは交互に持ち上げる）
            let lift = stepUp ? 1.0 : 0.0
            px(3, 11 + lift, 1, 4 - lift, bodyColor)
            px(5, 11, 1, 4, bodyColor)
            px(9, 11 + lift, 1, 4 - lift, bodyColor)
            px(11, 11, 1, 4, bodyColor)

            // 胴体
            px(2, 6, 11, 7, bodyColor)

            // 両腕（ハサミ）
            px(0, 9, 2, 2, bodyColor)
            px(13, 9, 2, 2, bodyColor)

            // 目（まばたきで細くなる）
            let eyeH = blink ? 0.5 : 2.0
            let eyeY = blink ? 9.0 : 8.0
            px(4, eyeY, 1, eyeH, .black)
            px(10, eyeY, 1, eyeH, .black)
        }
    }
}
