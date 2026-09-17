import SwiftUI
import AppKit

/// Assistant inbox: requests you've fired off and the responses that landed
/// while the launcher was hidden. Type a question and press Enter to ask the
/// default agent; pick a row to read (marks it viewed).
struct AssistantPageView: View {
    @ObservedObject var model: LauncherModel

    private var messages: [AssistantMessage] { model.assistantMessages }

    private var selected: AssistantMessage? {
        if let id = model.selectedAssistantID,
           let match = messages.first(where: { $0.id == id }) {
            return match
        }
        return messages.indices.contains(model.selectedIndex) ? messages[model.selectedIndex] : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                if messages.isEmpty {
                    Text("Ask an agent — type a question and press Enter.\nConfigure agents in Settings → Assistant.")
                        .font(.system(size: 13))
                        .foregroundStyle(model.theme.textColor.alpha(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                    AssistantRow(model: model, message: message,
                                                 isSelected: index == model.selectedIndex)
                                        .id(message.id)
                                        .onTapGesture {
                                            model.selectedIndex = index
                                            model.openAssistantMessage(message)
                                        }
                                }
                            }
                        }
                        .onChange(of: model.selectedIndex) { newIndex in
                            guard messages.indices.contains(newIndex) else { return }
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(messages[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(width: 250)

            Divider()
                .overlay(model.theme.textColor.alpha(0.15))

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(height: 330)
    }

    @ViewBuilder
    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("You · \(message.agent)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(model.theme.textColor.alpha(0.5))
                        Text(message.request)
                            .font(.system(size: 13))
                            .foregroundStyle(model.theme.textColor.alpha(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider().overlay(model.theme.textColor.alpha(0.15))

                        switch message.status {
                        case .pending:
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.6)
                                Text("Waiting for \(message.agent)…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(model.theme.textColor.alpha(0.5))
                            }
                        case .failed:
                            Text(message.error ?? "Request failed")
                                .font(.system(size: 13))
                                .foregroundStyle(.red.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .done:
                            MarkdownView(text: message.response ?? "", theme: model.theme)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                }
                HStack {
                    if message.status == .done,
                       let response = message.response, !response.isEmpty {
                        Button {
                            ClipboardService.copy(text: response)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy response")
                    }
                    if message.status == .failed {
                        Button {
                            model.retryAssistantMessage(message)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Retry")
                    }
                    Button {
                        model.deleteAssistantMessage(message)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                    Spacer()
                    if message.isUnread {
                        Text("new")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(model.theme.textColor.alpha(0.5))
                    }
                }
            } else {
                Spacer()
            }
        }
        .padding(.leading, 10)
    }
}

private struct AssistantRow: View {
    @ObservedObject var model: LauncherModel
    let message: AssistantMessage
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 12))
                .foregroundStyle(model.theme.textColor.alpha(0.8))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.request)
                    .font(.system(size: 13))
                    .foregroundStyle(model.theme.textColor)
                    .lineLimit(1)
                Text(message.agent)
                    .font(.system(size: 10))
                    .foregroundStyle(model.theme.textColor.alpha(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if message.isUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? model.theme.focusedRow : model.theme.unfocusedRow.alpha(0.001))
        )
    }

    private var statusIcon: String {
        switch message.status {
        case .pending: return "clock"
        case .failed: return "exclamationmark.triangle"
        case .done: return "sparkles"
        }
    }
}
