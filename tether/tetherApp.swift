//
//  tetherApp.swift
//  tether
//
//  Created by Zack Radisic on 06/06/2023.
//

import SwiftUI

class OverlayWindow: NSWindow {
    static var shared: OverlayWindow?
    
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
        self.backgroundColor = NSColor.clear
//        self.level = .floating
        self.level = .popUpMenu
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        OverlayWindow.shared = self
    }
    
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
}

struct OverlayWindowView: NSViewRepresentable {
    @Binding var isOverlayVisible: Bool
    @Binding var pos: CGPoint?
    @Binding var size: CGSize?
    
    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        DispatchQueue.main.async { // ensure UI updates are on the main thread.
            let rect: NSRect
            if let pos = self.pos, let size = self.size {
                rect = NSRect(origin: pos, size: size)
            } else {
                rect = nsView.bounds
            }
            
            if let overlayWindow = OverlayWindow.shared {
                overlayWindow.setFrame(rect, display: isOverlayVisible)
                overlayWindow.contentView = NSHostingView(rootView: ContentView())
                if isOverlayVisible {
                    overlayWindow.makeKeyAndOrderFront(nil)
                } else {
                    overlayWindow.orderOut(nil)
                }
            } else {
                let overlayWindow = OverlayWindow(contentRect: rect)
                
                overlayWindow.contentView = NSHostingView(rootView: ContentView2())
                if isOverlayVisible {
                    overlayWindow.makeKeyAndOrderFront(nil)
                } else {
                    overlayWindow.orderOut(nil)
                }
            }
        }
        return nsView
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { // ensure UI updates are on the main thread.
            if let overlayWindow = OverlayWindow.shared {
                if isOverlayVisible {
                    let rect: NSRect
                    if let pos = self.pos, let size = self.size {
                        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 800, height: 600)
                        let actualPos = CGPoint(x: pos.x, y: screenSize.height - pos.y - size.height)
                        rect = NSRect(origin:actualPos, size: size)
                    } else {
                        rect = nsView.bounds
                    }
                    overlayWindow.setFrame(rect, display: isOverlayVisible)
                    overlayWindow.makeKeyAndOrderFront(nil)
                } else {
                    overlayWindow.orderOut(nil)
                }
            }
        }
    }
}

struct ContentView2: View {
    var body: some View {
//        Text("Overlay Window")
//            .frame(maxWidth: .infinity, maxHeight: .infinity)
//            .background(Color.red.opacity(0.5))
        EditorViewRepresentable()
    }
}

@main
struct tetherApp: App {
    @ObservedObject var tetherState = TetherState()
    
    init() {
        tetherState.start()
    }
    
    var body: some Scene {
        WindowGroup {
            VStack {
                Text("Main Window")
                OverlayWindowView(isOverlayVisible: $tetherState.isOverlayVisible, pos: $tetherState.position, size: $tetherState.size)
            }
        }
    }
}
