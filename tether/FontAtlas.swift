//
//  FontAtlas.swift
//  tether
//
//  Created by Zack Radisic on 07/06/2023.
//

import Foundation
import AppKit
import simd

struct GlyphInfo {
    let glyph: CGGlyph
    let rect: CGRect
    let tx: Float
    let ty: Float
    let advance: Float
    
    init() {
        self.init(glyph: CGGlyph(), rect: CGRect(), tx: 0.0, ty: 0.0)
    }
    init (glyph: CGGlyph, rect: CGRect) {
        self.init(glyph: glyph, rect: rect, tx: 0.0, ty: 0.0)
    }
    init (glyph: CGGlyph, rect: CGRect, tx: Float, ty: Float) {
        self.init(glyph: glyph, rect: rect, tx: ty, ty: tx, advance: 0.0)
    }
    init (glyph: CGGlyph, rect: CGRect, tx: Float, ty: Float, advance: Float) {
        self.glyph = glyph
        self.rect = rect
        self.tx = tx
        self.ty = ty
        self.advance = advance
    }
    
    func texCoords() -> [float2] {
        //        let left = Float(0.0)
        //        let right = Float(1.0)
        //        let top = Float(1.0)
        //        let bot = Float(0.0)
        
        let left = Float(self.rect.minX)
        let right = Float(self.rect.maxX)
        let top = Float(self.rect.origin.y + self.rect.height)
        let bot = Float(self.rect.origin.y )
        
        //        let left = Float(526.0 / 1024)
        //        let right = Float(538.0 / 1024)
        //        let top = Float(35 / 58)
        //        let bot = Float(54 / 58)
        //        let bot = Float(35.0 / 58.0)
        //        let top = Float(54.0 / 58.0)
        
        return [
            float2(left, top),
            float2(left, bot),
            float2(right, bot),
            
            float2(right, bot),
            float2(right, top),
            float2(left, top),
        ]
    }
}

extension Double {
    func intCeil() -> Int {
        Int(ceil(self))
    }
}

extension Float {
    func intCeil() -> Int {
        Int(ceil(self))
    }
}

extension CGFloat {
    func intCeil() -> Int {
        Int(ceil(self))
    }
}

/// Only supports monospaced fonts right now
class FontAtlas {
    //    var characters = String("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    //    var font = NSFont.systemFont(ofSize: 48) // Or any other font you want
//    var font: NSFont = NSFont(name: "Iosevka SS04", size: 48)!
    var font: NSFont
    var fontSize: CGFloat
    let margin: CGFloat = 4
    let MAX_WIDTH = 1024.0
    var max_glyph_height: Int = 0
    var max_glyph_height_normalized: Float = 0.0
    var glyph_info: [GlyphInfo] = []
    var atlas: CGImage!
    
    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        self.font = NSFont(name: "Iosevka SS04", size: fontSize)!
    }
    
    func lookupCharFromStr(char: String) -> GlyphInfo {
        return lookupChar(char: char.first!.asciiValue!)
    }
    
    func lookupChar(char: UInt8) -> GlyphInfo {
        assert(char < glyph_info.count)
        return self.glyph_info[Int(char)]
    }
    
    func getAdvance(ctfont: CGFont, glyph: CGGlyph) -> Int {
        var the_glyph: [CGGlyph] = [glyph]
        var advances: [Int32] = [0]
        if !ctfont.getGlyphAdvances(glyphs: &the_glyph, count: 1, advances: &advances) {
            fatalError("WTF!")
        }
        return Int(ceil((Float(advances[0]) / Float(1000)) * Float(self.fontSize)));
    }
    
    func makeAtlas() {
        let CHAR_END: UInt8 = 127;
        self.glyph_info = [GlyphInfo](repeating: GlyphInfo(), count: Int(CHAR_END));
        
        var cchars: [UInt8] = (32..<CHAR_END).map { i in i }
        cchars.append(0)
        let characters = String(cString: cchars)
        
        /// Calculate glyphs for our characters
        var unichars = [UniChar](repeating: 0, count: CFStringGetLength(characters as NSString))
        (characters as NSString).getCharacters(&unichars)
        
        var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        let gotGlyphs = CTFontGetGlyphsForCharacters(font, unichars, &glyphs, unichars.count)
        if !gotGlyphs {
            fatalError("Well we fucked up.")
        }
        
        var glyph_rects = [CGRect](repeating: CGRect(), count: glyphs.count);
        let total_bounding_rect = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, &glyph_rects, glyphs.count)
        let ctfont = CTFontCopyGraphicsFont(font, nil)
        
        var roww = 0
        var rowh = 0
        var w = 0
        var h = 0
        var max_w = 0
        for i in 32..<CHAR_END {
            let j = Int(i - 32);
            let glyph = glyphs[j];
            let glyph_rect = glyph_rects[j];
            let advance = self.getAdvance(ctfont: ctfont, glyph: glyph);
            
            if roww + glyph_rect.width.intCeil() + advance + 1 >= MAX_WIDTH.intCeil() {
                w = max(w, roww);
                h += rowh
                roww = 0
                //                rowh = 0
            }
            
            max_w = max(max_w, glyph_rect.width.intCeil())
            
            roww += glyph_rect.width.intCeil() + advance + 1
            rowh = max(rowh, glyph_rect.height.intCeil())
        }
        
        let max_h = rowh;
        self.max_glyph_height = max_h;
        w = max(w, roww);
        h += rowh;
        
        let tex_w = w
        let tex_h = h
        
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: tex_w, height: tex_h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.0, green: 0, blue: 0, alpha: 0.0))
        context.fill(CGRect(x: 0, y: 0, width: tex_w, height: tex_h))
        context.setFont(ctfont)
        context.setFontSize(self.fontSize)
        
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        context.setAllowsFontSmoothing(true)
        
        context.setShouldSubpixelPositionFonts(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.setAllowsFontSubpixelPositioning(false)
        context.setAllowsFontSubpixelQuantization(false)
        
        
        context.setFillColor(CGColor(red: 0.0, green: 1, blue: 0, alpha: 1.0))
        var ox: Int = 0
        var oy: Int = 0
        
        for i in 32..<CHAR_END {
            let j = Int(i - 32);
            let glyph = glyphs[j];
            let rect = glyph_rects[j];
            
            let rectw = rect.width.intCeil()
            let recth = rect.height.intCeil()
            
            let advance = self.getAdvance(ctfont: ctfont, glyph: glyph)
            
            if (ox + rectw + advance + 1) >= MAX_WIDTH.intCeil() {
                ox = 0;
                oy += max_h;
                rowh = 0
            }
            
            let tx = Float(ox) / Float(tex_w)
            // the -rect.origin.y IS REALLY FUCKING IMORTANT, its to adjust because some glyphs that
            // are tall (like y) need to be adjusted
            let ty = (Float(tex_h) - (Float(oy) + Float(rect.origin.y))) / Float(tex_h)
            var the_glyph: [CGGlyph] = [glyph]
            ShowGlyphsAtPoint(context, &the_glyph, CGFloat(ox), CGFloat(oy))
            
            var new_rect = rect
            new_rect = CGRect(x: new_rect.origin.x, y: new_rect.origin.y, width: CGFloat(Float(advance)), height: new_rect.height)
            
            self.glyph_info[Int(i)] = GlyphInfo(
                glyph: glyph,
                rect: new_rect,
                tx: tx,
                ty: ty,
                advance: Float(advance)
            )
            
            ox += rectw + advance + 1
        }
        
        atlas = context.makeImage()!
    }
}
