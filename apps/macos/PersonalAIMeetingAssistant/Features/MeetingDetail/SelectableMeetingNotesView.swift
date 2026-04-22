import SwiftUI
import AppKit

class AutoSizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let manager = layoutManager, let container = textContainer else {
            return super.intrinsicContentSize
        }
        manager.ensureLayout(for: container)
        let rect = manager.usedRect(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: rect.height + textContainerInset.height * 2)
    }
    
    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }
}

/// Renders meeting summary markdown in a native NSTextView.
struct SelectableMeetingNotesView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> AutoSizingTextView {
        let textView = AutoSizingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        return textView
    }

    func updateNSView(_ textView: AutoSizingTextView, context: Context) {
        textView.textStorage?.setAttributedString(buildAttributedString(markdown))
        textView.invalidateIntrinsicContentSize()
    }

    // MARK: - Attributed string builder

    private func buildAttributedString(_ raw: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = raw.components(separatedBy: "\n")
        var firstBlock = true

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { continue }

            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 6

            let (text, attrs): (String, [NSAttributedString.Key: Any])

            if trimmed.hasPrefix("# ") {
                para.paragraphSpacingBefore = firstBlock ? 0 : 20
                para.paragraphSpacing = 8
                text = String(trimmed.dropFirst(2))
                attrs = [
                    .font: NSFont.systemFont(ofSize: 19, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: para,
                ]
            } else if trimmed.hasPrefix("## ") {
                para.paragraphSpacingBefore = firstBlock ? 0 : 16
                para.paragraphSpacing = 6
                text = String(trimmed.dropFirst(3))
                attrs = [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: para,
                ]
            } else if trimmed.hasPrefix("### ") {
                para.paragraphSpacingBefore = firstBlock ? 0 : 12
                text = String(trimmed.dropFirst(4))
                attrs = [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: para,
                ]
            } else if trimmed == "---" || trimmed == "***" {
                // Horizontal rule — render as a thin line via spacing
                para.paragraphSpacingBefore = 8
                para.paragraphSpacing = 8
                text = " "
                let rulerAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 2),
                    .foregroundColor: NSColor.separatorColor,
                    .paragraphStyle: para,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.separatorColor,
                ]
                if !firstBlock { result.append(NSAttributedString(string: "\n")) }
                result.append(NSAttributedString(string: "  \n", attributes: rulerAttrs))
                continue
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let content = String(trimmed.dropFirst(2))
                para.paragraphSpacingBefore = 1
                para.paragraphSpacing = 2
                para.headIndent = 14
                para.firstLineHeadIndent = 0
                text = "• " + content
                attrs = [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: para,
                ]
            } else {
                para.paragraphSpacingBefore = firstBlock ? 0 : 4
                text = trimmed
                attrs = [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: para,
                ]
            }

            if !firstBlock { result.append(NSAttributedString(string: "\n")) }
            result.append(renderInline(text, baseAttrs: attrs))
            firstBlock = false
        }

        return result
    }

    /// Handles **bold** and *italic* inline markers.
    private func renderInline(_ text: String, baseAttrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = (baseAttrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 13)
        var remaining = text

        while !remaining.isEmpty {
            // **bold**
            if let r1 = remaining.range(of: "**"),
               let r2 = remaining.range(of: "**", range: r1.upperBound..<remaining.endIndex) {
                let before = String(remaining[remaining.startIndex..<r1.lowerBound])
                let bold   = String(remaining[r1.upperBound..<r2.lowerBound])
                if !before.isEmpty {
                    result.append(NSAttributedString(string: before, attributes: baseAttrs))
                }
                var boldAttrs = baseAttrs
                boldAttrs[.font] = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
                result.append(NSAttributedString(string: bold, attributes: boldAttrs))
                remaining = String(remaining[r2.upperBound...])
                continue
            }
            // *italic*
            if let r1 = remaining.range(of: "*"),
               let r2 = remaining.range(of: "*", range: r1.upperBound..<remaining.endIndex) {
                let before  = String(remaining[remaining.startIndex..<r1.lowerBound])
                let italic  = String(remaining[r1.upperBound..<r2.lowerBound])
                if !before.isEmpty {
                    result.append(NSAttributedString(string: before, attributes: baseAttrs))
                }
                var italicAttrs = baseAttrs
                let italicDesc = baseFont.fontDescriptor.withSymbolicTraits(.italic)
                italicAttrs[.font] = NSFont(descriptor: italicDesc, size: baseFont.pointSize) ?? baseFont
                result.append(NSAttributedString(string: italic, attributes: italicAttrs))
                remaining = String(remaining[r2.upperBound...])
                continue
            }
            result.append(NSAttributedString(string: remaining, attributes: baseAttrs))
            break
        }
        return result
    }
}
