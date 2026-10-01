import SummaryKit
import SwiftUI

/// Welcome and unread features advance in one sheet, with acknowledgement saved per step.
struct EducationSheet: View {
    let pages: [EducationPage]
    var allowsDismissal = false
    var onAcknowledged: (EducationPage) -> Void = { _ in }
    var onFinished: () -> Void
    @State private var index = 0

    private var current: EducationPage? { pages.indices.contains(index) ? pages[index] : nil }
    private var isLast: Bool { index == pages.count - 1 }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iOSBody
        #endif
    }

    private func advance() {
        guard let current else { onFinished(); return }
        onAcknowledged(current)
        if isLast {
            onFinished()
        } else {
            withAnimation(Self.pageAnimation) { index += 1 }
        }
    }

    // Swiping from the final welcome page also completes the tour. Feature
    // cards still require their own explicit acknowledgement.
    private func acknowledgeSwipe(from old: Int, to new: Int) {
        if pages.indices.contains(old), pages.indices.contains(new),
           pages[old].kind == .welcome, pages[new].kind == .feature {
            onAcknowledged(pages[old])
        }
    }

    private static let pageAnimation = Animation.spring(response: 0.55, dampingFraction: 0.86)

    private var nextTitle: String {
        isLast ? (current?.kind == .feature ? "Got it" : "Get started") : "Next"
    }

    #if !os(macOS)
    private var iOSBody: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TabView(selection: $index) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { offset, page in
                        pageContent(page)
                            .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: index) { old, new in acknowledgeSwipe(from: old, to: new) }

                VStack(spacing: 16) {
                    if pages.count > 1 {
                        HStack(spacing: 8) {
                            ForEach(pages.indices, id: \.self) { offset in
                                Circle()
                                    .fill(offset == index ? Color.indigo : Color.secondary.opacity(0.25))
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Page \(index + 1) of \(pages.count)")
                    }
                    Button(action: advance) {
                        Label(nextTitle, systemImage: isLast ? "checkmark" : "arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("education-next")
                }
                .controlSize(.large)
                .frame(maxWidth: 500)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .background(Color.summaryGroupedBackground)
            .navigationTitle(current?.kind == .feature ? "What’s new" : "Welcome to Chippy")
            .summaryInlineNavigationTitle()
            .toolbar {
                if allowsDismissal {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", action: onFinished)
                    }
                }
            }
        }
        .tint(.indigo)
        .interactiveDismissDisabled(!allowsDismissal)
        .presentationDragIndicator(allowsDismissal ? .visible : .hidden)
        .presentationDetents([.large])
        .accessibilityIdentifier("education-sheet")
    }
    #endif

    #if os(macOS)
    /// Desktop pages sit in a paging scroll view so trackpad swipes, Next, Back and the page dots
    /// all share one spring-driven horizontal motion.
    private var macBody: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(pages.indices, id: \.self) { offset in
                        macPage(pages[offset])
                            .containerRelativeFrame(.horizontal)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .opacity(1 - abs(phase.value) * 0.7)
                                    .scaleEffect(1 - abs(phase.value) * 0.08)
                                    .blur(radius: abs(phase.value) * 6)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.never)
            .scrollPosition(id: Binding(get: { index }, set: { if let new = $0 { index = new } }))
            .onChange(of: index) { old, new in acknowledgeSwipe(from: old, to: new) }

            macControls
        }
        .frame(width: 660, height: 640)
        .background {
            ZStack(alignment: .top) {
                Color.summaryGroupedBackground
                LinearGradient(colors: [Color.indigo.opacity(0.16), .clear],
                               startPoint: .top, endPoint: .center)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            if allowsDismissal {
                Button(action: onFinished) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close")
                .padding(16)
            }
        }
        .tint(.indigo)
        .interactiveDismissDisabled(!allowsDismissal)
        .accessibilityIdentifier("education-sheet")
    }

    private func macPage(_ page: EducationPage) -> some View {
        VStack(spacing: 0) {
            Image(page.imageName)
                .resizable()
                .scaledToFit()
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .indigo.opacity(0.18), radius: 24, y: 12)
                // Artwork drifts slower than the page for a light parallax while swiping.
                .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                    content.offset(x: phase.value * -90)
                }
                .accessibilityHidden(true)
                .padding(.top, 48)

            Text(page.kind == .feature ? "NEW" : "WELCOME")
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.indigo)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.indigo.opacity(0.12), in: Capsule())
                .padding(.top, 32)

            Text(page.title)
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 12)

            Text(page.message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(page.id)
    }

    private var macControls: some View {
        HStack {
            Button {
                withAnimation(Self.pageAnimation) { index -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Back")
            .accessibilityLabel("Back")
            .opacity(index > 0 ? 1 : 0)
            .disabled(index == 0)

            Spacer()

            Button(action: advance) {
                HStack(spacing: 8) {
                    Text(nextTitle)
                        .contentTransition(.opacity)
                    Image(systemName: isLast ? "checkmark" : "arrow.right")
                        .contentTransition(.symbolEffect(.replace))
                }
                .font(.title3.weight(.semibold))
                .frame(minWidth: 180, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("education-next")
        }
        .controlSize(.extraLarge)
        .overlay { if pages.count > 1 { macPageIndicator } }
        .animation(Self.pageAnimation, value: index)
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 28)
    }

    private var macPageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { offset in
                Button {
                    withAnimation(Self.pageAnimation) { index = offset }
                } label: {
                    Capsule()
                        .fill(offset == index ? Color.indigo : Color.secondary.opacity(0.3))
                        .frame(width: offset == index ? 22 : 8, height: 8)
                        .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(index + 1) of \(pages.count)")
    }
    #endif

    #if !os(macOS)
    private func pageContent(_ page: EducationPage) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Image(page.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(height: min(280, max(140, geometry.size.height * 0.5)))
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .accessibilityHidden(true)
                    Text(page.title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(page.message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .accessibilityIdentifier(page.id)
    }
    #endif
}

#Preview("Welcome") {
    EducationSheet(pages: EducationPage.welcome, onFinished: {})
}

#Preview("What’s new") {
    EducationSheet(pages: EducationPage.features, onFinished: {})
}
