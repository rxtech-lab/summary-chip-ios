import SwiftUI

struct NotificationSettingsSheet: View {
    @Bindable private var notifications = SummaryNotifications.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status", value: notifications.isEnabled ? "Enabled" : "Disabled")
                    Button {
                        Task {
                            if notifications.isEnabled { await notifications.disable() }
                            else { await notifications.enable() }
                        }
                    } label: {
                        Label(notifications.isEnabled ? "Disable Notifications" : "Enable Notifications", systemImage: notifications.isEnabled ? "bell.slash" : "bell.badge")
                    }
                    .disabled(notifications.busy)
                } footer: {
                    Text("Receive a notification when a summary is added through the API or CLI. Tap the notification to open the summary. Summary titles may appear on your lock screen.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Notifications")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay {
                if notifications.busy {
                    ProgressView("Updating notifications…")
                        .padding(24)
                        .background(.regularMaterial, in: .rect(cornerRadius: 16))
                } else if let feedback = notifications.feedback {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .padding(20)
                        .background(.regularMaterial, in: .rect(cornerRadius: 16))
                        .allowsHitTesting(false)
                }
            }
            .sensoryFeedback(.success, trigger: notifications.feedback)
            .sensoryFeedback(.error, trigger: notifications.errorMessage)
            .alert("Notifications", isPresented: Binding(get: { notifications.errorMessage != nil }, set: { if !$0 { notifications.errorMessage = nil } })) {
                Button("OK", role: .cancel) { notifications.errorMessage = nil }
            } message: { Text(notifications.errorMessage ?? "") }
            .task { await notifications.refreshStatus() }
            .task(id: notifications.feedback) {
                guard notifications.feedback != nil else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                notifications.clearFeedback()
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 300)
        #endif
    }
}
