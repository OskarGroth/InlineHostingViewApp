//
//  InlineHostView+HostingCell.swift
//  InlineHostingViewApp
//
//  Created by Stephan Casas on 5/1/23.
//

import AppKit;
import SwiftUI;

extension InlineHostingView {
    
    class HostingCell<Content: View>: NSTextAttachmentCell {
        
        private let contentView: () -> Content;
        private let contentHost: NSHostingView<Content>;
        
        init(_ content: @escaping () -> Content) {
            self.contentView = content;
            self.contentHost = NSHostingView(rootView: contentView());
            
            super.init();
        }
        
        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
            guard let controlView = controlView else {
                return;
            }
            
            if BugReproduction.reproduceBug {
                // ⚠️ BUG: Adding subview during draw() causes race condition!
                //
                // WHY THIS HAPPENS:
                // 1. addSubview() connects the View hierarchy immediately (superview chain)
                // 2. But AppKit connects the Layer hierarchy lazily/asynchronously
                // 3. When we call layoutSubtreeIfNeeded() + displayIfNeeded(), the layer
                //    tries to display, but superlayer.superlayer is still nil
                // 4. AppKit calculates geometryFlipped using: self.isFlipped XOR ancestor.isFlipped
                // 5. With no connected ancestor, this calculation is wrong
                // 6. Core Animation creates CGContext with wrong CTM (d = -2 instead of +2)
                // 7. Text renders upside-down into the cached CABackingStore
                //
                // PROOF (from LLDB during bug):
                //   View hierarchy connected:  [[superlayer delegate] superview] → exists
                //   Layer hierarchy broken:    [superlayer superlayer] → nil
                //
                controlView.addSubview(contentHost)
                contentHost.frame = NSRect(
                    x: cellFrame.origin.x,
                    y: cellFrame.origin.y,
                    width: cellFrame.width,
                    height: cellFrame.height)
                
                // Force immediate display to guarantee 100% repro of the bug
                if let layer = contentHost.layer {
                    // Force layout first to create sublayers
                    contentHost.layoutSubtreeIfNeeded()
                    
                    // Now force display on all layers (including CGDrawingLayers)
                    // This triggers display while superlayer.superlayer is still nil
                    func forceDisplay(_ l: CALayer) {
                        l.setNeedsDisplay()
                        l.displayIfNeeded()
                        for sub in l.sublayers ?? [] {
                            forceDisplay(sub)
                        }
                    }
                    forceDisplay(layer)
                }
            } else if FixOptions.enableWorkaround {
                // Workaround: Defer addSubview (and frame set) until after current CA transaction
                //
                // KEY INSIGHT: The cellFrame passed to draw() is only correct AFTER the text
                // system has completed layout. By deferring to CATransaction.setCompletionBlock,
                // we ensure:
                // 1. The text layout is complete (so cellFrame captured here is correct)
                // 2. The layer hierarchy will be connected before display
                //
                // Capturing frame inside the completion block works because:
                // - The completion block runs after the current CA transaction commits
                // - By that time, the layer tree is connected (superlayer.superlayer != nil)
                // - The cellFrame we capture here (in draw) is the correct final position
                //
                let frame = NSRect(
                    x: cellFrame.origin.x,
                    y: cellFrame.origin.y,
                    width: cellFrame.width,
                    height: cellFrame.height)
                
                if contentHost.superview == nil {
                    // First time: defer addSubview to CATransaction completion
                    CATransaction.setCompletionBlock { [weak self] in
                        guard let self = self else { return }
                        guard self.contentHost.superview == nil else { return }
                        NSLog("HostingCell.draw (fix): deferred addSubview, frame=\(frame)")
                        controlView.addSubview(self.contentHost)
                        self.contentHost.frame = frame
                    }
                } else {
                    // Already attached: just update frame
                    contentHost.frame = frame
                }
            } else {
                // Natural timing (no forced repro, no explicit fix):
                // Add subview immediately but do not force display within this draw pass.
                //
                // This causes a race condition (~10% of launches). We leave it up to chance
                // whether the layer hierarchy is connected before CA::Transaction::commit()
                // runs the display phase.
                // Easier to reproduce if you leave the window in a constrained layout
                // (very narrow, forcing truncation) and then relaunching.
                //
                // GOOD case (layer hierarchy connected in time):
                //   addSubview() → view hierarchy connected
                //   ... CA transaction processes ...
                //   layer hierarchy connected (superlayer.superlayer != nil)
                //   CA::Transaction::commit() → display phase
                //   CGDrawingLayer.display() sees gp_exists=1, superlayer.flip=1
                //   CTM.d = +2 (correct) → text renders right-side up
                //
                // BAD case (layer hierarchy NOT connected in time):
                //   addSubview() → view hierarchy connected
                //   CA::Transaction::commit() → display phase (runs too soon!)
                //   layer hierarchy NOT connected (superlayer.superlayer == nil)
                //   CGDrawingLayer.display() sees gp_exists=0, superlayer.flip=0
                //   geometryFlipped cannot be calculated (no ancestor chain)
                //   CTM.d = -2 (wrong) → text renders upside-down
                //   ... later, layer hierarchy connects, but content already cached wrong
                //
                if contentHost.superview == nil {
                    NSLog("HostingCell addSubview (natural): superview was nil")
                } else {
                    NSLog("HostingCell addSubview (natural): superview was not nil")
                }
                NSLog("HostingCell.draw (natural): cellFrame=\(cellFrame), controlView.bounds=\(controlView.bounds)")
                controlView.addSubview(contentHost)
                contentHost.frame = NSRect(
                    x: cellFrame.origin.x,
                    y: cellFrame.origin.y,
                    width: cellFrame.width,
                    height: cellFrame.height)
            }
        }
        
        override func cellSize() -> NSSize {
            self.contentHost.fittingSize;
        }
        
        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
    
}
