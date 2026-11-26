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

func render(_ px: Int) -> CGImage {
    let s = CGFloat(px)/1024
    let small = px <= 32      // simplified detail
    let tiny = px <= 16
    let c = CGContext(data:nil,width:px,height:px,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setAllowsAntialiasing(true); c.interpolationQuality = .high
    c.scaleBy(x:s,y:s)
    func shadow(_ dy: CGFloat,_ blur: CGFloat,_ color: CGColor) { c.setShadow(offset: CGSize(width:0,height:-dy*s), blur: blur*s, color: color) }

    // body (squircle n=5, 824 px)
    let bp = squircle(CGRect(x:100,y:100,width:824,height:824))
    c.saveGState(); shadow(12,28,col(0,0,0,0.32))
    c.addPath(bp); c.setFillColor(col(27,28,32)); c.fillPath(); c.restoreGState()
    c.saveGState(); c.addPath(bp); c.clip()
    lin(c, grad([(0,col(0x1B,0x1C,0x20)),(1,col(0x34,0x36,0x3C))]), CGPoint(x:512,y:100), CGPoint(x:512,y:924))
    lin(c, grad([(0,col(255,255,255,0)),(1,col(255,255,255,0.05))]), CGPoint(x:512,y:560), CGPoint(x:512,y:924))
    c.restoreGState()
    // 1 px aluminium rim at ~18% white
    c.saveGState(); c.addPath(bp); c.clip()
    c.addPath(bp); c.setLineWidth(2/s); c.replacePathWithStrokedPath(); c.clip()
    c.setFillColor(col(255,255,255,0.18)); c.fill(CGRect(x:0,y:0,width:1024,height:1024)); c.restoreGState()

    // cap geometry: half-width 250, 14 px skirt
    let cxm: CGFloat = 512
    let baseR = CGRect(x:262,y:276,width:500,height:480)
    let faceR = CGRect(x:284,y:290,width:456,height:448)   // face sits 14 px above skirt bottom
    let skirt = CGPath(roundedRect: baseR, cornerWidth:112, cornerHeight:112, transform:nil)
    let face = CGPath(roundedRect: faceR, cornerWidth:92, cornerHeight:92, transform:nil)

    // amber under-light spilling below the cap (soft, wide, ~sigma 60)
    if !tiny {
        c.saveGState(); c.addPath(bp); c.clip()
        c.translateBy(x: cxm, y: 262); c.scaleBy(x: 1.45, y: 0.62)
        var stops: [(CGFloat, CGColor)] = []
        for i in 0...8 { let t = CGFloat(i)/8; let a = 0.12*exp(-pow(t*3.0,2)/2*1.0); stops.append((t, col(255,170,60,a))) }
        stops[8].1 = col(255,170,60,0)
        c.drawRadialGradient(grad(stops), startCenter:.zero, startRadius:0, endCenter:.zero, endRadius:240, options:[])
        c.restoreGState()
    }

    // skirt (darker)
    c.saveGState(); shadow(16,30,col(0,0,0,0.55))
    c.addPath(skirt); c.setFillColor(col(8,8,10)); c.fillPath(); c.restoreGState()
    c.saveGState(); c.addPath(skirt); c.clip()
    lin(c, grad([(0,col(10,10,12)),(1,col(34,35,39))]), CGPoint(x:512,y:276), CGPoint(x:512,y:756)); c.restoreGState()
    if !small {
        c.saveGState(); c.addPath(skirt); c.setLineWidth(3); c.replacePathWithStrokedPath(); c.clip()
        lin(c, grad([(0,col(255,255,255,0.04)),(1,col(255,255,255,0.26))]), CGPoint(x:512,y:276), CGPoint(x:512,y:756)); c.restoreGState()
    }
    // face
    c.saveGState(); c.addPath(face); c.clip()
    lin(c, grad([(0,col(30,31,35)),(1,col(0x4A,0x4C,0x53))]), CGPoint(x:512,y:290), CGPoint(x:512,y:738))
    if !small {
        c.drawRadialGradient(grad([(0,col(255,255,255,0.05)),(1,col(255,255,255,0))]), startCenter: CGPoint(x:512,y:600), startRadius:0, endCenter: CGPoint(x:512,y:600), endRadius:290, options:[])
        c.addPath(face); c.setLineWidth(10); c.replacePathWithStrokedPath(); c.clip()
        lin(c, grad([(0,col(0,0,0,0.30)),(1,col(0,0,0,0))]), CGPoint(x:512,y:290), CGPoint(x:512,y:390))
    }
    c.restoreGState()
    if !small {
        c.saveGState(); c.addPath(face); c.setLineWidth(3); c.replacePathWithStrokedPath(); c.clip()
        lin(c, grad([(0,col(255,255,255,0.06)),(1,col(255,255,255,0.36))]), CGPoint(x:512,y:290), CGPoint(x:512,y:738)); c.restoreGState()
    }

    // waveform: wider Gaussian window (+15%), centre peak 65% of 122 px
    let cy: CGFloat = (faceR.midY)
    let amp: CGFloat = tiny ? 120 : (small ? 108 : 79), half: CGFloat = small ? 170 : 188
    let freq: CGFloat = tiny ? 5.6 : (small ? 6.6 : 9.2*175/188)
    let w = CGMutablePath()
    let n = 240
    for i in 0...n {
        let x = 512 - half + 2*half*CGFloat(i)/CGFloat(n)
        let u = (x-512)/half
        let y = cy + amp*exp(-pow(u*2.0,2))*cos(u*freq)
        i==0 ? w.move(to:CGPoint(x:x,y:y)) : w.addLine(to:CGPoint(x:x,y:y))
    }
    // stroke >= 28 px at 1024; 16 px gets >= 2.2 px, 32 px >= 3 px
    var lw: CGFloat = 30
    if tiny { lw = 2.3/s } else if px <= 32 { lw = 2.8/s } else if px <= 64 { lw = 34 }
    func sk(_ extra: CGFloat) -> CGPath { w.copy(strokingWithWidth: lw+extra, lineCap:.round, lineJoin:.round, miterLimit:4) }
    let sp = sk(0)

    if !small {
        // restrained bloom: <10% alpha, <40 px radius
        c.saveGState(); c.addPath(face); c.clip()
        shadow(0,34,col(255,160,50,0.09))
        c.addPath(sp); c.setFillColor(col(255,170,60,0.09)); c.fillPath(); c.restoreGState()
        // engraved groove: lower-lip highlight (1.5 px, amber-tinted 25% white), then dark channel, then 2 px dark inner stroke above
        c.saveGState(); c.addPath(face); c.clip()
        c.translateBy(x:0,y:-1.5)
        c.addPath(sk(7)); c.setFillColor(col(255,235,205,0.25)); c.fillPath(); c.restoreGState()
        c.saveGState(); c.addPath(face); c.clip()
        c.addPath(sk(7)); c.setFillColor(col(6,6,8,0.55)); c.fillPath(); c.restoreGState()
        c.saveGState(); c.addPath(face); c.clip()
        c.translateBy(x:0,y:2)
        c.addPath(sk(7)); c.addPath(sk(3)); // ring of 2 px dark on the upper side
        c.setFillColor(col(0,0,0,0.45)); c.fillPath(using: .evenOdd); c.restoreGState()
    }
    // amber stroke, vertical gradient #FFC76A -> #F2A03A, no hot core
    c.saveGState(); c.addPath(sp); c.clip()
    lin(c, grad([(0,col(0xF2,0xA0,0x3A)),(1,col(0xFF,0xC7,0x6A))]), CGPoint(x:512,y:cy-amp-lw/2), CGPoint(x:512,y:cy+amp+lw/2))
    c.restoreGState()
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
