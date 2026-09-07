import SwiftUI

struct SetPasscodeView: View {
    let coordinator: VaultLockCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var passcode = ""
    @State private var confirmation = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    QuietIntroduction(
                        title: "Set Passcode",
                        message: "The existing vault key will be wrapped by this passcode. Media files do not need to be re-encrypted.",
                        systemImage: "lock.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, QuietFrameTheme.contentSpacing)
                    .listRowBackground(Color.clear)
                }

                Section {
                    SecureField("New six-digit passcode", text: $passcode)
                        .keyboardType(.numberPad)
                        .onChange(of: passcode) { _, value in passcode = digits(value) }
                        .frame(minHeight: QuietFrameTheme.controlHeight)
                    SecureField("Confirm passcode", text: $confirmation)
                        .keyboardType(.numberPad)
                        .onChange(of: confirmation) { _, value in confirmation = digits(value) }
                        .frame(minHeight: QuietFrameTheme.controlHeight)
                }

                if let message {
                    Section { AuthenticationErrorMessage(message: message) }
                }
            }
            .listSectionSpacing(QuietFrameTheme.sectionSpacing)
            .quietFormStyle()
            .navigationTitle("Set Passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { setPasscode() }
                        .disabled(passcode.count != 6 || confirmation.count != 6)
                }
            }
        }
    }

    private func digits(_ value: String) -> String {
        String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
    }

    private func setPasscode() {
        Task {
            if await coordinator.addPasscode(passcode, confirmation: confirmation) {
                dismiss()
            } else {
                message = coordinator.userMessage
            }
        }
    }
}
