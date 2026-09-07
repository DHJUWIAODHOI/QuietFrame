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
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Type RESET", text: $confirmationText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .frame(minHeight: QuietFrameTheme.controlHeight)
                    SecureField("Current six-digit passcode", text: $passcode)
                        .keyboardType(.numberPad)
                        .onChange(of: passcode) { _, value in
                            passcode = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        }
                        .frame(minHeight: QuietFrameTheme.controlHeight)
                } footer: {
                    Text("QuietFrame authenticates first, deletes the Keychain master-key envelope, then removes encrypted files.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message {
                    Section { AuthenticationErrorMessage(message: message) }
                }

                Section {
                    Button(role: .destructive) { reset() } label: {
                        Text("Permanently Reset QuietFrame")
                            .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(!canReset || coordinator.isWorking)
                    .accessibilityIdentifier("confirm-reset")
                }
            }
            .labelStyle(QuietSettingsLabelStyle())
            .listSectionSpacing(QuietFrameTheme.sectionSpacing)
            .quietFormStyle()
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
