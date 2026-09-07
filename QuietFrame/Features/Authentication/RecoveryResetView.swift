import SwiftUI

struct RecoveryResetView: View {
    let coordinator: VaultLockCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledgesLoss = false
    @State private var confirmation = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    QuietIntroduction(
                        title: "Erase Unrecoverable Vault",
                        message: "QuietFrame cannot recover a forgotten passcode or missing encryption key. Erasing lets you set up a new empty vault.",
                        systemImage: "key.slash"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, QuietFrameTheme.contentSpacing)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Toggle("I understand all vault media will be lost", isOn: $acknowledgesLoss)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Type ERASE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .frame(minHeight: QuietFrameTheme.controlHeight)
                }

                Section {
                    Button(role: .destructive) {
                        erase()
                    } label: {
                        Text("Authenticate and Erase Vault")
                            .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(!acknowledgesLoss || confirmation != "ERASE" || coordinator.isWorking)
                } footer: {
                    Text("iOS will require Face ID, Touch ID, or the device passcode. Authentication permits erasure only; it cannot decrypt the vault.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message {
                    Section { AuthenticationErrorMessage(message: message) }
                }
            }
            .listSectionSpacing(QuietFrameTheme.sectionSpacing)
            .quietFormStyle()
            .navigationTitle("Erase Unrecoverable Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func erase() {
        Task {
            let succeeded = await coordinator.resetUnrecoverableApplication()
            if succeeded {
                dismiss()
            } else {
                message = coordinator.userMessage
            }
        }
    }
}
