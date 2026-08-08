import SwiftUI

struct RemovePasscodeView: View {
    let coordinator: VaultLockCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var currentPasscode = ""
    @State private var understandsRisk = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("QuietFrame will open without asking for a passcode whenever this iPhone is unlocked. Media remains encrypted with a random key in the iOS Keychain.")
                        .foregroundStyle(.secondary)
                    Toggle("I understand anyone using my unlocked iPhone can open the vault", isOn: $understandsRisk)
                    SecureField("Current six-digit passcode", text: $currentPasscode)
                        .keyboardType(.numberPad)
                        .onChange(of: currentPasscode) { _, value in
                            currentPasscode = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        }
                }

                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }

                Section {
                    Button("Turn Off App Passcode", role: .destructive) { removePasscode() }
                        .disabled(!understandsRisk || currentPasscode.count != 6)
                }
            }
            .navigationTitle("Turn Off Passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func removePasscode() {
        Task {
            if await coordinator.removePasscode(current: currentPasscode) {
                dismiss()
            } else {
                message = coordinator.userMessage
                currentPasscode = ""
            }
        }
    }
}
