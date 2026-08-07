import SwiftUI

struct ResetApplicationView: View {
    let coordinator: VaultLockCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var understandsDeletion = false
    @State private var confirmationText = ""
    @State private var passcode = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("All encrypted photos and videos", systemImage: "photo.stack")
                    Label("Albums, favorites, tags, and Trash", systemImage: "rectangle.stack")
                    Label("Passcode data and encryption keys", systemImage: "key")
                } header: {
                    Text("This Permanently Removes")
                }

                Section {
                    Toggle("I understand this cannot be undone", isOn: $understandsDeletion)
                    TextField("Type RESET", text: $confirmationText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    SecureField("Current six-digit passcode", text: $passcode)
                        .keyboardType(.numberPad)
                        .onChange(of: passcode) { _, value in
                            passcode = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        }
                } footer: {
                    Text("QuietFrame authenticates first, removes encrypted files, then deletes the Keychain master-key envelope.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }

                Section {
                    Button("Permanently Reset QuietFrame", role: .destructive) { reset() }
                        .disabled(!canReset || coordinator.isWorking)
                        .accessibilityIdentifier("confirm-reset")
                }
            }
            .navigationTitle("Final Reset Confirmation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var canReset: Bool {
        understandsDeletion && confirmationText == "RESET" && passcode.count == 6
    }

    private func reset() {
        Task {
            let succeeded = await coordinator.resetApplication(passcode: passcode)
            if succeeded {
                dismiss()
            } else {
                message = coordinator.userMessage
                passcode = ""
            }
        }
    }
}
