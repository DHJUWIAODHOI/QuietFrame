import SwiftData
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRecords: [AppSettings]

    @State private var showsChangePasscode = false
    @State private var confirmsReset = false
    @State private var showsReset = false
    @State private var userMessage: String?

    private var settings: AppSettings? { settingsRecords.first }

    var body: some View {
        List {
            securitySection
            behaviorSection
            appearanceSection
            storageSection
            privacySection
            destructiveSection
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showsChangePasscode) {
            ChangePasscodeView(coordinator: dependencies.lockCoordinator)
        }
        .sheet(isPresented: $showsReset) {
            ResetApplicationView(coordinator: dependencies.lockCoordinator)
                .interactiveDismissDisabled(dependencies.lockCoordinator.isWorking)
        }
        .confirmationDialog(
            "Reset QuietFrame?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Continue to Reset", role: .destructive) { showsReset = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reset permanently deletes all encrypted media, albums, settings, and encryption keys. You will confirm again and enter your passcode.")
        }
        .alert("QuietFrame", isPresented: messageIsPresented) {
            Button("OK", role: .cancel) { userMessage = nil }
        } message: {
            Text(userMessage ?? "The setting could not be saved.")
        }
    }

    private var securitySection: some View {
        Section("Security") {
            Toggle(isOn: biometricsBinding) {
                Label(dependencies.lockCoordinator.biometricKind.title, systemImage: biometricSymbol)
            }
            .disabled(dependencies.lockCoordinator.biometricKind == .none)
            .accessibilityHint("Uses biometrics currently enrolled on this device")

            Button {
                showsChangePasscode = true
            } label: {
                Label("Change Passcode", systemImage: "ellipsis.rectangle")
            }

            Button {
                Task { await dependencies.lockCoordinator.lock() }
            } label: {
                Label("Lock QuietFrame Now", systemImage: "lock.fill")
            }
            .accessibilityIdentifier("lock-now")
        }
    }

    private var behaviorSection: some View {
        Section {
            Picker(selection: autoLockBinding) {
                ForEach(AutoLockPeriod.allCases) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                Label("Auto-Lock", systemImage: "lock.rotation")
            }

            Picker(selection: trashRetentionBinding) {
                ForEach(TrashRetentionPeriod.allCases) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                Label("Trash Retention", systemImage: "trash.circle")
            }
        } header: {
            Text("Lock and Recovery")
        } footer: {
            Text("QuietFrame is covered immediately in the app switcher. Auto-lock controls how long an unlocked session may remain during a brief background transition.")
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: appearanceBinding) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            } label: {
                Label("Theme", systemImage: "circle.lefthalf.filled")
            }

            Picker(selection: thumbnailBinding) {
                ForEach(ThumbnailSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            } label: {
                Label("Thumbnail Size", systemImage: "square.grid.3x3")
            }
        }
    }

    private var storageSection: some View {
        Section("Vault") {
            NavigationLink {
                StorageManagementView(service: dependencies.storageAnalysisService)
            } label: {
                Label("Storage Usage", systemImage: "internaldrive")
            }

            NavigationLink {
                ExportOptionsView()
            } label: {
                Label("Export Behavior", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            NavigationLink {
                PrivacyInformationView()
            } label: {
                Label("How QuietFrame Protects You", systemImage: "hand.raised.fill")
            }

            LabeledContent("Analytics and Tracking", value: "Off")
            LabeledContent("Cloud Sync", value: "Not Used")
        }
    }

    private var destructiveSection: some View {
        Section {
            Button("Reset QuietFrame", systemImage: "exclamationmark.arrow.triangle.2.circlepath", role: .destructive) {
                confirmsReset = true
            }
            .accessibilityHint("Permanently deletes encrypted media and keys after additional confirmations")
        }
    }

    private var biometricSymbol: String {
        dependencies.lockCoordinator.biometricKind == .touchID ? "touchid" : "faceid"
    }

    private var biometricsBinding: Binding<Bool> {
        Binding(
            get: { settings?.biometricsEnabled ?? false },
            set: { enabled in
                Task {
                    let succeeded = await dependencies.lockCoordinator.setBiometricsEnabled(enabled)
                    if !succeeded {
                        userMessage = dependencies.lockCoordinator.userMessage
                    }
                }
            }
        )
    }

    private var autoLockBinding: Binding<AutoLockPeriod> {
        Binding(
            get: { settings?.autoLockPeriod ?? .immediately },
            set: { value in updateSettings { $0.autoLockPeriod = value } }
        )
    }

    private var trashRetentionBinding: Binding<TrashRetentionPeriod> {
        Binding(
            get: { settings?.trashRetentionPeriod ?? .thirtyDays },
            set: { value in updateSettings { $0.trashRetentionPeriod = value } }
        )
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { settings?.appearance ?? .system },
            set: { value in updateSettings { $0.appearance = value } }
        )
    }

    private var thumbnailBinding: Binding<ThumbnailSize> {
        Binding(
            get: { settings?.thumbnailSize ?? .comfortable },
            set: { value in updateSettings { $0.thumbnailSize = value } }
        )
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(get: { userMessage != nil }, set: { if !$0 { userMessage = nil } })
    }

    private func updateSettings(_ update: (AppSettings) -> Void) {
        guard let settings else { return }
        update(settings)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            userMessage = VaultError.persistenceFailure.localizedDescription
        }
    }
}
