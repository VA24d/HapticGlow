// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// HapticGlow app icon generator. Usage: swift make_icon.swift <outdir>
// Writes AppIcon.iconset/ (all macOS sizes) and icon-1024.png into <outdir>.
// Each size is rendered straight from vector at that pixel size.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func col(_ r: Int,_ g: Int,_ b: Int,_ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [CGFloat(r)/255,CGFloat(g)/255,CGFloat(b)/255,a])! }
func grad(_ s: [(CGFloat, CGColor)]) -> CGGradient { CGGradient(colorsSpace: cs, colors: s.map{$0.1} as CFArray, locations: s.map{$0.0})! }
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath(); let steps = 360
    for i in 0...steps {
        let t = CGFloat(i)/CGFloat(steps)*2 * .pi; let c = cos(t), s = sin(t)
        let x = r.midX + r.width/2*(c<0 ? -1:1)*pow(abs(c),2/n)
        let y = r.midY + r.height/2*(s<0 ? -1:1)*pow(abs(s),2/n)
        i==0 ? p.move(to: CGPoint(x:x,y:y)) : p.addLine(to: CGPoint(x:x,y:y))
    }
    p.closeSubpath(); return p
}
func lin(_ c: CGContext,_ g: CGGradient,_ a: CGPoint,_ b: CGPoint) { c.drawLinearGradient(g,start:a,end:b,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation]) }

// Sunrise over water: the horizon bar is a lit key edge, the rays echo the keyboard-brightness glyph,
// the reflection is rows of key-shaped dashes, and the whole square reads as a dusk wallpaper.
func render(_ px: Int) -> CGImage {
    let s = CGFloat(px)/1024
    let small = px <= 32      // drop the reflection, fewer and thicker rays
    let tiny = px <= 16
    let c = CGContext(data:nil,width:px,height:px,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setAllowsAntialiasing(true); c.interpolationQuality = .high
    c.scaleBy(x:s,y:s)
    c.setLineCap(.round)
    let ink = col(255,246,232), amber = col(255,190,110)
    let bp = squircle(CGRect(x:100,y:100,width:824,height:824))
    c.saveGState(); c.setShadow(offset: CGSize(width:0,height:-12*s), blur: 28*s, color: col(0,0,0,0.32))
    c.addPath(bp); c.setFillColor(col(20,22,44)); c.fillPath(); c.restoreGState()

    let hy: CGFloat = small ? 470 : 476
    c.saveGState(); c.addPath(bp); c.clip()
    // sky
    lin(c, grad([(0,col(0xF0,0xA4,0x70)),(0.18,col(0x9C,0x5C,0x68)),(0.52,col(0x3A,0x2C,0x56)),(1,col(0x14,0x16,0x2C))]), CGPoint(x:512,y:hy), CGPoint(x:512,y:924))
    // water: fades in over 70 px below the horizon, so there is no hard full-width line
    c.saveGState(); c.clip(to: CGRect(x:0,y:0,width:1024,height:hy))
    lin(c, grad([(0,col(0x7A,0x4E,0x5E)),(0.12,col(0x34,0x26,0x42)),(0.5,col(0x18,0x16,0x2A)),(1,col(0x0C,0x0C,0x16))]), CGPoint(x:512,y:hy), CGPoint(x:512,y:100))
    c.restoreGState()
    let sun = CGPoint(x:512,y:hy)
    c.drawRadialGradient(grad([(0,col(255,214,150,0.50)),(0.45,col(255,190,120,0.14)),(1,col(255,190,120,0))]), startCenter:sun, startRadius:0, endCenter:sun, endRadius:200, options:[])

    // rays
    let lens: [CGFloat] = tiny ? [180] : (small ? [90, 120, 150, 120, 90] : [56, 100, 78, 136, 78, 100, 56])
    let rw: CGFloat = tiny ? 80 : (small ? 50 : 32)
    let inner: CGFloat = tiny ? 120 : 130
    let n = lens.count
    for i in 0..<n {
        let a = n == 1 ? CGFloat.pi / 2 : CGFloat.pi * (0.17 + 0.66 * CGFloat(i)/CGFloat(n-1))
        let p0 = CGPoint(x: sun.x + cos(a)*inner, y: sun.y + sin(a)*inner)
        let p1 = CGPoint(x: sun.x + cos(a)*(inner+lens[i]), y: sun.y + sin(a)*(inner+lens[i]))
        let l = CGMutablePath(); l.move(to: p0); l.addLine(to: p1)
        c.saveGState(); c.addPath(l.copy(strokingWithWidth: rw, lineCap: .round, lineJoin: .round, miterLimit: 1)); c.clip()
        c.drawLinearGradient(grad([(0,ink),(1,amber)]), start: p0, end: p1, options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
        c.restoreGState()
    }
    // horizon bar = lit key edge
    let bh: CGFloat = small ? 175 : 160, bt: CGFloat = tiny ? 84 : (small ? 60 : 34)
    let bar = CGRect(x: 512-bh, y: hy-bt/2, width: 2*bh, height: bt)
    c.addPath(CGPath(roundedRect: bar, cornerWidth: small ? bt/2 : 11, cornerHeight: small ? bt/2 : 11, transform: nil)); c.setFillColor(ink); c.fillPath()

    // reflection: rows of key-shaped dashes on a soft wave
    if !small {
        let rows: [(n: Int, w: CGFloat, y: CGFloat, a: CGFloat)] = [(4, 70, hy - 84, 0.85), (3, 62, hy - 152, 0.65), (2, 54, hy - 216, 0.50)]
        for (ri, r) in rows.enumerated() {
            let gap: CGFloat = 16, total = CGFloat(r.n) * r.w + CGFloat(r.n - 1) * gap
            for i in 0..<r.n {
                let x0 = 512 - total/2 + CGFloat(i) * (r.w + gap)
                let dy = 6 * sin(CGFloat(i) * 1.6 + CGFloat(ri))
                let rect = CGRect(x: x0, y: r.y + dy - 14, width: r.w, height: 28)
                c.addPath(CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil)); c.setFillColor(col(255,214,160,r.a)); c.fillPath()
            }
        }
    }
    c.restoreGState()
    // 1 px rim
    c.saveGState(); c.addPath(bp); c.setStrokeColor(col(255,255,255,0.10)); c.setLineWidth(3); c.strokePath(); c.restoreGState()
    return c.makeImage()!
}
func save(_ img: CGImage,_ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
var cache: [Int: CGImage] = [:]
for px in [16,32,64,128,256,512,1024] { cache[px] = render(px) }
let map: [(String, Int)] = [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)]
for (name, px) in map { save(cache[px]!, "\(set)/icon_\(name).png") }
save(cache[1024]!, out + "/icon-1024.png")
