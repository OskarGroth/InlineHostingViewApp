//
//  InlineHostView.swift
//  InlineHostViewApp
//
//  Created by Stephan Casas on 4/30/23.
//

import AppKit;
import SwiftUI;
import Combine;


// MARK: - Custom SwiftUI NSViewRepresentable with NSTextField and NSHostingView
struct InlineHostingView: NSViewRepresentable {
    
    private var displayString: String;
    private var contentAnchors: [Int] = [];
    
    let contentViews: [() -> AnyView];
    
    init(
        _ usingString: String,
        replaceText: String = "{{ content }}",
        _ withContent: () -> any View...
    ) {
        self.displayString = usingString;
        
        for anchor in self.displayString.ranges(of: replaceText) {
            let anchor = self.displayString.distance(
                from: self.displayString.startIndex,
                to: anchor.lowerBound);
            
            // consider offset for prior replacements in next step
            let offset = self.contentAnchors.count * replaceText.count;
            
            contentAnchors.append(anchor - offset + self.contentAnchors.count);
        }
        
        self.displayString = self.displayString.replacingOccurrences(
            of: replaceText,
            with: ""
        );
        
        self.contentViews = withContent.map({ contentView in
            { AnyView(contentView()) };
        });
    }
    
    /// The text color for the display string
    private var color: NSColor = .secondaryLabelColor;
    
    /// Set the text color for the display string.
    func color(_ color: NSColor) -> Self {
        var copy = self;
        copy.color = color;
        
        return copy;
    }
    
    /// The font for the display string
    private var font: NSFont = .systemFont(ofSize: 14, weight: .semibold);
    
    /// Set the font for the display string.
    func font(_ font: NSFont) -> Self {
        var copy = self;
        copy.font = font;
        
        return copy;
    }
    
    /// The alignment for the display string
    private var alignment: NSTextAlignment = .center;
    
    /// Set the alignment for the display string.
    func align(_ alignment: NSTextAlignment) -> Self {
        var copy = self;
        copy.alignment = alignment;
        
        return copy;
    }
    
    func makeNSView(context: Context) -> NSView {
        if FixOptions.useProperFix {
            // Use NSTextView (TextKit2) for proper NSTextAttachmentViewProvider support
            if #available(macOS 12.0, *) {
                return makeTextKitView()
            }
        }
        // Use NSTextField with workaround
        return makeTextField()
    }
    
    private func makeTextField() -> OffsetTextField {
        let textView = OffsetTextField();
        
        textView.translatesAutoresizingMaskIntoConstraints = false;
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal);
        textView.setContentCompressionResistancePriority(.required, for: .vertical);
        
        textView.isBezeled = false;
        textView.isEditable = false;
        textView.isSelectable = false;
        textView.drawsBackground = false;
        textView.isAutomaticTextCompletionEnabled = false;
        
        textView.lineBreakMode = .byWordWrapping;
        textView.maximumNumberOfLines = 0;
        
        textView.alignment = .center;
        textView.font = self.font;
        textView.textColor = self.color;
        
        textView.attributedStringValue = buildAttributedString();

        return textView;
    }

    // MARK: - Build Attributed String with Attachments

    private func buildAttributedString() -> NSMutableAttributedString {
        let attributedString = NSMutableAttributedString(string: self.displayString)
        attributedString.addAttributes([
            .font: self.font,
            .foregroundColor: self.color
        ], range: NSRange(location: 0, length: attributedString.length))

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = self.alignment
        attributedString.addAttribute(.paragraphStyle, value: paragraphStyle,
                                      range: NSRange(location: 0, length: attributedString.length))

        // Track attachment sizes for baseline offset calculation
        var attachmentSizes: [(index: Int, size: CGSize)] = []

        contentAnchors.enumerated().forEach { anchor in
            let offset = anchor.offset;
            let anchor = anchor.element;

            if offset > contentViews.count {
                NSLog("[InlineHostTextView] Content anchor occurrences exceed given content views.");
                return;
            }

            // Choose attachment type based on fix mode
            let attachment: NSTextAttachment
            if FixOptions.useProperFix {
                let hostingAttachment = HostingAttachment(content: self.contentViews[offset])
                attachment = hostingAttachment
                // Track size for baseline calculation (anchor shifts by number of prior insertions)
                let insertionIndex = anchor + attachmentSizes.count
                attachmentSizes.append((index: insertionIndex, size: hostingAttachment.attachmentSize))
                NSLog("[InlineHostingView] Using HostingAttachment (NSTextAttachmentViewProvider)")
            } else {
                // Original approach using NSTextAttachmentCell (has race condition)
                attachment = NSTextAttachment()
                attachment.attachmentCell = HostingCell(self.contentViews[offset])
                NSLog("[InlineHostingView] Using HostingCell (NSTextAttachmentCell)")
            }

            attributedString.insert(
                NSAttributedString(attachment: attachment),
                at: anchor
            );
        }

        // Apply baseline offset to text when using proper fix
        // This vertically centers text with taller attachments
        if FixOptions.useProperFix && !attachmentSizes.isEmpty {
            applyBaselineOffsets(to: attributedString, attachmentSizes: attachmentSizes)
        }

        return attributedString
    }

    /// Apply baseline offsets to text characters to vertically center them with attachments
    private func applyBaselineOffsets(to attributedString: NSMutableAttributedString,
                                       attachmentSizes: [(index: Int, size: CGSize)]) {
        // Find the tallest attachment
        let tallestAttachment = attachmentSizes.map { $0.size.height }.max() ?? 0

        // Get font metrics
        let fontHeight = self.font.capHeight

        // If attachments are taller than text, offset the text downward
        if tallestAttachment > fontHeight {
            let offset = (tallestAttachment - fontHeight) / 2.0

            // Apply baseline offset to all non-attachment characters
            let fullRange = NSRange(location: 0, length: attributedString.length)
            attributedString.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
                if value == nil {
                    // This is text, not an attachment - apply baseline offset
                    attributedString.addAttribute(.baselineOffset, value: offset, range: range)
                }
            }

            NSLog("[InlineHostingView] Applied baselineOffset=%.1f (attachmentH=%.1f, fontH=%.1f)",
                  offset, tallestAttachment, fontHeight)
        }
    }

    // MARK: - NSViewRepresentable

    func updateNSView(_ nsView: NSView, context: Context) {
        /// If we needed in this to be a usable control,
        /// we'd populate this method and add a `Coordinator`.
    }

    // MARK: - NSTextView Implementation

    @available(macOS 12.0, *)
    private func makeTextKitView() -> NSView {
        NSLog("[InlineHostingView] Creating TextKit2 NSTextView for proper attachment support")

        // Create TextKit2 stack
        let textContentStorage = NSTextContentStorage()
        let textLayoutManager = NSTextLayoutManager()
        textContentStorage.addTextLayoutManager(textLayoutManager)

        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textLayoutManager.textContainer = textContainer

        let textView = FittingTextView(frame: .zero, textContainer: textContainer)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)  // Don't grow vertically

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false  // Don't resize vertically
        textView.isHorizontallyResizable = false

        // Set the attributed string via textStorage
        let attributedString = buildAttributedString()
        textContentStorage.textStorage?.setAttributedString(attributedString)

        return textView
    }

    // MARK: - Fitting Text View

    /// NSTextView subclass that sizes to fit its text content
    @available(macOS 12.0, *)
    class FittingTextView: NSTextView {

        override var intrinsicContentSize: NSSize {
            guard let textLayoutManager = self.textLayoutManager else {
                return super.intrinsicContentSize
            }
            let usedRect = textLayoutManager.usageBoundsForTextContainer
            return NSSize(
                width: NSView.noIntrinsicMetric,
                height: usedRect.height + textContainerInset.height * 2
            )
        }

        override func layout() {
            super.layout()
            invalidateIntrinsicContentSize()
        }
    }

}



