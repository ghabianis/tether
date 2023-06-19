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
        //        return EditorViewController(pos: pos, size: size)
        var editorViewController = EditorViewController()
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
    
    var mtkView: MTKView!
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
        mtkView = MTKView()
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mtkView)
        view.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "|[mtkView]|", options: [], metrics: nil, views: ["mtkView" : mtkView!]))
        
        view.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "V:|[mtkView]|", options: [], metrics: nil, views: ["mtkView" : mtkView!]))
        
        let device = MTLCreateSystemDefaultDevice()
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        
        var nice = MTLVertexDescriptor();
        var attrs = nice.attributes;
        
        renderer = SwiftRenderer(view: mtkView, device: device!, pos: pos, size: size)
        mtkView.delegate = renderer
    }
}

class SwiftRenderer: NSObject, MTKViewDelegate {
    var pos: CGPoint?
    var size: CGSize?
    
    let device: MTLDevice
    let mtkView: MTKView
    let zig: Renderer
    
    init(view: MTKView, device: MTLDevice, pos: CGPoint?, size: CGSize?) {
        self.pos = pos
        self.size = size
        
        self.mtkView = view
        self.device = device
        
        self.zig = renderer_create(view, device);
        let val = renderer_get_val(self.zig)
        print("VAL \(val)")
        
        super.init()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
    
    func draw(in view: MTKView) {
        
    }
}
