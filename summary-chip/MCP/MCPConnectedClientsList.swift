import SummaryKit
import SwiftUI

struct MCPConnectedClientsList: View {
    let clients: [MCPConnectedClient]
    let onSelect: (MCPConnectedClient) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Authorized Apps").font(.headline)
                        Spacer()
                        Text("\(clients.count) authorizations")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Review what each app can access. Select an app to manage its authorization.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                LazyVStack(spacing: 12) {
                    ForEach(clients) { client in
                        Button { onSelect(client) } label: {
                            MCPConnectedClientRow(client: client)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mcp-connected-client")
                    }
                }

                Label {
                    Text("Each OAuth authorization is shown separately. These are permissions, not online sessions. Manage API-key clients under API Keys.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.primary.opacity(0.025))
    }
}

private struct MCPConnectedClientRow: View {
    let client: MCPConnectedClient

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(verbatim: String(client.name.prefix(1)).uppercased())
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 46)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(client.name)
                    .font(.headline).foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(permissions)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                Text("Expires \(client.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 5)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Review permissions and disconnect this authorization")
    }

    private var permissions: LocalizedStringKey {
        let scopes = Set(client.scope.split(separator: " "))
        guard scopes.isSubset(of: ["chippy:read", "chippy:write"]), !scopes.isEmpty else {
            return "Custom permissions"
        }
        if scopes.contains("chippy:read") && scopes.contains("chippy:write") { return "Read and write" }
        return scopes.contains("chippy:write") ? "Write access" : "Read only"
    }
}
