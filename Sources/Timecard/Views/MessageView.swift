import SwiftUI

/// パネルの横に出すメッセージの中身。背景は MessagePanel が描く
struct MessageView: View {
    let message: String
    let isError: Bool
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Color(nsColor: .systemRed) : Color.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let onRetry {
                HStack {
                    Spacer()
                    Button("再取得", action: onRetry)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}
