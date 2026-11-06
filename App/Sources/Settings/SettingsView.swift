import EmulationKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppModel.onboardingKey) private var onboardingComplete = false

    @State private var urlString = PassServiceSettings.urlString
    @State private var token = PassServiceSettings.token
    @State private var saveMessage: String?
    @State private var saveFailed = false

    private var hasChanges: Bool {
        urlString != PassServiceSettings.urlString || token != PassServiceSettings.token
    }

    private var urlIsValid: Bool {
        urlString.isEmpty || PassServiceSettings.url(from: urlString) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Presenting", value: Copy.title(for: app.availability))
                    if !Copy.detail(for: app.availability).isEmpty {
                        Text(Copy.detail(for: app.availability))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Contactless")
                } footer: {
                    if app.availability == .available {
                        Text("If another app answers readers first, you can choose the default contactless app in the Settings app.")
                    }
                }

                Section {
                    TextField("https://passes.example.com", text: $urlString)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Pass service URL")
                    SecureField("Token", text: $token)
                        .textContentType(.password)
                        .accessibilityLabel("Pass service token")
                    if !urlIsValid {
                        Label("Enter a full address starting with https://.", systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button("Save") { save() }
                        .disabled(!hasChanges || !urlIsValid)
                    if let saveMessage {
                        Text(saveMessage)
                            .font(.footnote)
                            .foregroundStyle(saveFailed ? .red : .secondary)
                    }
                } header: {
                    Text("Wallet Pass Service")
                } footer: {
                    Text("Passes are signed by your own service, so Add to Wallet needs both of these. The token is stored in the Keychain on this iPhone. Local addresses can use http://.")
                }

                Section("Privacy") {
                    Text("Tags and keys stay on this iPhone. Private keys never reach the pass service, logs, iCloud, or backups.")
                    Text(Copy.qrPrivacy)
                }
                .font(.footnote)

                Section("Signer Keys") {
                    Text(Copy.signerWarning)
                        .font(.footnote)
                }

                Section("Wallet Pass") {
                    Text(Copy.passLimits)
                        .font(.footnote)
                }

                Section("About") {
                    LabeledContent("Pass Type ID") {
                        Text(AppEnvironment.passTypeIdentifier)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("Show Introduction Again") {
                        dismiss()
                        onboardingComplete = false
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func save() {
        do {
            try PassServiceSettings.save(urlString: urlString, token: token)
            saveFailed = false
            saveMessage = PassServiceSettings.configuration() == nil
                ? "Saved. Add to Wallet needs both a URL and a token."
                : "Saved."
        } catch {
            saveFailed = true
            saveMessage = "Couldn't save the token. \(error.localizedDescription)"
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel.preview())
}
