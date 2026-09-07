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
                    QuietIntroduction(
                        title: "Turn Off Passcode",
                        message: "QuietFrame will open without asking for a passcode whenever this iPhone is unlocked. Media remains encrypted with a random key in the iOS Keychain.",
                        systemImage: "lock.open"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, QuietFrameTheme.contentSpacing)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Toggle("I understand anyone using my unlocked iPhone can open the vault", isOn: $understandsRisk)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("Current six-digit passcode", text: $currentPasscode)
                        .keyboardType(.numberPad)
                        .onChange(of: currentPasscode) { _, value in
                            currentPasscode = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        }
                        .frame(minHeight: QuietFrameTheme.controlHeight)
                }

                if let message {
                    Section { AuthenticationErrorMessage(message: message) }
                }

                Section {
                    Button(role: .destructive) { removePasscode() } label: {
                        Text("Turn Off App Passcode")
                            .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(!understandsRisk || currentPasscode.count != 6)
                }
            }
            .listSectionSpacing(QuietFrameTheme.sectionSpacing)
            .quietFormStyle()
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
