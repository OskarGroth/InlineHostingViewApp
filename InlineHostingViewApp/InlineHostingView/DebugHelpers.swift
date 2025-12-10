//
//  DebugHelpers.swift
//  InlineHostingViewApp
//
//  Created by Oskar Groth on 2025-12-10.
//

import AppKit
import ObjectiveC;

// MARK: - Bug Reproduction Settings

/// Access from non-SwiftUI code (e.g., HostingCell)
enum BugReproduction {
    static var reproduceBug: Bool {
        UserDefaults.standard.object(forKey: "reproduceBug") as? Bool ?? true
    }
}

/// Global access for enabling/disabling fixes from non-SwiftUI code
enum FixOptions {
    /// Workaround: defer attachment until after current CA transaction
    static var enableWorkaround: Bool {
        UserDefaults.standard.object(forKey: "enableWorkaround") as? Bool ?? false
    }

    /// Proper fix toggle (system-managed attachment path)
    static var useProperFix: Bool {
        UserDefaults.standard.object(forKey: "useProperFix") as? Bool ?? false
    }
}

// MARK: - Flipped CTM Detector

class FlippedCTMDetector {
    static var isInstalled = false
    static var detectionCount = 0

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        print("╔════════════════════════════════════════════════════════════╗")
        print("║  Flipped CTM Detector ACTIVE                               ║")
        print("║  BugReproduction.reproduceBug = \(BugReproduction.reproduceBug)                       ║")
        print("╚════════════════════════════════════════════════════════════╝")

        swizzleDisplay(for: CALayer.self)
    }

    private static func swizzleDisplay(for layerClass: AnyClass) {
        let originalSelector = NSSelectorFromString("display")
        let swizzledSelector = #selector(CALayer.swizzled_display)

        guard let originalMethod = class_getInstanceMethod(layerClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(CALayer.self, swizzledSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
        print("✓ Swizzled CALayer.display")
    }
}

// MARK: - CALayer Swizzle Extension

extension CALayer {
    @objc func swizzled_display() {
        let className = String(cString: object_getClassName(self))

        if className.contains("CGDrawingLayer") {
            let isFirstDisplay = (self.contents == nil)
            let grandparentExists = (self.superlayer?.superlayer != nil)
            let superlayerFlipped = self.superlayer?.isGeometryFlipped ?? false
            let grandparentFlipped = self.superlayer?.superlayer?.isGeometryFlipped ?? false

            // Check if we're being called during a draw pass or CA transaction
            let stack = Thread.callStackSymbols.joined(separator: "\n")
            let duringDraw = stack.contains("draw") || stack.contains("Draw")
            // C++ mangled: _ZN2CA11Transaction6commitEv = CA::Transaction::commit
            let duringTransaction = stack.contains("CA11Transaction") || stack.contains("Transaction6commit")

            if isFirstDisplay {
                // Log EVERY first display with full context
                let layerAddr = Unmanaged.passUnretained(self).toOpaque()
                let status = grandparentExists ? "OK" : "BAD"

                NSLog("═══════════════════════════════════════════════════════════")
                NSLog("CGDrawingLayer FIRST DISPLAY [%@]", status)
                NSLog("  Layer: %@", "\(layerAddr)")
                NSLog("  gp_exists=%d  superlayer.flip=%d  gp.flip=%d",
                      grandparentExists ? 1 : 0,
                      superlayerFlipped ? 1 : 0,
                      grandparentFlipped ? 1 : 0)
                NSLog("  during_draw=%d  during_CA_commit=%d",
                      duringDraw ? 1 : 0,
                      duringTransaction ? 1 : 0)

                // Detect the bug condition: layer hierarchy not connected
                if !grandparentExists {
                    FlippedCTMDetector.detectionCount += 1
                    NSLog("🚨 BUG #%d: LAYER HIERARCHY NOT CONNECTED!", FlippedCTMDetector.detectionCount)
                    NSLog("   superlayer.superlayer is nil → geometryFlipped calc will fail")
                    NSLog("   Expected CTM.d = -2 (wrong), should be +2 (correct)")

                    // Print abbreviated backtrace (key frames only)
                    let keyFrames = Thread.callStackSymbols.prefix(15)
                    NSLog("   Backtrace (top 15):")
                    for (i, frame) in keyFrames.enumerated() {
                        NSLog("     %2d: %@", i, frame)
                    }
                }
                NSLog("═══════════════════════════════════════════════════════════")
            }
        }

        // Call original
        self.swizzled_display()
    }
}
