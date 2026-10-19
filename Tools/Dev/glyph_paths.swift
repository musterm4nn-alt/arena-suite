// glyph_paths.swift <font> <text> <pointSize> <centerX> <centerY>
// Prints SVG path data for the text set in the font, its ink box centred on (centerX, centerY) of a
// y-down canvas. Used by make_app_icon.py to draw Departure Mono letters into the app icon.
import CoreText
import Foundation
let a = CommandLine.arguments
let desc = (CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: a[1]) as CFURL) as! [CTFontDescriptor])[0]
let font = CTFontCreateWithFontDescriptor(desc, CGFloat(Double(a[3])!), nil)
let line = CTLineCreateWithAttributedString(NSAttributedString(string: a[2], attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
let path = CGMutablePath()
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let n = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: n), positions = [CGPoint](repeating: .zero, count: n)
    CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
    for i in 0..<n {
        if let g = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
            path.addPath(g, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
        }
    }
}
let box = path.boundingBoxOfPath
let cx = Double(a[4])!, cy = Double(a[5])!
// flip y and center the ink box
func p(_ pt: CGPoint) -> String { String(format: "%.1f,%.1f", pt.x - box.midX + cx, -(pt.y - box.midY) + cy) }
var d = ""
path.applyWithBlock { e in
    let el = e.pointee
    switch el.type {
    case .moveToPoint: d += "M" + p(el.points[0])
    case .addLineToPoint: d += "L" + p(el.points[0])
    case .addQuadCurveToPoint: d += "Q" + p(el.points[0]) + " " + p(el.points[1])
    case .addCurveToPoint: d += "C" + p(el.points[0]) + " " + p(el.points[1]) + " " + p(el.points[2])
    case .closeSubpath: d += "Z"
    @unknown default: break
    }
}
print(d)
FileHandle.standardError.write("ink \(box.width)x\(box.height)\n".data(using: .utf8)!)
