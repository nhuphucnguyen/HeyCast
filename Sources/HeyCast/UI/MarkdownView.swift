import SwiftUI

/// Minimal markdown renderer for agent responses. Block structure
/// (headings, lists, fenced code, quotes, rules) is parsed here; inline
/// bold/italic/code/links go through AttributedString's markdown parser.
struct MarkdownView: View {
    let text: String
    let theme: Theme

    enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case listItem(marker: String, text: String)
        case code(String)
        case quote(String)
        case rule
    }

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text, size: 14)
        case .heading(let level, let text):
            inline(text, size: level == 1 ? 17 : (level == 2 ? 15 : 14))
                .bold()
                .padding(.top, 2)
        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textColor.alpha(0.55))
                inline(text, size: 14)
            }
        case .code(let code):
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textColor)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.secondaryBackground.alpha(0.6))
                )
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.textColor.alpha(0.25))
                    .frame(width: 3)
                inline(text, size: 14).italic()
            }
        case .rule:
            Divider().overlay(theme.textColor.alpha(0.15))
        }
    }

    /// Renders one line of markdown inline syntax; falls back to plain text
    /// when the input isn't valid markdown.
    private func inline(_ string: String, size: CGFloat) -> some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: string,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
            } else {
                Text(string)
            }
        }
        .font(.system(size: size))
        .foregroundStyle(theme.textColor)
    }

    // MARK: - block parsing

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")

        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // skip the closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            let hashes = trimmed.prefix(while: { $0 == "#" })
            if (1...4).contains(hashes.count),
               trimmed.dropFirst(hashes.count).first == " " {
                flushParagraph()
                blocks.append(.heading(level: hashes.count,
                                       text: trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }
            if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                blocks.append(.listItem(marker: "•",
                                        text: trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }
            // ordered list: "1." / "12." / "3)"
            if trimmed.count <= 4,
               let dotIndex = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }),
               let number = Int(trimmed[..<dotIndex]),
               trimmed.index(after: dotIndex) < trimmed.endIndex {
                flushParagraph()
                let rest = trimmed[trimmed.index(after: dotIndex)...].trimmingCharacters(in: .whitespaces)
                blocks.append(.listItem(marker: "\(number).", text: rest))
                index += 1
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }
}
