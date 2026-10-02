import SwiftUI

/// 初回の freee 連携設定。手順を上から順に進める
struct SetupView: View {
    private static let developerPageURL = URL(string: "https://app.secure.freee.co.jp/developers/applications")!

    let state: AppState
    let onDone: () -> Void

    @State private var clientID: String
    @State private var clientSecret: String
    @State private var code = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    init(state: AppState, onDone: @escaping () -> Void) {
        self.state = state
        self.onDone = onDone
        // Keychain の読み出しは初期化時の1回だけにする
        let saved = state.savedClient
        _clientID = State(initialValue: saved?.id ?? "")
        _clientSecret = State(initialValue: saved?.secret ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            intro
            step(1, "アプリの情報を入力") {
                // ラベル幅が違っても入力欄の左端をそろえる
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Client ID")
                            .gridColumnAlignment(.trailing)
                        TextField("", text: $clientID)
                    }
                    GridRow {
                        Text("Client Secret")
                        SecureField("", text: $clientSecret)
                    }
                }
            }
            step(2, "freee にログインして許可") {
                HStack(alignment: .firstTextBaseline) {
                    Text("ブラウザで認可ページが開きます。許可すると認可コードが表示されます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("認可ページを開く") {
                        state.openAuthorizePage(clientID: clientID)
                    }
                    .disabled(trimmedClientID.isEmpty)
                }
            }
            step(3, "認可コードを貼り付け") {
                LabeledContent("認可コード") {
                    TextField("", text: $code)
                }
            }
            footer
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 440)
        .onSubmit {
            if canConnect {
                connect()
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("freee の開発者ページでアプリを作成し、コールバック URL に `urn:ietf:wg:oauth:2.0:oob` を設定してください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("freee 開発者ページを開く", destination: Self.developerPageURL)
                .font(.callout)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor, in: Circle())
                Text(title)
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.leading, 26)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color(nsColor: .systemRed))
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .systemRed).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                    Text("連携しています…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("連携する", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)
            }
        }
    }

    private var trimmedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConnect: Bool {
        !isConnecting
            && !trimmedClientID.isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await state.connect(
                    clientID: clientID,
                    clientSecret: clientSecret,
                    code: code.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                isConnecting = false
                onDone()
            } catch {
                isConnecting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
