import SwiftUI

struct ChangePasscodeView: View {
    let coordinator: VaultLockCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var newPasscode = ""
    @State private var confirmation = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Current Passcode") {
                    passcodeField("Current six-digit passcode", text: $current)
                }
                Section {
                    passcodeField("New six-digit passcode", text: $newPasscode)
                    passcodeField("Confirm new passcode", text: $confirmation)
                } header: {
                    Text("New Passcode")
                } footer: {
                    Text("Changing your passcode securely re-wraps the existing vault key. Media is not decrypted or rewritten.")
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(message)")
                    }
                }
            }
            .navigationTitle("Change Passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Change") { changePasscode() }
                        .disabled(current.count != 6 || newPasscode.count != 6 || confirmation.count != 6 || coordinator.isWorking)
                }
            }
        }
    }

    private func passcodeField(_ label: String, text: Binding<String>) -> some View {
        SecureField(label, text: text)
            .keyboardType(.numberPad)
            .textContentType(.password)
            .onChange(of: text.wrappedValue) { _, newValue in
                text.wrappedValue = String(newValue.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
            }
    }

    private func changePasscode() {
        Task {
            let succeeded = await coordinator.changePasscode(
                current: current,
                new: newPasscode,
                confirmation: confirmation
            )
            if succeeded {
                dismiss()
            } else {
                message = coordinator.userMessage
                current = ""
            }
        }
    }
}
