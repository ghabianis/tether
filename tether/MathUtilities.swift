//
//  MathUtilities.swift
//  tether2
//
//  Created by Zack Radisic on 05/06/2023.
//

import simd
 
extension float4x4 {
    init(scaleBy s: Float) {
        self.init(float4(s, 0, 0, 0),
                  float4(0, s, 0, 0),
                  float4(0, 0, s, 0),
                  float4(0, 0, 0, 1))
    }
 
    init(rotationAbout axis: float3, by angleRadians: Float) {
        let x = axis.x, y = axis.y, z = axis.z
        let c = cosf(angleRadians)
        let s = sinf(angleRadians)
        let t = 1 - c
        self.init(float4( t * x * x + c,     t * x * y + z * s, t * x * z - y * s, 0),
                  float4( t * x * y - z * s, t * y * y + c,     t * y * z + x * s, 0),
                  float4( t * x * z + y * s, t * y * z - x * s,     t * z * z + c, 0),
                  float4(                 0,                 0,                 0, 1))
    }
 
    init(translationBy t: float3) {
        self.init(float4(   1,    0,    0, 0),
                  float4(   0,    1,    0, 0),
                  float4(   0,    0,    1, 0),
                  float4(t[0], t[1], t[2], 1))
    }
 
    init(orthographicProjectionLeft left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) {
            let dx = right - left
            let dy = top - bottom
            let dz = far - near
            
            let tx = -(right + left) / dx
            let ty = -(top + bottom) / dy
            let tz = (far + near) / dz
            
            self.init(float4(2 / dx, 0, 0, 0),
                      float4(0, 2 / dy, 0, 0),
                      float4(0, 0, 2 / dz, 0),
                      float4(tx, ty, tz, 1))
        }
        
    init(perspectiveProjectionFov fovYRadians: Float,
         aspectRatio: Float,
         near: Float,
         far: Float)
    {
        let sy = 1 / tan(fovYRadians * 0.5)
        let sx = sy / aspectRatio
        let zRange = far - near
        let sz = -(far + near) / zRange
        let tz = -2 * far * near / zRange
        self.init(SIMD4<Float>(sx, 0,  0,  0),
                  SIMD4<Float>(0, sy,  0,  0),
                  SIMD4<Float>(0,  0, sz, -1),
                  SIMD4<Float>(0,  0, tz,  0))
    }}
