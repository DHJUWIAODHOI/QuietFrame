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
                Section {
                    QuietIntroduction(
                        title: "Change Passcode",
                        message: "Changing your passcode securely re-wraps the existing vault key. Media is not decrypted or rewritten.",
                        systemImage: "ellipsis.rectangle"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, QuietFrameTheme.contentSpacing)
                    .listRowBackground(Color.clear)
                }

                Section("Current Passcode") {
                    passcodeField("Current six-digit passcode", text: $current)
                }
                Section {
                    passcodeField("New six-digit passcode", text: $newPasscode)
                    passcodeField("Confirm new passcode", text: $confirmation)
                } header: {
                    Text("New Passcode")
                }
                if let message {
                    Section {
                        AuthenticationErrorMessage(message: message)
                            .accessibilityLabel("Error: \(message)")
                    }
                }
            }
            .listSectionSpacing(QuietFrameTheme.sectionSpacing)
            .quietFormStyle()
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
            .frame(minHeight: QuietFrameTheme.controlHeight)
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
