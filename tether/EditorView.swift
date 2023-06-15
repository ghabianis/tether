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
    
    var fontAtlas = FontAtlas()
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
    
    func textToVertices(text: [UInt8], sx: Float, sy: Float) -> [Vertex] {
        var vertices = [Vertex]()
        var x: Float = -0.5
        var y: Float = 1.0
        
        for char in text {
            let c = UInt8(char)
            let glyph = self.fontAtlas.lookupChar(char: c)
            let l = Float(glyph.rect.origin.x)
            let r = Float(glyph.rect.origin.x + glyph.rect.width);
            let t = Float(glyph.rect.origin.y)
            let b = Float(glyph.rect.minY)
            let bitmap_w = Float(glyph.rect.width.intCeil())
            let bitmap_h = Float(glyph.rect.height.intCeil()) 
            
//            let x2 = x + l * sx;
//            let y2 = -y - t * sy
            
            let x2 = x + l * sx;
            let y2 = -y - t * sy
            
            let width = bitmap_w * sx
            let height = bitmap_h * sy
            
            x += glyph.advance * sx
            
            let color = float4(1.0, 0.0, 0.0, 1.0)
            let atlas_w = Float(self.fontAtlas.atlas.width)
            let atlas_h = Float(self.fontAtlas.atlas.height)
            
            print("Y \(-y2) \(-y2 - height)")
            // tl
            vertices.append(
                Vertex(
//                    pos: float2(x2, -y2),
                    pos: float2(-1.0, 1.0),
                    texCoords: float2(glyph.tx, glyph.ty),
                    color: color))
            
            // tr
            vertices.append(
                Vertex(
//                    pos: float2(x2 + width, -y2),
                    pos: float2(1.0, 1.0),
                    texCoords: float2(glyph.tx + bitmap_w / atlas_w, glyph.ty),
                    color: color))
            
            // bl
            vertices.append(
                Vertex(
//                    pos: float2(x2, -y2 - height),
                    pos: float2(-1.0, -1.0),
                    texCoords: float2(glyph.tx, glyph.ty + bitmap_h / atlas_h),
                    color: color))
            
            // tr
            vertices.append(
                Vertex(
//                    pos: float2(x2 + width, -y2),
                    pos: float2(1.0, 1.0),
                    texCoords: float2(glyph.tx + bitmap_w / atlas_w, glyph.ty),
                    color: color))
            
            // br
            vertices.append(
                Vertex(
//                    pos: float2(x2 + width, -y2 - height),
                    pos: float2(1.0, -1.0),
                    texCoords: float2(glyph.tx + bitmap_w / atlas_w, glyph.ty + bitmap_h / atlas_h),
                    color: color))
            
            // bl
            vertices.append(
                Vertex(
//                    pos: float2(x2, -y2 - height),
                    pos: float2(-1.0, -1.0),
                    texCoords: float2(glyph.tx, glyph.ty + bitmap_h / atlas_h),
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
        
        //        let modelURL = Bundle.main.url(forResource: "atlas", withExtension: "png")!
        //        self.texture = try! textureLoader.newTexture(URL: modelURL, options: options)
        
        //        let modelURL = Bundle.main.url(forResource: "shrek", withExtension: "png")!
        //        self.texture = try! textureLoader.newTexture(URL: modelURL)
        
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .linear
        //                samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToZero
        samplerDescriptor.tAddressMode = .clampToZero
        
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            fatalError("Failed to create sampler")
        }
        
        self.sampler = sampler
        
        //        let vertices = self.textToVertices(text: Array("!Hello world".utf8))
        print("SIZE \(self.size!)")
        let vertices = self.textToVertices(text: Array("A".utf8), sx: 1.0 / Float(self.size!.width * 2.0), sy: 1.0 / Float(self.size!.height * 2.0))
        
        //                let texCoords = self.fontAtlas.lookupChar(char: UInt8(70)).texCoords()
        //                let y: Float = 0.6035088
        //                let y: Float = 1
        //                let x: Float = 1.0
        //                let color = float4(1, 0, 0, 1)
        //                let blue = float4(0, 0, 1, 1)
        //                let vertices = [
        //                    Vertex(pos: float2(-x, -y), texCoords: texCoords[0], color: color),
        //                    Vertex(pos: float2(-x, y), texCoords: texCoords[1], color: color),
        //                    Vertex(pos: float2(x, y), texCoords: texCoords[2], color: color),
        //
        //                    Vertex(pos: float2(x, y), texCoords: texCoords[3], color: blue),
        //                    Vertex(pos: float2(x, -y), texCoords: texCoords[4], color: blue),
        //                    Vertex(pos: float2(-x, -y), texCoords: texCoords[5], color: blue),
        //                ]
        
        //        let vertices = [
        //            Vertex(pos: SIMD2<Float>(-0.9972763, 0.70581895), texCoords: float2(0, 0), color: color),
        //            Vertex(pos: SIMD2<Float>(-1.0, 0.70581895), texCoords: float2(0, 0), color: color),
        //            Vertex(pos: SIMD2<Float>(-1.0, 1.0), texCoords: float2(0, 0), color: color),
        //        ]
        
        print("VERTICES \(vertices)")
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
            //            let projectionMatrix = float4x4(orthographicProjectionLeft: -1, right: 1, bottom: -aspectRatio, top: aspectRatio, near: 0.1, far: 100.0)
            let projectionMatrix = float4x4(orthographicProjectionLeft: -1, right: 1, bottom: -1, top: 1, near: 0.1, far: 100.0)
            //                        let projectionMatrix = float4x4(orthographicProjectionLeft: -aspectRatio, right: aspectRatio, bottom: -1, top: 1, near: 0.1, far: 100.0)
            
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
