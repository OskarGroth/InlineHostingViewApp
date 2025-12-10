//
//  InlineHostingView+ViewProvider.swift
//  InlineHostingViewApp
//
//  NSTextAttachmentViewProvider implementation for macOS 12+
//  This is Apple's designed solution for embedding views in text.
//

import AppKit
import SwiftUI

@available(macOS 12.0, *)
extension InlineHostingView {

    /// NSTextAttachmentViewProvider subclass that provides an NSHostingView for SwiftUI content.
    ///
    /// This is the proper way to embed views in text on macOS 12+:
    /// - The view is created via `loadView()` during layout, not draw
    /// - TextKit manages the view lifecycle correctly
    /// - No race conditions with CA transaction timing
    /// - Layer hierarchy is properly connected before display
    ///
    class HostingAttachmentViewProvider<Content: View>: NSTextAttachmentViewProvider {

        private let contentBuilder: () -> Content

        init(
            textAttachment: NSTextAttachment,
            parentView: NSView?,
            textLayoutManager: NSTextLayoutManager?,
            location: NSTextLocation,
            content: @escaping () -> Content
        ) {
            self.contentBuilder = content
            super.init(
                textAttachment: textAttachment,
                parentView: parentView,
                textLayoutManager: textLayoutManager,
                location: location
            )
        }

        override func loadView() {
            // This is called by TextKit during layout - the proper time to create views
            let hostingView = NSHostingView(rootView: contentBuilder())
            self.view = hostingView
            NSLog("HostingAttachmentViewProvider.loadView: created NSHostingView")
        }
    }

    /// NSTextAttachment subclass that uses NSTextAttachmentViewProvider.
    ///
    /// Key differences from NSTextAttachmentCell approach:
    /// - `viewProvider(for:location:)` returns the view provider
    /// - TextKit calls this during layout phase (not draw)
    /// - The view is added to the text view's hierarchy by TextKit
    /// - No manual addSubview needed, no race conditions
    ///
    class HostingAttachment<Content: View>: NSTextAttachment {

        private let contentBuilder: () -> Content
        let attachmentSize: CGSize  // Exposed for baseline offset calculation

        init(content: @escaping () -> Content) {
            self.contentBuilder = content

            // Calculate size from a temporary hosting view
            let tempHost = NSHostingView(rootView: content())
            self.attachmentSize = tempHost.fittingSize

            super.init(data: nil, ofType: nil)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // MARK: - View Provider (macOS 12+)

        override func viewProvider(
            for parentView: NSView?,
            location: NSTextLocation,
            textContainer: NSTextContainer?
        ) -> NSTextAttachmentViewProvider? {
            // This is called during layout, not draw
            NSLog("HostingAttachment.viewProvider: creating provider for location")

            guard let textContainer = textContainer,
                  let textLayoutManager = textContainer.textLayoutManager else {
                NSLog("HostingAttachment.viewProvider: no textLayoutManager, falling back to cell")
                return nil
            }

            return HostingAttachmentViewProvider(
                textAttachment: self,
                parentView: parentView,
                textLayoutManager: textLayoutManager,
                location: location,
                content: contentBuilder
            )
        }

        // MARK: - Size

        override func attachmentBounds(
            for textContainer: NSTextContainer?,
            proposedLineFragment lineFrag: NSRect,
            glyphPosition position: CGPoint,
            characterIndex charIndex: Int
        ) -> NSRect {
            return NSRect(origin: .zero, size: attachmentSize)
        }
    }
}
