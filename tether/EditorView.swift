//
//  EditorView.swift
//  tether2
//
//  Created by Zack Radisic on 05/06/2023.
//

import Foundation
import AppKit
import MetalKit
import simd
import SwiftUI
import CoreText
import EditorKit

struct Uniforms {
    var modelViewMatrix: float4x4
    var projectionMatrix: float4x4
}

struct Vertex {
    var pos: float2
    var texCoords: float2
    var color: float4
}

struct EditorViewRepresentable: NSViewControllerRepresentable {
    @Binding var pos: CGPoint?
    @Binding var size: CGSize?
    
    func makeNSViewController(context: Context) -> EditorViewController {
        var editorViewController = EditorViewController()
        DispatchQueue.main.async {
            editorViewController.mtkView.window?.makeFirstResponder(editorViewController.mtkView)
        }
        editorViewController.pos = self.pos
        editorViewController.size = self.size
        return editorViewController
    }
    
    func updateNSViewController(_ nsViewController: EditorViewController, context: Context) {
        nsViewController.pos = self.pos
        nsViewController.size = self.size
    }
    
    typealias NSViewControllerType = EditorViewController
    
}

class EditorViewController: NSViewController {
    var pos: CGPoint?
    var size: CGSize?
    
    var mtkView: CustomMTKView!
    var renderer: SwiftRenderer!
    
    override func loadView() {
        view = NSView()
        //        view = NSView(frame: NSMakeRect(0.0, 0.0, 400.0, 270.0))
        if var renderer = self.renderer {
            renderer.pos = pos
            renderer.size = size
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        mtkView = CustomMTKView()
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mtkView)
        view.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "|[mtkView]|", options: [], metrics: nil, views: ["mtkView" : mtkView!]))
        
        view.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "V:|[mtkView]|", options: [], metrics: nil, views: ["mtkView" : mtkView!]))
        
        let device = MTLCreateSystemDefaultDevice()
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        
        renderer = SwiftRenderer(view: mtkView, device: device!, pos: pos, size: size)
        mtkView.delegate = renderer
    }
}

class CustomMTKView: MTKView {
    var renderer: Renderer?
    private var accumulatedDeltaY: CGFloat = 0.0
    private var phase: NSEvent.Phase? = nil
    
    var isScrolling = false
    
    /*
    override func scrollWheel(with event: NSEvent) {
//        return;
        guard let renderer = self.renderer else {
            return
        }
        print("SCROLL!");
        //        switch (event.phase) {
        //        case NSEvent.Phase.began:
        //            print("NSEventPhaseBegan");
        //        case NSEvent.Phase.cancelled:
        //            print("NSEventPhaseCancelled");
        //        case NSEvent.Phase.changed:
        //            print("NSEventPhaseChanged");
        //        case NSEvent.Phase.ended:
        //            print("NSEventPhaseEnded");
        //        case NSEvent.Phase.mayBegin:
        //            print("NSEventPhaseMayBegin");
        //        case NSEvent.Phase.stationary:
        //            print("NSEventPhaseStationary");
        //        default:
        //            print("NSEventPhaseNone");
        //        }
        renderer_handle_scroll(renderer, event.deltaX, event.deltaY, event.phase)
    }
     */
    
     override func scrollWheel(with event: NSEvent) {
     //        super.scrollWheel(with: event)
     accumulatedDeltaY += event.scrollingDeltaY
         phase = event.phase
     }
    
    func handleAccumulatedScroll() {
        if let thePhase = self.phase {
            // Process the accumulated scroll delta here
            if let renderer = self.renderer {
                renderer_handle_scroll(renderer, 0.0, accumulatedDeltaY, thePhase);
            }
            
            // Reset the accumulated delta after processing
            accumulatedDeltaY = 0
            phase = nil
        }
    }
    
    override func keyDown(with event: NSEvent) {
        guard let renderer = self.renderer else {
            return
        }
        renderer_handle_keydown(renderer, event)
    }
}

class SwiftRenderer: NSObject, MTKViewDelegate {
    var pos: CGPoint?
    var size: CGSize?
    
    let device: MTLDevice
    let mtkView: CustomMTKView
    let zig: Renderer!
    
    init(view: CustomMTKView, device: MTLDevice, pos: CGPoint?, size: CGSize?) {
        self.pos = pos
        self.size = size
        
        self.mtkView = view
        self.device = device
        
        self.zig = renderer_create(view, device);
        
        let image: CGImage = renderer_get_atlas_image(self.zig) as! CGImage
        view.renderer = self.zig
        
        let url = URL(fileURLWithPath: "/Users/zackradisic/Code/tether/atlas.png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, kUTTypePNG, 1, nil)
        CGImageDestinationAddImage(destination!, image, nil)
        CGImageDestinationFinalize(destination!)
        //        let val = renderer_get_val(self.zig)
        //        print("VAL \(val)")
        
        super.init()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer_resize(self.zig, size);
        print("CHANGE \(view.drawableSize) \(size)");
    }
    
    func draw(in view: MTKView) {
        //        while let event = getNextEvent() {
        //            handle(event: event)
        //        }
        self.mtkView.handleAccumulatedScroll()
        
        renderer_draw(self.zig, view)
    }
    
    func getNextEvent() -> NSEvent? {
        return self.mtkView.window?.nextEvent(matching: .any, until: Date.distantPast, inMode: .default, dequeue: true)
    }
    
    func handle(event: NSEvent) {
        guard let renderer = self.zig else {
            return
        }
        
        switch event.type {
        case .leftMouseDown:
            break
        case .scrollWheel:
            renderer_handle_scroll(renderer, event.deltaX, event.deltaY, event.phase)
            print("SCROLL! \(event.deltaX) \(event.deltaY)")
        default:
            break
        }
    }}

extension [CChar] {
    func len() -> Int {
        var i = 0
        for c in self {
            if c == 0 {
                break
            }
            i += 1
        }
        return i
    }
}
