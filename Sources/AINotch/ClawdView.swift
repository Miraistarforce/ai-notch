import SwiftUI

/// clawd-on-desk のピクセルアートを参考にした小さなClawd（カニ型キャラクター）。
/// エージェントの状態に合わせてアニメーションが変わる。
enum ClawdMode: Equatable {
    case idle                  // エージェントなし：立ち止まる
    case walk                  // 待機セッションあり：ぶらぶら歩く
    case work                  // 実行中：トンカチ作業
    case alert(isError: Bool)  // 承認待ち＝青「！」／エラー＝赤「！」
    case joy                   // 完了：バンザイジャンプ
}

enum ClawdArmPose {
    case normal   // 両腕横
    case bothUp   // バンザイ
    case leftUp   // 左腕を振り上げ（作業）
    case rightUp  // 右腕を振り上げ（作業）
}

struct ClawdWalker: View {
    /// 中心から左右に動ける幅（pt）
    let range: CGFloat
    let mode: ClawdMode

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let blink = t.truncatingRemainder(dividingBy: 4.2) < 0.18

            switch mode {
            case .idle:
                sprite(
                    ClawdSprite(stepUp: false, blink: blink, arms: .normal, mark: nil, markBob: 0),
                    dx: 0, dy: 0, facingRight: true
                )
            case .walk:
                let angle = 2 * Double.pi * t / 18.0
                let dx = CGFloat(sin(angle)) * range
                let velocity = cos(angle)
                let moving = abs(velocity) > 0.25
                let step = moving && Int(t / 0.28) % 2 == 0
                sprite(
                    ClawdSprite(stepUp: step, blink: blink, arms: .normal, mark: nil, markBob: 0),
                    dx: dx, dy: 0, facingRight: velocity >= 0
                )
            case .work:
                // その場で小さく揺れながらトンカチ作業（腕を交互に振り上げる）
                let sway = CGFloat(sin(2 * Double.pi * t / 11.0)) * range * 0.3
                let hammer = Int(t / 0.24) % 2 == 0
                sprite(
                    ClawdSprite(
                        stepUp: false,
                        blink: blink,
                        arms: hammer ? .leftUp : .rightUp,
                        mark: nil,
                        markBob: 0
                    ),
                    dx: sway, dy: hammer ? 0 : 0.8, facingRight: true
                )
            case .alert(let isError):
                // 立ち止まって頭上に「！」を出す（上下にぷかぷか）
                let bob = CGFloat(sin(2 * Double.pi * t / 0.9)) * 1.4
                sprite(
                    ClawdSprite(
                        stepUp: false,
                        blink: false,
                        arms: .normal,
                        mark: isError ? Color(nsColor: .systemRed) : Color(nsColor: .systemBlue),
                        markBob: bob
                    ),
                    dx: 0, dy: 0, facingRight: true
                )
            case .joy:
                // バンザイしながらぴょんぴょん跳ねる
                let jump = CGFloat(abs(sin(Double.pi * t / 0.45))) * 4.5
                sprite(
                    ClawdSprite(stepUp: false, blink: false, arms: .bothUp, mark: nil, markBob: 0),
                    dx: 0, dy: -jump, facingRight: true
                )
            }
        }
    }

    private func sprite(_ s: ClawdSprite, dx: CGFloat, dy: CGFloat, facingRight: Bool) -> some View {
        s
            .scaleEffect(x: facingRight ? 1 : -1, y: 1)
            .frame(width: 24, height: 27)
            .offset(x: dx, y: dy)
    }
}

/// Clawd本体のピクセル描画（1フレーム）
struct ClawdSprite: View {
    let stepUp: Bool
    let blink: Bool
    let arms: ClawdArmPose
    /// 頭上の「！」の色（nilなら非表示）
    let mark: Color?
    /// 「！」の上下アニメーション量
    let markBob: CGFloat

    private let bodyColor = Color(red: 0xDE / 255.0, green: 0x88 / 255.0, blue: 0x6D / 255.0)

    var body: some View {
        Canvas { context, size in
            // ピクセルグリッド: x 0...15, y 1...15。足（y=15）がキャンバス下端に接地する
            let unit = min(size.width / 15.0, size.height / 15.0)

            func px(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
                let rect = CGRect(
                    x: x * unit,
                    y: size.height - (15.0 - y) * unit,
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

            // 腕（ポーズ別）
            switch arms {
            case .normal:
                px(0, 9, 2, 2, bodyColor)
                px(13, 9, 2, 2, bodyColor)
            case .bothUp:
                px(0, 4.5, 1.5, 3, bodyColor)
                px(13.5, 4.5, 1.5, 3, bodyColor)
            case .leftUp:
                px(0, 5.5, 1.5, 3, bodyColor)
                px(13, 9, 2, 2, bodyColor)
            case .rightUp:
                px(0, 9, 2, 2, bodyColor)
                px(13.5, 5.5, 1.5, 3, bodyColor)
            }

            // 目（まばたきで細くなる）
            let eyeH = blink ? 0.5 : 2.0
            let eyeY = blink ? 9.0 : 8.0
            px(4, eyeY, 1, eyeH, .black)
            px(10, eyeY, 1, eyeH, .black)

            // 頭上の「！」マーク
            if let mark {
                let bob = Double(markBob)
                px(6.8, 1.0 + bob, 1.6, 2.6, mark)
                px(6.8, 4.4 + bob, 1.6, 1.1, mark)
            }
        }
    }
}
