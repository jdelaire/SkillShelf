@preconcurrency import MarkdownUI
import SwiftUI

@MainActor
extension Theme {
    static let shelf = Theme.gitHub
        .text {
            ForegroundColor(.primary)
            BackgroundColor(nil)
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            BackgroundColor(Color.primary.opacity(0.07))
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 18, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.45))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 18, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.2))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.05))
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: 12, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    ForegroundColor(.secondary)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.2))
                .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.15))
        }
        .codeBlock { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.15))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.85))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
                .markdownMargin(top: 2, bottom: 10)
        }
        .blockquote { configuration in
            configuration.label
                .markdownTextStyle { ForegroundColor(.secondary) }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                }
                .markdownMargin(top: 0, bottom: 8)
        }
}
