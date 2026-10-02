import SwiftUI

/// Dock の上に浮かぶ出勤ボタン。表示専用で、マウス操作は親の NSView が受け取る
struct ClockButtonView: View {
    /// タイル本体は 44pt。周囲 6pt は影を描くための余白
    static let panelSize = CGSize(width: 56, height: 56)
    private static let tileSize: CGFloat = 44
    /// Dock アイコンと同じ比率（1辺の約 22%）の連続角丸
    private static let cornerRadius: CGFloat = 10

    let state: AppState

    var body: some View {
        ZStack {
            tile
            content
        }
        .frame(width: Self.tileSize, height: Self.tileSize)
        .brightness(state.isHovering && isInteractive ? 0.08 : 0)
        .scaleEffect(state.isPressed && isInteractive ? 0.94 : 1)
        .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
        // 壁紙の明暗にかかわらず白い文字・スピナーで統一する
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.15), value: state.isHovering)
        .animation(.easeOut(duration: 0.1), value: state.isPressed)
        .animation(.easeInOut(duration: 0.25), value: state.phase)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return shape
            .fill(fillGradient)
            .overlay(shape.strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .opacity(0.7)
        case .needsSetup:
            VStack(spacing: 2) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                Text("設定")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.85))
        case .ready:
            Text("出勤")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
        case .busy:
            ProgressView()
                .controlSize(.small)
        case .working(let since):
            VStack(spacing: 1) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(AppState.format(since, "H:mm"))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    /// クリックに反応する phase のときだけホバー・押下の見た目を変える
    private var isInteractive: Bool {
        switch state.phase {
        case .ready, .working, .failed, .needsSetup: true
        case .loading, .busy: false
        }
    }

    private var fillGradient: LinearGradient {
        let (top, bottom): (Color, Color) = switch state.phase {
        case .ready:
            // 白文字でコントラスト比 4.5 以上を確保できる濃さの緑
            (Color(red: 0.13, green: 0.54, blue: 0.32), Color(red: 0.09, green: 0.46, blue: 0.27))
        case .busy:
            (Color(red: 0.13, green: 0.54, blue: 0.32).opacity(0.6), Color(red: 0.09, green: 0.46, blue: 0.27).opacity(0.6))
        case .failed:
            (Color(nsColor: .systemRed), Color(nsColor: .systemRed).opacity(0.85))
        case .loading, .needsSetup, .working:
            // 無彩色の暗いガラス。明るい壁紙でも暗い壁紙でも輪郭が残る
            (Color.black.opacity(0.50), Color.black.opacity(0.60))
        }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}
