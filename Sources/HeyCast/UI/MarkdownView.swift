import SwiftUI
import MarkdownUI

/// Renders agent responses with MarkdownUI (GFM: tables, task lists, code
/// blocks), themed to HeyCast's palette.
struct MarkdownView: View {
    let text: String
    let theme: Theme

    var body: some View {
        Markdown(text)
            .markdownTheme(Theme.heycastMarkdown(theme))
            .textSelection(.enabled)
    }
}

// `Theme` here is HeyCast's palette struct; MarkdownUI also exports a type
// named Theme, so the factory returns MarkdownUI.Theme explicitly.
extension Theme {
    static func heycastMarkdown(_ t: Theme) -> MarkdownUI.Theme {
        MarkdownUI.Theme.basic
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.18))
                    .markdownTextStyle {
                        FontSize(14)
                        ForegroundColor(t.textColor)
                    }
                    .markdownMargin(top: 0, bottom: 8)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(17)
                        ForegroundColor(t.textColor)
                    }
                    .markdownMargin(top: 14, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(15)
                        ForegroundColor(t.textColor)
                    }
                    .markdownMargin(top: 12, bottom: 5)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(14)
                        ForegroundColor(t.textColor)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(14)
                        ForegroundColor(t.textColor.alpha(0.9))
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(12)
                ForegroundColor(t.textColor)
                BackgroundColor(t.textColor.alpha(0.12))
            }
            .link {
                ForegroundColor(Color.accentColor)
            }
            .codeBlock { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12)
                        ForegroundColor(t.textColor)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(t.secondaryBackground.alpha(0.6))
                    )
                    .markdownMargin(top: 4, bottom: 8)
            }
            .blockquote { configuration in
                configuration.label
                    .padding(.leading, 10)
                    .padding(.vertical, 2)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(t.textColor.alpha(0.25))
                            .frame(width: 3)
                    }
                    .markdownTextStyle {
                        FontStyle(.italic)
                        ForegroundColor(t.textColor.alpha(0.85))
                    }
                    .markdownMargin(top: 4, bottom: 8)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
                    .markdownTextStyle {
                        FontSize(14)
                        ForegroundColor(t.textColor)
                    }
            }
    }
}
