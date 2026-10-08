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
                        title: "Erase unrecoverable vault",
                        message: "QuietFrame cannot recover a forgotten passcode or missing encryption key. Erasing lets you set up a new empty vault.",
                        systemImage: "key.slash"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, QuietFrameTheme.contentSpacing)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Toggle("I understand all vault media will be lost", isOn: $acknowledgesLoss)
                        .foregroundStyle(QuietFrameTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Type ERASE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .foregroundStyle(QuietFrameTheme.ink)
                        .frame(minHeight: QuietFrameTheme.controlHeight)
                }
                .quietRows()

                Section {
                    Button(role: .destructive) {
                        erase()
                    } label: {
                        Text("Authenticate and erase vault")
                            .fontWeight(.semibold)
                            .foregroundStyle(isEraseDisabled ? QuietFrameTheme.quietInk : QuietFrameTheme.destructive)
                            .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(isEraseDisabled)
                } footer: {
                    Text("iOS will require Face ID, Touch ID, or the device passcode. Authentication permits erasure only; it cannot decrypt the vault.")
                        .foregroundStyle(QuietFrameTheme.quietInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .quietRows()

                if let message {
                    Section { AuthenticationErrorMessage(message: message) }
                        .quietRows()
                }
            }
            .listSectionSpacing(QuietFrameTheme.sectionSpacing)
            .quietFormStyle()
            .navigationTitle("Erase unrecoverable vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationBackground(QuietFrameTheme.elevated)
        .presentationCornerRadius(QuietFrameTheme.sheetCornerRadius)
    }

    private var isEraseDisabled: Bool {
        !acknowledgesLoss || confirmation != "ERASE" || coordinator.isWorking
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
