//
//  make-icon.swift — 生成 TNT go Touchpad 的应用图标
//
//  运行: swift make-icon.swift
//  输出: icon_1024.png(再由 build.sh 转成 icns)
//
//  设计:TNT go 的黑底白字风格,"TNT" 白色 + "go" 锤科红,配触摸板轮廓。
//

import AppKit

let S: CGFloat = 1024

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// 背景圆角矩形(macOS 图标规范:圆角自带,外部透明)
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S), xRadius: 232, yRadius: 232)
bg.addClip()
NSGradient(starting: NSColor(calibratedWhite: 0.16, alpha: 1),
           ending: NSColor(calibratedWhite: 0.07, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: S, height: S), angle: -90)

// 顶部一道微光,增加质感
let glow = NSGradient(starting: NSColor.white.withAlphaComponent(0.07),
                      ending: NSColor.white.withAlphaComponent(0.0))!
glow.draw(in: NSRect(x: 0, y: S * 0.72, width: S, height: S * 0.28), angle: -90)

// 触摸板轮廓(圆角矩形描边 + 顶部隔断线,经典触摸板图形)
let padStroke = NSColor.white.withAlphaComponent(0.92)
let padRect = NSRect(x: 272, y: 452, width: 480, height: 336)
let pad = NSBezierPath(roundedRect: padRect, xRadius: 58, yRadius: 58)
pad.lineWidth = 20
padStroke.setStroke()
pad.stroke()

let divider = NSBezierPath()
divider.move(to: NSPoint(x: padRect.minX, y: padRect.maxY - 78))
divider.line(to: NSPoint(x: padRect.maxX, y: padRect.maxY - 78))
divider.lineWidth = 20
divider.lineCapStyle = .butt
padStroke.setStroke()
divider.stroke()

// 字标:白色 "TNT" + 红色 " go"
let fontSize: CGFloat = 168
let style = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
style.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
    .paragraphStyle: style,
]
let title = NSMutableAttributedString(string: "TNT ", attributes: attrs)
title.append(NSAttributedString(string: "go", attributes: attrs.merging([
    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.90, green: 0.22, blue: 0.19, alpha: 1),
]) { _, new in new }))
title.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: 4))

let titleSize = title.size()
title.draw(in: NSRect(x: (S - titleSize.width) / 2, y: 148, width: titleSize.width + 8, height: titleSize.height + 8))

img.unlockFocus()

// 写出 PNG
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 编码失败")
}
try png.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("✓ icon_1024.png 已生成")
