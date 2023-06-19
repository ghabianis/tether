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
    var renderer: Renderer!
    
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
        
        renderer = Renderer(view: mtkView, device: device!, pos: pos, size: size)
        mtkView.delegate = renderer
    }
}

class Renderer: NSObject, MTKViewDelegate {
    var pos: CGPoint?
    var size: CGSize?
    
    let device: MTLDevice
    let mtkView: MTKView
    var vertexDescriptor: MTLVertexDescriptor!
    var renderPipeline: MTLRenderPipelineState!
    let commandQueue: MTLCommandQueue
    
    var fontAtlas = FontAtlas(fontSize: 64 * 2)
    var texture: MTLTexture!
    var sampler: MTLSamplerState!
    var vertexBuffer: MTLBuffer!
    var verticesLen: Int!
    
    var time: Float = 0
    
    init(view: MTKView, device: MTLDevice, pos: CGPoint?, size: CGSize?) {
        self.pos = pos
        self.size = size
        
        self.mtkView = view
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        
        super.init()
        
        buildPipeline()
        buildFontAtlas()
    }
    
    func textToVertices(text: [UInt8], screenx: Float, screeny: Float) -> [Vertex] {
        var vertices = [Vertex]()
        var x: Float = 0.0
        var y: Float = screeny - Float(self.fontAtlas.max_glyph_height)
        
        let starting_x = x;
        
        for char in text {
            let c = UInt8(char)
            
            let glyph = self.fontAtlas.lookupChar(char: c)
            let l = Float(glyph.rect.origin.x)
            let r = Float(glyph.rect.origin.x + glyph.rect.width);
            let t = Float(glyph.rect.origin.y)
            let b = Float(glyph.rect.minY)
            let bitmap_w = Float(glyph.rect.width.intCeil())
            let bitmap_h = Float(glyph.rect.height.intCeil())
            
            let width = bitmap_w
            let height = bitmap_h
            let ydif = Float(self.fontAtlas.max_glyph_height)  - height
            
            let x2 = x + l
            let y2 = y + Float(glyph.rect.maxY.intCeil());
            let bot = y + Float(glyph.rect.minY.intCeil());
            
            let color = float4(1.0, 0.0, 0.0, 1.0)
            let atlas_w = Float(self.fontAtlas.atlas.width)
            let atlas_h = Float(self.fontAtlas.atlas.height)
            
            let tyt = glyph.ty - bitmap_h / atlas_h;
            let tyb = glyph.ty;
            
            switch (c) {
            // Tab
            case 9:
                x += self.fontAtlas.lookupCharFromStr(char: " ").advance * 4.0
            // New line
            case 10:
                x = starting_x
                y -= Float(self.fontAtlas.max_glyph_height)
            default:
                if glyph.rect.width == 0.0 && glyph.rect.height == 0.0 {
                    continue
                }
                x += glyph.advance
            }
            
            // tl
            vertices.append(
                Vertex(
                    pos: float2(x2, y2),
                    //                    pos: float2(-1.0, 1.0),
                    texCoords: float2(glyph.tx, tyt),
                    color: color))
            
            // tr
            vertices.append(
                Vertex(
                    pos: float2(x2 + width, y2),
                    //                    pos: float2(1.0, 1.0),
                    texCoords: float2(glyph.tx + bitmap_w / atlas_w, tyt),
                    color: color))
            
            // bl
            vertices.append(
                Vertex(
                    pos: float2(x2, bot),
                    //                    pos: float2(-1.0, -1.0),
                    texCoords: float2(glyph.tx, tyb),
                    color: color))
            
            // tr
            vertices.append(
                Vertex(
                    pos: float2(x2 + width, y2),
                    //                    pos: float2(1.0, 1.0),
                    texCoords: float2(glyph.tx + bitmap_w / atlas_w, tyt),
                    color: color))
            
            // br
            vertices.append(
                Vertex(
                    pos: float2(x2 + width, bot),
                    //                    pos: float2(1.0, -1.0),
                    texCoords: float2(glyph.tx + bitmap_w / atlas_w, tyb),
                    color: color))
            
            // bl
            vertices.append(
                Vertex(
                    pos: float2(x2, bot),
                    //                    pos: float2(-1.0, -1.0),
                    texCoords: float2(glyph.tx, tyb),
                    color: color))
        }
        
        return vertices
    }
    
    func buildFontAtlas() {
        self.fontAtlas.makeAtlas()
        print("ATLAS \(self.fontAtlas.atlas.width) \(self.fontAtlas.atlas.height)")
        
        let textureLoader = MTKTextureLoader(device: self.device)
        let options: [MTKTextureLoader.Option : Any] = [
            .textureUsage : MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode : MTLStorageMode.private.rawValue,
            .SRGB: true
        ]
        
        self.texture = try! textureLoader.newTexture(cgImage: self.fontAtlas.atlas, options: options)
        
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToZero
        samplerDescriptor.tAddressMode = .clampToZero
        
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            fatalError("Failed to create sampler")
        }
        
        self.sampler = sampler
        
        let vertices = self.textToVertices(text: Array("PooPy qbgoi\nnicebro\n\nwooo".utf8), screenx:  Float(self.size!.width * 2.0), screeny: Float(self.size!.height * 2.0))
        
        self.vertexBuffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.size * vertices.count)!
        self.verticesLen = vertices.count
    }
    
    func buildPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Could not load default library from main bundle")
        }
        
        let vertexFunction = library.makeFunction(name: "vertex_main")
        let fragmentFunction = library.makeFunction(name: "fragment_main")
        
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float2, offset: 0, bufferIndex: 0)
        vertexDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: MemoryLayout<float2>.size, bufferIndex: 0)
        vertexDescriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeColor, format: .float4, offset: MemoryLayout<float2>.size * 2, bufferIndex: 0)
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<float2>.size * 2 + MemoryLayout<float4>.size)
        self.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(vertexDescriptor)
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        pipelineDescriptor.vertexDescriptor = self.vertexDescriptor
        
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            renderPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Could not create render pipeline state object: \(error)")
        }
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
    
    func draw(in view: MTKView) {
        let commandBuffer = commandQueue.makeCommandBuffer()!
        
        if  let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable {
            
            let colorAttachmentDesc = renderPassDescriptor.colorAttachments[0]!
            //            colorAttachmentDesc.texture = // your render target texture here
            colorAttachmentDesc.loadAction = MTLLoadAction.clear
            colorAttachmentDesc.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0) // black color value
            
            let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
            commandEncoder.setViewport(MTLViewport(originX: 0.0, originY: 0.0, width: view.drawableSize.width, height: view.drawableSize.height, znear: 0.1, zfar: 100.0))
            
            time += 1 / Float(mtkView.preferredFramesPerSecond)
            let angle = -time
            //            let aspectRatio = Float(view.drawableSize.width / view.drawableSize.height)
            // this is with the dpi so it is * 2 of the actual size
            let aspectRatio = Float(view.drawableSize.height / view.drawableSize.width)
            //            print("VIEW SIZE \(view.drawableSize)")
            
            //            print("DAMN \(aspectRatio)")
            //            let modelMatrix = float4x4(rotationAbout: float3(0, 1, 0), by: angle)  *  float4x4(scaleBy: 1)
            let modelMatrix = float4x4(scaleBy: 1) * float4x4(scaleBy: 1.0)
            //            let viewMatrix = float4x4(translationBy: float3(0, 0, -1.5))
            //            let viewMatrix = float4x4(translationBy: float3(0.25, -0.5, -1.5))
            let viewMatrix = float4x4(translationBy: float3(0.0, 0.0, -1.5))
            //            let viewMatrix = float4x4(translationBy: float3(0.0, -time * 0.5, -1.5))
            
            let modelViewMatrix = viewMatrix * modelMatrix
            
            //            print("WTF \(aspectRatio)")
            //            let projectionMatrix = float4x4(perspectiveProjectionFov: Float.pi / 3, aspectRatio: aspectRatio, near: 0.1, far: 100.0)
            //                        let projectionMatrix = float4x4(orthographicProjectionLeft: -1, right: 1, bottom: -aspectRatio, top: aspectRatio, near: 0.1, far: 100.0)
            //            let projectionMatrix = float4x4(orthographicProjectionLeft: -1, right: 1, bottom: -1, top: 1, near: 0.1, far: 100.0)
            let projectionMatrix = float4x4(orthographicProjectionLeft: 0, right: Float(view.drawableSize.width ), bottom: 0, top: Float(view.drawableSize.height ), near: 0.1, far: 100.0)
            //            let projectionMatrix = float4x4(orthographicProjectionLeft: 0, right: Float(view.drawableSize.width), bottom: Float(view.drawableSize.height), top: 0, near: 0.1, far: 100.0)
            //            let projectionMatrix = float4x4(orthographicProjectionLeft: -aspectRatio, right: aspectRatio, bottom: -1, top: 1, near: 0.1, far: 100.0)
            
            var uniforms = Uniforms(modelViewMatrix: modelViewMatrix, projectionMatrix: projectionMatrix)
            
            commandEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            commandEncoder.setRenderPipelineState(renderPipeline)
            
            commandEncoder.setVertexBuffer(self.vertexBuffer, offset: 0, index: 0)
            commandEncoder.setFragmentTexture(self.texture, index: 0)
            commandEncoder.setFragmentSamplerState(self.sampler, index: 0)
            commandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verticesLen)
            
            commandEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
