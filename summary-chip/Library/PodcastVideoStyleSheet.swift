import SummaryKit
import SwiftUI

extension PodcastVideoStyle {
    var title: String {
        switch self {
        case .news: String(localized: "News")
        case .crayon: String(localized: "Crayon")
        }
    }

    var detail: String {
        switch self {
        case .news: String(localized: "A calm editorial TV explainer with clean ivory-and-teal line art.")
        case .crayon: String(localized: "Hand-drawn crayon doodles on drawing paper, sketched in as the hosts speak.")
        }
    }

    var symbol: String {
        switch self {
        case .news: "tv"
        case .crayon: "pencil.and.scribble"
        }
    }

    /// The style's palette, as a preview swatch.
    var swatch: [Color] {
        switch self {
        case .news: [Color(red: 0.97, green: 0.98, blue: 0.97), Color(red: 0, green: 0.61, blue: 0.52), Color(red: 0.13, green: 0.23, blue: 0.21), Color(red: 0.86, green: 0.92, blue: 0.89)]
        case .crayon: [Color(red: 0.98, green: 0.96, blue: 0.9), Color(red: 0.89, green: 0.34, blue: 0.18), Color(red: 0.23, green: 0.53, blue: 0.78), Color(red: 0.95, green: 0.71, blue: 0.21), Color(red: 0.31, green: 0.63, blue: 0.35)]
        }
    }
}

/// Chooses the art direction the server designs the video in.
struct PodcastVideoStyleSheet: View {
    @Binding var style: PodcastVideoStyle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(PodcastVideoStyle.allCases) { option in
                        Button {
                            style = option
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.symbol)
                                    .font(.title3)
                                    .frame(width: 32)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(option.title).font(.headline)
                                    Text(option.detail).font(.subheadline).foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        ForEach(option.swatch.indices, id: \.self) { index in
                                            Circle().fill(option.swatch[index])
                                                .overlay { Circle().strokeBorder(.secondary.opacity(0.3)) }
                                                .frame(width: 14, height: 14)
                                        }
                                    }
                                    .accessibilityHidden(true)
                                }
                                Spacer(minLength: 8)
                                if option == style {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option == style ? .isSelected : [])
                        .accessibilityIdentifier("podcast-video-style-\(option.rawValue)")
                    }
                } footer: {
                    Text("The video is designed in this style. Your choice is saved on this device when you generate.")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Video Style")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sensoryFeedback(.selection, trigger: style)
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
}
