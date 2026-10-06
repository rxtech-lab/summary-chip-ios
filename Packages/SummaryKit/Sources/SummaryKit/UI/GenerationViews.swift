#if os(iOS) || os(macOS)
import SwiftUI

/// Form sections for language, image style, link lifetime and visibility.
/// Embed inside a `Form` / `List`.
public struct GenerationOptionsSections: View {
    @Binding var options: GenerationOptions

    public init(options: Binding<GenerationOptions>) { self._options = options }

    public var body: some View {
        Section {
            Picker(String(localized: "Language", bundle: .module), selection: $options.language) {
                ForEach(SummaryLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif
        } header: {
            Text("Summary", bundle: .module)
        } footer: {
            Text("The language the summary is written in.", bundle: .module)
        }

        Section {
            ForEach(ImageStyle.allCases) { style in
                Button {
                    options.imageStyle = style
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: style.systemImage)
                            .frame(width: 26)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.title).foregroundStyle(.primary)
                            Text(style.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if options.imageStyle == style {
                            Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(options.imageStyle == style ? .isSelected : [])
                .sensoryFeedback(.selection, trigger: options.imageStyle == style) { _, new in new }
            }
        } header: {
            Text("Preview image", bundle: .module)
        }

        SharingOptionsSections(visibility: $options.visibility, ttl: $options.ttl)
    }
}

/// Visibility + TTL controls, shared by creation options and the "Edit sharing" sheet.
public struct SharingOptionsSections: View {
    @Binding var visibility: SummaryVisibility
    @Binding var ttl: TTLOption

    public init(visibility: Binding<SummaryVisibility>, ttl: Binding<TTLOption>) {
        self._visibility = visibility
        self._ttl = ttl
    }

    public var body: some View {
        Section {
            ForEach(SummaryVisibility.allCases) { value in
                Button {
                    visibility = value
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: value.systemImage)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(value.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(value.title).foregroundStyle(.primary)
                            Text(value.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if visibility == value {
                            Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(visibility == value ? .isSelected : [])
                .sensoryFeedback(.selection, trigger: visibility == value) { _, new in new }
            }
        } header: {
            Text("Who can open the link", bundle: .module)
        }

        if visibility == .public {
            Section {
                Picker(selection: $ttl) {
                    ForEach(TTLOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    Label(String(localized: "Expires after", bundle: .module), systemImage: "hourglass")
                }
                #if os(macOS)
                .pickerStyle(.menu)
                #else
                .pickerStyle(.navigationLink)
                #endif
            } header: {
                Text("Link expiry", bundle: .module)
            } footer: {
                Text(ttl == .never
                    ? String(localized: "The link stays open until you make the summary private.", bundle: .module)
                    : String(localized: "The link stops working \(ttl.title) from now. The summary stays in your library, and you can extend the link at any time.", bundle: .module))
            }
        }
    }
}

extension SummaryVisibility {
    var tint: Color { self == .public ? .green : .orange }

    var detail: String {
        switch self {
        case .public: String(localized: "Anyone with the link can view it and its preview.", bundle: .module)
        case .private: String(localized: "Only you. This link stops working, nothing is deleted, and other links you add keep working.", bundle: .module)
        }
    }
}

/// Stage list shown while a summary is being generated.
public struct GenerationProgressView: View {
    let stages: [GenerationStage]
    let current: GenerationStage

    public init(stages: [GenerationStage], current: GenerationStage) {
        self.stages = stages
        self.current = current
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(stages, id: \.self) { stage in
                HStack(spacing: 14) {
                    ZStack {
                        if stage < current {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if stage == current {
                            ProgressView()
                                #if os(macOS)
                                .controlSize(.small)
                                #endif
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    Label(stage.title, systemImage: stage.systemImage)
                        .foregroundStyle(stage <= current ? .primary : .secondary)
                        .fontWeight(stage == current ? .semibold : .regular)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(stage < current ? Text("Done", bundle: .module) : (stage == current ? Text("In progress", bundle: .module) : Text("Pending", bundle: .module)))
            }
            Text("This usually takes under a minute.", bundle: .module)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .animation(.default, value: current)
        .sensoryFeedback(.selection, trigger: current)
    }
}

/// Compact description of what's about to be summarised.
public struct SummaryInputPreview: View {
    let input: SummaryInput

    public init(input: SummaryInput) { self.input = input }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: input.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(input.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        switch input {
        case .url(let url): return url.absoluteString
        case .webpage(let page):
            let words = page.content.split(whereSeparator: \.isWhitespace).count
            let site = page.siteName ?? page.url.host() ?? String(localized: "Web page", bundle: .module)
            return String(localized: "\(site) · \(words) words extracted", bundle: .module)
        case .pdf(let file, _, let sourceURL):
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            return sourceURL.map { String(localized: "PDF · \(sizeText) · \($0.host() ?? "")", bundle: .module) } ?? String(localized: "PDF · \(sizeText)", bundle: .module)
        case .text(let text, _):
            return String(localized: "\(text.count) characters of text", bundle: .module)
        case .localFile(let file):
            return String(localized: "\(file.typeLabel) · \(file.text.count) characters read on this device", bundle: .module)
        }
    }
}
#endif
