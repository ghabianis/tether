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
    var meshes: [MTKMesh] = []
    var renderPipeline: MTLRenderPipelineState!
    let commandQueue: MTLCommandQueue
    
    var fontAtlas = FontAtlas()
    var texture: MTLTexture!
    var sampler: MTLSamplerState!
    
    var time: Float = 0
    
    init(view: MTKView, device: MTLDevice, pos: CGPoint?, size: CGSize?) {
        self.pos = pos
        self.size = size
        
        self.mtkView = view
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        
        super.init()
        
        loadResources()
        buildPipeline()
        buildFontAtlas()
    }
    
    func buildFontAtlas() {
        self.fontAtlas.makeAtlas()
        let textureLoader = MTKTextureLoader(device: self.device)
        self.texture = try! textureLoader.newTexture(cgImage: self.fontAtlas.atlas, options: nil)
        
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            fatalError("Failed to create sampler")
        }
        
        self.sampler = sampler
    }
    
    func loadResources() {
        let modelURL = Bundle.main.url(forResource: "teapot", withExtension: "obj")!
        
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        vertexDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: MemoryLayout<Float>.size * 3, bufferIndex: 0)
        vertexDescriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: MemoryLayout<Float>.size * 6, bufferIndex: 0)
        
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 8)
        
        self.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(vertexDescriptor)
        
        let bufferAllocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: modelURL, vertexDescriptor: vertexDescriptor, bufferAllocator: bufferAllocator)
        
        do {
            (_, meshes) = try MTKMesh.newMeshes(asset: asset, device: device)
        } catch {
            fatalError("Could not extract meshes from Model I/O asset")
        }
    }
    
    func buildPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Could not load default library from main bundle")
        }
        
        let vertexFunction = library.makeFunction(name: "vertex_main")
        let fragmentFunction = library.makeFunction(name: "fragment_main")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        
        do {
            renderPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Could not create render pipeline state object: \(error)")
        }
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
    
    func draw(in view: MTKView) {
        print("NICE \(self.size) \(self.pos)")
        if self.size == nil || self.pos == nil {
            return
        }
        let commandBuffer = commandQueue.makeCommandBuffer()!
        
        if  let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable {
            
            
            let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
            
            time += 1 / Float(mtkView.preferredFramesPerSecond)
            let angle = -time
            let modelMatrix = float4x4(rotationAbout: float3(0, 1, 0), by: angle)  *  float4x4(scaleBy: 1)
            let viewMatrix = float4x4(translationBy: float3(0, 0.0, -1.0))
            
            let modelViewMatrix = viewMatrix * modelMatrix
            
            let aspectRatio = Float(view.drawableSize.width / view.drawableSize.height)
            let projectionMatrix = float4x4(orthographicProjectionLeft: -aspectRatio, right: aspectRatio, bottom: -1.0, top: 1.0, near: 0.1, far: 100.0)
            
            var uniforms = Uniforms(modelViewMatrix: modelViewMatrix, projectionMatrix: projectionMatrix)
            
            commandEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            commandEncoder.setRenderPipelineState(renderPipeline)
            
            for mesh in meshes {
                let vertexBuffer = mesh.vertexBuffers.first!
                commandEncoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: 0)
                commandEncoder.setFragmentTexture(self.texture, index: 0)
                commandEncoder.setFragmentSamplerState(self.sampler, index: 0)
                
                for submesh in mesh.submeshes {
                    let indexBuffer = submesh.indexBuffer
                    commandEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                         indexCount: submesh.indexCount,
                                                         indexType: submesh.indexType,
                                                         indexBuffer: indexBuffer.buffer,
                                                         indexBufferOffset: indexBuffer.offset)
                }
            }
            
            
            commandEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
