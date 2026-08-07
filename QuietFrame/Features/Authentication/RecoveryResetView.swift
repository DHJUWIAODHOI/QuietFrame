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
                    Text("QuietFrame cannot recover a forgotten passcode or missing encryption key. Erasing lets you set up a new empty vault.")
                        .foregroundStyle(.secondary)
                    Toggle("I understand all vault media will be lost", isOn: $acknowledgesLoss)
                    TextField("Type ERASE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section {
                    Button("Authenticate and Erase Vault", role: .destructive) {
                        erase()
                    }
                    .disabled(!acknowledgesLoss || confirmation != "ERASE" || coordinator.isWorking)
                } footer: {
                    Text("iOS will require Face ID, Touch ID, or the device passcode. Authentication permits erasure only; it cannot decrypt the vault.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
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
