//
//  FontAtlas.swift
//  tether
//
//  Created by Zack Radisic on 07/06/2023.
//

import Foundation
import AppKit

struct GlyphInfo {
    let glyph: CGGlyph
    let rect: CGRect
}

/// Only supports monospaced fonts right now
class FontAtlas {
    var characters = String("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    var font = NSFont.systemFont(ofSize: 24) // Or any other font you want
    let margin: CGFloat = 2
    let MAX_WIDTH = 1024.0
    var glyphs: [GlyphInfo] = []
    var atlas: CGImage!
    
    func makeAtlas() {
        var atlas_height: Int
        let atlas_width: Int = Int(MAX_WIDTH);
        
        /// Calculate glyphs for our characters
        var unichars = [UniChar](repeating: 0, count: CFStringGetLength(characters as NSString))
        (characters as NSString).getCharacters(&unichars)
        var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        
        let gotGlyphs = CTFontGetGlyphsForCharacters(font, unichars, &glyphs, unichars.count)
        if !gotGlyphs {
            fatalError("Well we fucked up.")
        }
        
        /// Set glyph rects and atlwas w/h
        var glyph_rects = [CGRect](repeating: CGRect(), count: glyphs.count);
        let max_glyph_height = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, &glyph_rects, glyphs.count).height;
        
        var x: CGFloat = margin
        var y: CGFloat = margin
        for (i, glyph_rect) in glyph_rects.enumerated() {
            glyph_rects[i] = CGRect(x: x, y: y, width: glyph_rect.width, height: glyph_rect.height);
            x += glyph_rect.width + margin
            if x >= MAX_WIDTH {
                y += max_glyph_height + margin;
                x = 0;
            }
        }
        atlas_height = Int(ceil(y));
        
        
        /// Create a context for drawing
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: Int(atlas_width), height: Int(atlas_height), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: atlas_width, height: atlas_height))
        
        context.setFont(CTFontCopyGraphicsFont(font, nil))
        context.setFontSize(24)
        
        context.setFillColor(CGColor.black)
        
        /// Draw all the glyphs line by line
        var glyph_pos = glyph_rects.map { rect in
            CGPoint(x: rect.minX, y: rect.minY)
        };
        var rowStart = 0;
        var rowEnd = 0;
        while rowStart < glyph_rects.count {
            let current_y = glyph_rects[rowStart].minY;
            
            rowEnd = rowStart + 1;
            for (i, glyph) in glyph_rects[rowStart...].enumerated() {
                if glyph.minY != current_y {
                    rowEnd = rowStart + i;
                }
            }
            
            let count = rowEnd - rowStart;
            ShowGlyphsAtPositions(context, &glyphs, &glyph_pos, rowStart, count);
            rowStart = rowEnd;
        }
        
        // Now you can use the context to create a CGImage
        atlas = context.makeImage()!
        
        self.glyphs = [GlyphInfo](repeating: GlyphInfo(glyph: CGGlyph(), rect: CGRect()), count: glyphs.count)
        for (i, glyph) in glyphs.enumerated() {
        let rect = glyph_rects[i]
            self.glyphs[i] = GlyphInfo(glyph: glyph, rect: rect)
        }
    }
}
