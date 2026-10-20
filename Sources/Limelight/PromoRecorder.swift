import AppKit
import AVFoundation
import CoreImage
import LimelightCore

/// Renders the promo video from the real panel, driven through a scripted session.
/// Runs on sample files and sample clipboard entries, so nothing personal ends up on screen.
/// The window server draws the real glass, so the frosted backdrop here is composited by hand.
/// Started with LIMELIGHT_PROMO=/path/out.mp4.
final class PromoRecorder {
    private let size = CGSize(width: 1920, height: 1080)
    private let fps: Int32 = 30
    private let output: URL
    private let controller: SearchController
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor!
    private var frameIndex: Int64 = 0
    private var background: CGImage!
    private var frosted: CGImage!
    private let lime = NSColor(red: 0.78, green: 0.96, blue: 0.20, alpha: 1)

    // Scene state.
    private var panelAlpha: CGFloat = 0
    private var caption: String?
    private var captionAlpha: CGFloat = 0
    private var keycap: String?
    private var keycapAlpha: CGFloat = 0
    private var caretVisible = true

    init(output: URL, catalog: [CatalogItem]) {
        self.output = output
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("limelight-promo-home")
        Self.makeDemoHome(temp)
        // The index stores real paths (/private/var/…), so "home" must match for paths to read as ~/….
        let home = URL(fileURLWithPath: FileIndex.realPath(temp.path))
        let index = FileIndex(config: IndexConfig(roots: [home.path], excludedPaths: [], excludedNames: [], includeHidden: false), home: home.path)
        index.rebuild()
        index.waitUntilIdle()
        let engine = SearchEngine(files: index, frecency: Frecency(file: nil), home: home.path)
        engine.catalog = catalog
        let now = Date()
        engine.clipboard.add("Lunch at 12:30? The usual place", source: "Messages", date: now.addingTimeInterval(-3 * 3600))
        engine.clipboard.add("~/Documents/Work/Q3 Report.pdf", source: "Finder", date: now.addingTimeInterval(-50 * 60))
        engine.clipboard.add("Meeting moved to 3:30, same room", source: "Slack", date: now.addingTimeInterval(-14 * 60))
        engine.clipboard.add("https://github.com/devouswitz/limelight", source: "Safari", date: now.addingTimeInterval(-2 * 60))
        controller = SearchController(engine: engine)
    }

    func run() throws {
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        makeBackground()
        controller.promoPrepare()
        controller.promoSet(query: "", mode: .all)
        settle(0.5)

        script()

        input.markAsFinished()
        var done = false
        writer.finishWriting { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    // MARK: - Script

    private func script() {
        intro()

        showKeycap("⌘ Space")
        animate(9) { t in self.panelAlpha = t }
        hold(12)
        scene("Apps, ranked by what you actually use", type: "saf", hold: 60)
        scene("Its own file index. Nothing goes missing.", type: "q3 report", hold: 60)
        settle(1.0)
        hold(10)
        controller.promoMove(2)
        settle(1.0)
        hold(40)
        scene("Math and unit conversion", type: "5 km to mi", hold: 60)
        scene("Settings and actions by what they do", type: "dark mode", hold: 60)
        scene("Definitions, offline", type: "serendipity", hold: 60)

        clearQuery()
        showKeycap("⌘4")
        setCaption("Clipboard history")
        controller.promoSet(query: "", mode: .clipboard)
        settle(0.3)
        hold(30)
        for _ in 0..<2 { controller.promoMove(1); settle(0.1); hold(14) }
        hold(30)
        hideKeycap()
        animate(10) { t in
            self.panelAlpha = 1 - t
            self.captionAlpha = 1 - t
        }
        outro()
    }

    private func scene(_ text: String, type query: String, hold frames: Int) {
        clearQuery()
        if keycap != nil { hideKeycap() }
        setCaption(text)
        type(query)
        settle(0.4)
        hold(frames)
    }

    private func type(_ query: String) {
        var typed = ""
        for ch in query {
            typed.append(ch)
            controller.promoSet(query: typed, mode: .all)
            settle(0.05)
            hold(3)
        }
    }

    private func clearQuery() {
        controller.promoSet(query: "", mode: .all)
        settle(0.05)
        hold(6)
    }

    private func setCaption(_ text: String) {
        if caption != nil { animate(5) { t in self.captionAlpha = 1 - t } }
        caption = text
        animate(8) { t in self.captionAlpha = t }
    }

    private func showKeycap(_ text: String) {
        keycap = text
        animate(6) { t in self.keycapAlpha = t }
    }

    private func hideKeycap() {
        animate(6) { t in self.keycapAlpha = 1 - t }
        keycap = nil
    }

    // MARK: - Title cards

    private func intro() {
        for i in 0..<84 {
            let t = CGFloat(i)
            emit { ctx in
                self.drawTitleCard(ctx, iconT: Self.ease(min(1, t / 18)), titleT: Self.ease(min(1, max(0, (t - 8) / 16))),
                                   lineT: Self.ease(min(1, max(0, (t - 22) / 16))), fadeOut: Self.ease(min(1, max(0, (t - 70) / 14))),
                                   lines: [("Spotlight search but it actually works", 46, NSColor.white.withAlphaComponent(0.82))])
            }
        }
    }

    private func outro() {
        for i in 0..<105 {
            let t = CGFloat(i)
            emit { ctx in
                self.drawTitleCard(ctx, iconT: Self.ease(min(1, t / 14)), titleT: Self.ease(min(1, max(0, (t - 6) / 14))),
                                   lineT: Self.ease(min(1, max(0, (t - 16) / 14))), fadeOut: 0,
                                   lines: [("Free forever", 56, self.lime),
                                           ("github.com/devouswitz/limelight", 36, NSColor.white.withAlphaComponent(0.75))])
            }
        }
    }

    private func drawTitleCard(_ ctx: CGContext, iconT: CGFloat, titleT: CGFloat, lineT: CGFloat, fadeOut: CGFloat,
                               lines: [(String, CGFloat, NSColor)]) {
        ctx.setAlpha(1 - fadeOut)
        let icon = NSApp.applicationIconImage!
        let side: CGFloat = 230 * (0.9 + 0.1 * iconT)
        let iconRect = CGRect(x: size.width / 2 - side / 2, y: 610 - (side - 230) / 2, width: side, height: side)
        withNSContext(ctx) {
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: iconT)
            self.drawCentered("Limelight", y: 470 + 12 * (1 - titleT), size: 108, weight: .bold, color: NSColor.white.withAlphaComponent(titleT))
            var y: CGFloat = 395
            for (text, size, color) in lines {
                self.drawCentered(text, y: y + 10 * (1 - lineT), size: size, weight: .medium, color: color.withAlphaComponent(color.alphaComponent * lineT))
                y -= size + 26
            }
        }
        ctx.setAlpha(1)
    }

    // MARK: - Frames

    private func hold(_ frames: Int) {
        for _ in 0..<frames { emit(nil) }
    }

    private func animate(_ frames: Int, _ step: @escaping (CGFloat) -> Void) {
        for i in 1...frames {
            step(Self.ease(CGFloat(i) / CGFloat(frames)))
            emit(nil)
        }
    }

    /// Lets Quick Look and layout finish their asynchronous work between frames.
    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func emit(_ custom: ((CGContext) -> Void)?) {
        while !input.isReadyForMoreMediaData { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let pb = buffer else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(background, in: CGRect(origin: .zero, size: size))
        if let custom {
            custom(ctx)
        } else {
            drawPanel(ctx)
            drawOverlays(ctx)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: frameIndex, timescale: fps))
        frameIndex += 1
    }

    private func drawPanel(_ ctx: CGContext) {
        guard panelAlpha > 0, let (rep, caret) = controller.promoRender(), let image = rep.cgImage else { return }
        // As large as fits between the key hint and the caption, so it reads on a phone.
        let scale = min(1.9, (size.height - 110 - 170) / rep.size.height)
        let w = rep.size.width * scale, h = rep.size.height * scale
        let pop = 0.97 + 0.03 * panelAlpha
        let rect = CGRect(x: (size.width - w * pop) / 2, y: size.height - 120 - h * pop, width: w * pop, height: h * pop)
        let radius = 26 * scale * pop
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setAlpha(panelAlpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(frosted, in: CGRect(origin: .zero, size: size))
        ctx.setFillColor(NSColor(white: 0.09, alpha: 0.58).cgColor)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        if caretVisible && (frameIndex / 16) % 2 == 0 {
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fill(CGRect(x: rect.minX + caret.minX * scale * pop, y: rect.minY + caret.minY * scale * pop,
                            width: 3, height: caret.height * scale * pop))
        }
        ctx.restoreGState()

        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func drawOverlays(_ ctx: CGContext) {
        withNSContext(ctx) {
            if let caption = self.caption, self.captionAlpha > 0 {
                self.drawCentered(caption, y: 64, size: 44, weight: .semibold, color: NSColor.white.withAlphaComponent(self.captionAlpha))
            }
            if let keycap = self.keycap, self.keycapAlpha > 0 {
                let font = NSFont.systemFont(ofSize: 30, weight: .semibold)
                let text = NSAttributedString(string: keycap, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(self.keycapAlpha)])
                let ts = text.size()
                let pill = NSRect(x: self.size.width / 2 - ts.width / 2 - 22, y: self.size.height - 100, width: ts.width + 44, height: 58)
                NSColor.white.withAlphaComponent(0.12 * self.keycapAlpha).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 14, yRadius: 14).fill()
                NSColor.white.withAlphaComponent(0.25 * self.keycapAlpha).setStroke()
                NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14).stroke()
                text.draw(at: NSPoint(x: pill.midX - ts.width / 2, y: pill.midY - ts.height / 2))
            }
        }
    }

    // MARK: - Drawing helpers

    private func withNSContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCentered(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let w = s.size().width
        s.draw(at: NSPoint(x: self.size.width / 2 - w / 2, y: y))
    }

    static func ease(_ t: CGFloat) -> CGFloat { 1 - pow(1 - max(0, min(1, t)), 3) }

    /// Dark backdrop with soft color fields, so the frosted panel has something to blur.
    private func makeBackground() {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        let base = CGGradient(colorsSpace: space, colors: [
            NSColor(red: 0.07, green: 0.09, blue: 0.07, alpha: 1).cgColor,
            NSColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        func glow(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: NSColor) {
            let g = CGGradient(colorsSpace: space, colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
        }
        glow(960, 1150, 900, lime.withAlphaComponent(0.22))
        glow(250, 250, 700, NSColor(red: 0.10, green: 0.55, blue: 0.55, alpha: 0.18))
        glow(1700, 300, 650, NSColor(red: 0.45, green: 0.30, blue: 0.85, alpha: 0.16))
        glow(1500, 900, 420, lime.withAlphaComponent(0.10))
        background = ctx.makeImage()!

        let ci = CIImage(cgImage: background)
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 40).cropped(to: ci.extent)
        frosted = CIContext().createCGImage(blurred, from: ci.extent)!
    }

    // MARK: - Demo files

    static func makeDemoHome(_ home: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: home)
        let work = home.appendingPathComponent("Documents/Work")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? fm.createDirectory(at: home.appendingPathComponent("Desktop/Q3 Assets"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: home.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        makeReportPDF(work.appendingPathComponent("Q3 Report.pdf"), draft: false)
        makeReportPDF(home.appendingPathComponent("Downloads/Q3 Report (draft).pdf"), draft: true)
        try? "# Q3 report notes\n\n- Revenue up 18%\n- Ship onboarding v2\n- Hiring: 2 engineers\n".write(
            to: work.appendingPathComponent("Q3 Report Notes.md"), atomically: true, encoding: .utf8)
        try? "month,revenue\nJul,412\nAug,455\nSep,486\n".write(
            to: work.appendingPathComponent("Q3 Revenue.csv"), atomically: true, encoding: .utf8)
    }

    static func makeReportPDF(_ url: URL, draft: Bool) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(box)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let title = draft ? "Q3 Report — Draft" : "Q3 Report"
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: 56, y: 700))
        NSAttributedString(string: "Revenue by month, in thousands", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray])
            .draw(at: NSPoint(x: 56, y: 672))
        let values: [CGFloat] = [412, 455, 486]
        for (i, v) in values.enumerated() {
            let bar = CGRect(x: 80 + CGFloat(i) * 150, y: 380, width: 90, height: v * 0.55)
            NSColor(red: 0.45, green: 0.62, blue: 0.10, alpha: 1).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
            NSAttributedString(string: ["Jul", "Aug", "Sep"][i], attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray])
                .draw(at: NSPoint(x: bar.minX + 30, y: 356))
        }
        for line in 0..<6 {
            NSColor(white: 0.85, alpha: 1).setFill()
            NSRect(x: 56, y: 300 - CGFloat(line) * 26, width: line == 5 ? 300 : 500, height: 10).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
