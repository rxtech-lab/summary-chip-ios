#if os(iOS)
import SummaryKit
import UIKit

/// The strip above the keyboard while editing LaTeX: completions (with their descriptions) for the
/// word at the caret, or, when there are none, the compile error on the caret's line or a
/// description of the word at the caret, then the characters TeX needs that the iOS keyboard hides
/// a layer down.
final class PaperCompletionBar: UIInputView {
    /// A line of text before the keys.
    struct Info: Equatable {
        let text: String
        let isError: Bool
    }

    static let keys = ["\\", "{", "}", "$", "[", "]", "_", "^", "&", "%", "~"]

    var onPick: ((LaTeXSuggestion) -> Void)?
    var onKey: ((String) -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let feedback = UISelectionFeedbackGenerator()
    private var shown: ([LaTeXSuggestion], Info?)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -10),
        ])
        accessibilityIdentifier = "paper-completion-bar"
        show([], info: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ suggestions: [LaTeXSuggestion], info: Info?) {
        if let shown, shown.0 == suggestions, shown.1 == info { return }
        shown = (suggestions, info)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if suggestions.isEmpty {
            if let info { stack.addArrangedSubview(label(info)) }
            for key in Self.keys {
                stack.addArrangedSubview(button(key, subtitle: nil) { [weak self] in self?.onKey?(key) })
            }
        } else {
            for suggestion in suggestions {
                stack.addArrangedSubview(button(suggestion.label, subtitle: suggestion.detail) { [weak self] in self?.onPick?(suggestion) })
            }
        }
        scroll.setContentOffset(.zero, animated: false)
    }

    private func label(_ info: Info) -> UILabel {
        let label = UILabel()
        label.text = info.isError ? "⚠︎ " + info.text : info.text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = info.isError ? .systemRed : .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func button(_ title: String, subtitle: String?, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.subtitleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
            return attributes
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .caption2)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.feedback.selectionChanged()
            action()
        })
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        button.accessibilityLabel = title
        return button
    }
}
#endif
