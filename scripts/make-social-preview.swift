// GitHub 대표 이미지(social preview, 1280x640) 생성
// 사용: swift scripts/make-social-preview.swift   ->  docs/social-preview.png
import AppKit

let W = 1280, H = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 배경: 어두운 남색 + 왼쪽 위에 아이콘 초록을 옅게
NSColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()
NSGradient(starting: NSColor(red: 0.18, green: 0.90, blue: 0.65, alpha: 0.22), ending: .clear)!
    .draw(fromCenter: NSPoint(x: 160, y: 560), radius: 0, toCenter: NSPoint(x: 160, y: 560), radius: 620, options: [])

// 오른쪽: 점검 결과 화면(예시 데이터). 0.72배로 놓고 오른쪽·아래는 화면 밖으로 흘려 글자가 읽히게 한다
let img = NSImage(contentsOfFile: "docs/screenshots/main.png")!
let scale: CGFloat = 0.72
let px = img.representations.first!
let shot = NSRect(x: 600, y: 570 - CGFloat(px.pixelsHigh) * scale,
                  width: CGFloat(px.pixelsWide) * scale, height: CGFloat(px.pixelsHigh) * scale)
let clip = NSBezierPath(roundedRect: shot, xRadius: 16, yRadius: 16)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(white: 0.12, alpha: 1).setFill()
clip.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
clip.addClip()
img.draw(in: shot)
NSGraphicsContext.restoreGraphicsState()
NSColor(white: 1, alpha: 0.14).setStroke()
clip.lineWidth = 1
clip.stroke()

// 왼쪽: 아이콘, 이름, 소개
NSImage(contentsOfFile: "docs/icon.png")!.draw(in: NSRect(x: 48, y: 388, width: 200, height: 200))

func text(_ s: String, _ font: NSFont, _ color: NSColor, _ rect: NSRect) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 6
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        .draw(with: rect, options: [.usesLineFragmentOrigin])
}
text("치지직 점검", .systemFont(ofSize: 76, weight: .bold), .white, NSRect(x: 72, y: 290, width: 520, height: 100))
text("방송 시청자수와 채팅 흐름을\n한 번에 점검하는 맥 앱", .systemFont(ofSize: 32, weight: .semibold),
     NSColor(white: 0.92, alpha: 1), NSRect(x: 72, y: 180, width: 520, height: 100))
text("Check a CHZZK broadcast in one click.", .systemFont(ofSize: 22, weight: .regular),
     NSColor(white: 0.62, alpha: 1), NSRect(x: 72, y: 130, width: 520, height: 34))
text("macOS 14+  ·  Apple Silicon  ·  MIT  ·  Node.js", .systemFont(ofSize: 20, weight: .medium),
     NSColor(red: 0.18, green: 0.90, blue: 0.65, alpha: 1), NSRect(x: 72, y: 60, width: 520, height: 30))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/social-preview.png"))
print("docs/social-preview.png")
