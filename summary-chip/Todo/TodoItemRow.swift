import RichDocumentEditor
import SummaryKit
import SwiftUI

struct TodoCheckButton: View {
    let item: TodoItem
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(item.completed ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: item.completed)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.completed ? "Mark \(item.title) incomplete" : "Complete \(item.title)")
    }
}

/// Bridges the row's focus enum to the composer's Bool.
private func focusBinding(_ focus: Binding<TodoFocus?>, _ target: TodoFocus) -> Binding<Bool> {
    Binding {
        focus.wrappedValue == target
    } set: { focused in
        if focused { focus.wrappedValue = target } else if focus.wrappedValue == target { focus.wrappedValue = nil }
    }
}

/// Owners can edit an item title in place and open its details.
struct TodoItemRow: View {
    @Binding var item: TodoItem
    let editable: Bool
    let listDeadline: Date
    @Binding var focus: TodoFocus?
    let pending: [TodoAttachmentUploads.Pending]
    let onToggle: () -> Void
    let onReturn: () -> Void
    let onChange: () -> Void
    let onAttach: ([PastedAttachment]) -> Void
    let onPasteError: (String) -> Void
    let onLoadingAttachments: (Bool) -> Void
    let onDetails: () -> Void
    @ScaledMetric(relativeTo: .body) private var lineHeight = 22
    private var isFocused: Bool { focus == .item(item.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TodoCheckButton(item: item, action: onToggle)
                .disabled(!editable)
                .frame(height: lineHeight)
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if editable && (!item.completed || isFocused) {
                        ComposerTextView("Title", text: $item.title, isFocused: focusBinding($focus, .item(item.id)),
                                         onSubmit: onReturn, onPasteAttachments: onAttach, onPasteError: onPasteError,
                                         onLoadingAttachments: onLoadingAttachments)
                    } else if editable {
                        Button { focus = .item(item.id) } label: { Text(item.title) }.buttonStyle(.plain)
                    } else {
                        Text(item.title)
                    }
                }
                .strikethrough(item.completed && !isFocused)
                .foregroundStyle(item.completed && !isFocused ? .secondary : .primary)
                TodoAttachmentStrip(attachments: item.attachments, pending: pending,
                                    canRemove: editable && isFocused) { attachment in
                    item.attachments.removeAll { $0.id == attachment.id }
                    onChange()
                }
                if isFocused {
                    TodoDeadlineMenu(deadline: $item.deadline, listDeadline: listDeadline, completed: item.completed,
                                     onChange: onChange, onCustom: onDetails)
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    Label { Text(item.deadline, format: .dateTime.month().day().hour().minute()) }
                        icon: { Image(systemName: item.deadline < .now && !item.completed ? "exclamationmark.circle" : "calendar") }
                        .font(.caption)
                        .foregroundStyle(todoDeadlineColor(item.deadline, completed: item.completed))
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if editable && isFocused {
                Button("Details", systemImage: "info.circle", action: onDetails)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                    .frame(height: lineHeight)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 4)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: isFocused)
        .animation(.snappy, value: item.completed)
    }
}

/// The trailing "New Item" composer. Return adds the item and keeps the cursor here for the next one.
struct TodoNewItemRow: View {
    @Binding var item: TodoItem
    let listDeadline: Date
    @Binding var focus: TodoFocus?
    let pending: [TodoAttachmentUploads.Pending]
    let onReturn: () -> Void
    let onPasteLines: ([String]) -> Void
    let onAttach: ([PastedAttachment]) -> Void
    let onPasteError: (String) -> Void
    let onLoadingAttachments: (Bool) -> Void
    let onDetails: () -> Void
    @ScaledMetric(relativeTo: .body) private var lineHeight = 22
    private var isFocused: Bool { focus == .newItem }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isFocused ? "circle" : "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(isFocused ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: lineHeight)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                ComposerTextView("New Item", text: $item.title, isFocused: focusBinding($focus, .newItem),
                                 accessibilityIdentifier: "todo-new-item", onSubmit: onReturn, onPasteAttachments: onAttach,
                                 onPasteError: onPasteError, onPasteLines: item.attachments.isEmpty && pending.isEmpty ? onPasteLines : nil,
                                 onLoadingAttachments: onLoadingAttachments)
                TodoAttachmentStrip(attachments: item.attachments, pending: pending, canRemove: true) { attachment in
                    item.attachments.removeAll { $0.id == attachment.id }
                }
                if isFocused {
                    VStack(alignment: .leading, spacing: 8) {
                        TodoDeadlineMenu(deadline: $item.deadline, listDeadline: listDeadline, onChange: {}, onCustom: onDetails)
                        Text("Return to add · Shift-Return for a new line · Paste images or files")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isFocused {
                Button("Details", systemImage: "info.circle", action: onDetails)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                    .frame(height: lineHeight)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, isFocused ? 10 : 4)
        .padding(.horizontal, isFocused ? 10 : 0)
        .background {
                if isFocused {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.fill.quinary)
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.tint.opacity(0.35), lineWidth: 1) }
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focus = .newItem }
        .animation(.spring(duration: 0.4, bounce: 0.25), value: isFocused)
    }
}
