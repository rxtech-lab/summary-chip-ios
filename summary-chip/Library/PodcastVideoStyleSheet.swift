import SummaryKit
import SwiftUI

/// Chooses the art direction the server designs the video in, from the styles the server offers.
struct PodcastVideoStyleSheet: View {
    let styles: [PodcastGenerationOptions.VideoStyle]
    @Binding var style: PodcastVideoStyle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(styles) { option in
                        Button {
                            style = option.id
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.symbol)
                                    .font(.title3)
                                    .frame(width: 32)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(option.title).font(.headline)
                                    Text(option.description).font(.subheadline).foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        ForEach(option.swatch.indices, id: \.self) { index in
                                            Circle().fill(Color(hex: option.swatch[index]))
                                                .overlay { Circle().strokeBorder(.secondary.opacity(0.3)) }
                                                .frame(width: 14, height: 14)
                                        }
                                    }
                                    .accessibilityHidden(true)
                                }
                                Spacer(minLength: 8)
                                if option.id == style {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option.id == style ? .isSelected : [])
                        .accessibilityIdentifier("podcast-video-style-\(option.id.rawValue)")
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

/// Dedicated host configuration; the generation sheet persists it when generation starts.
struct PodcastSpeakersSheet: View {
    @Binding var names: [String]
    let limits: PodcastGenerationOptions.Speakers?
    @Environment(\.dismiss) private var dismiss
    private var maxCount: Int { limits?.maxCount ?? 0 }
    private var maxNameLength: Int { limits?.maxNameLength ?? 40 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Speakers", selection: Binding(get: { names.count }, set: { count in
                        names = (0..<count).map { $0 < names.count ? names[$0] : "" }
                    })) {
                        Text("Automatic").tag(0)
                        ForEach(0..<maxCount, id: \.self) { Text("\($0 + 1)").tag($0 + 1) }
                    }
                    ForEach(names.indices, id: \.self) { index in
                        TextField("Speaker \(index + 1)", text: $names[index])
                            .accessibilityIdentifier("podcast-speaker-name-\(index)")
                    }
                } footer: {
                    Text("Choose Automatic to let the podcast choose its hosts, or enter a name for each speaker (up to \(maxNameLength) characters). Up to \(maxCount) speakers are available. These settings are saved on this device when you generate.")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Speakers")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(names.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.utf16.count > maxNameLength })
                }
            }
            .sensoryFeedback(.selection, trigger: names.count)
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
}

/// Presets and custom timing share one dedicated, full-height configuration sheet.
struct PodcastDurationSheet: View {
    let options: PodcastGenerationOptions.DurationOptions
    @Binding var seconds: Int
    @Environment(\.dismiss) private var dismiss
    @State private var custom = false
    @State private var draft = 360

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(options.presets) { preset in
                        Button {
                            seconds = preset.seconds
                            dismiss()
                        } label: {
                            HStack {
                                Text(preset.title)
                                Spacer()
                                Text(Self.time(preset.seconds)).monospacedDigit().foregroundStyle(.secondary)
                                if seconds == preset.seconds {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("podcast-duration-\(preset.seconds)")
                    }
                    Toggle("Custom duration", isOn: $custom)
                        .accessibilityIdentifier("podcast-duration-custom")
                }
                if custom {
                    Section {
                        Stepper(value: $draft, in: options.minSeconds...options.maxSeconds) {
                            HStack {
                                Text("Duration")
                                Spacer()
                                Text(Self.time(draft)).monospacedDigit()
                            }
                        }
                        HStack {
                            Text("Minutes")
                            Picker("Minutes", selection: Binding(get: { draft / 60 }, set: { draft = $0 * 60 + draft % 60 })) {
                                ForEach(0...(options.maxSeconds / 60), id: \.self) { Text("\($0)").tag($0) }
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("podcast-duration-minutes")
                        }
                        HStack {
                            Text("Seconds")
                            Picker("Seconds", selection: Binding(get: { draft % 60 }, set: { draft = draft / 60 * 60 + $0 })) {
                                ForEach(0..<60, id: \.self) { Text("\($0)").tag($0) }
                            }
                            .labelsHidden()
                        }
                    } footer: {
                        Text("Choose from \(Self.time(options.minSeconds)) to \(Self.time(options.maxSeconds)).")
                    }
                }
                Section {
                    Text("This is a duration target. The finished audio and video may be shorter depending on the source material. Changing an existing video's length requires regenerating the podcast.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Length")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        seconds = draft
                        dismiss()
                    }
                    .disabled(!custom || !(options.minSeconds...options.maxSeconds).contains(draft))
                }
            }
            .onAppear {
                draft = seconds
                custom = !options.presets.contains { $0.seconds == seconds }
            }
            .sensoryFeedback(.selection, trigger: seconds)
            .sensoryFeedback(.selection, trigger: draft)
            .sensoryFeedback(.selection, trigger: custom)
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    static func time(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
