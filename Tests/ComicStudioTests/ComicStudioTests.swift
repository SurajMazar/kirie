import CoreGraphics
import Foundation
import MediaServices
import ProjectDomain
import Testing
@testable import ComicStudio

func comicScratch(_ name: String = #function) throws -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kirie-comic-\(safe)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func close(_ a: UnitRect, _ b: UnitRect, tolerance: Double = 0.012) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
}

@Suite("Panel detection")
struct PanelDetectionTests {
    @Test func findsUnequalPanelsInReadingOrder() throws {
        let root = try comicScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("strip.png")
        let truth = try SampleMedia.writeComicStrip(to: url)
        let detection = try PanelDetector.detect(url: url)
        #expect(detection.panels.count == truth.count)
        for (found, expected) in zip(detection.panels, truth) {
            #expect(close(found, expected), "found \(found), expected \(expected)")
        }
        // Not a grid: the two middle panels have different widths, and that is measured, not assumed.
        #expect(abs(detection.panels[1].width - 0.40) < 0.012 && abs(detection.panels[2].width - 0.48) < 0.012)
        #expect(abs(detection.paper.r - 0.957) < 0.03 && abs(detection.paper.b - 0.859) < 0.03)
    }

    @Test func handlesOtherLayoutsAndMangaOrder() throws {
        let root = try comicScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // Rows at heights that match no template, and three unequal columns in the middle row.
        let layout = [
            UnitRect(x: 0.05, y: 0.04, width: 0.55, height: 0.19), UnitRect(x: 0.64, y: 0.04, width: 0.31, height: 0.19),
            UnitRect(x: 0.05, y: 0.27, width: 0.2, height: 0.41), UnitRect(x: 0.29, y: 0.27, width: 0.36, height: 0.41),
            UnitRect(x: 0.69, y: 0.27, width: 0.26, height: 0.41), UnitRect(x: 0.05, y: 0.72, width: 0.9, height: 0.24),
        ]
        let url = root.appendingPathComponent("six.png")
        try SampleMedia.writeComicStrip(to: url, width: 1200, height: 1500, layout: layout, paper: .white)
        let detection = try PanelDetector.detect(url: url)
        #expect(detection.panels.count == 6)
        for (found, expected) in zip(detection.panels, layout) { #expect(close(found, expected), "found \(found), expected \(expected)") }

        var manga = PanelDetector.Options()
        manga.rightToLeft = true
        let reversed = try PanelDetector.detect(url: url, options: manga)
        #expect(close(reversed.panels[0], layout[1]) && close(reversed.panels[1], layout[0]), "top row reads right to left")
        #expect(close(reversed.panels[2], layout[4]) && close(reversed.panels[4], layout[2]))
        #expect(close(reversed.panels[5], layout[5]))
    }

    @Test(arguments: 2...5)
    func detectsBorderedPanelsWithPageColouredInsides(count: Int) throws {
        // Wireframes are outline-only: the inside of each panel is the same white as the gutters.
        let wireframe = try #require(ComicSheets.wireframe(panelCount: count))
        let detection = PanelDetector.detect(wireframe.image)
        #expect(detection.panels.count == count, "wireframe with \(count) panels gave \(detection.panels.count)")
        for (found, expected) in zip(detection.panels, wireframe.panels) { #expect(close(found, expected, tolerance: 0.015)) }
        #expect(wireframe.description.contains("Panel \(count):"))
        #expect(ComicSheets.wireframe(panelCount: 9) == nil)
    }

    @Test func toleratesSpecksAndIgnoresEmptyPages() throws {
        let truth = [UnitRect(x: 0.05, y: 0.05, width: 0.9, height: 0.4), UnitRect(x: 0.05, y: 0.55, width: 0.9, height: 0.4)]
        let context = try #require(SampleMedia.makeContext(width: 800, height: 1000))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        for panel in truth {
            context.fill(CGRect(x: panel.x * 800, y: (1 - panel.maxY) * 1000, width: panel.width * 800, height: panel.height * 1000))
        }
        // A scanner speck in the gutter must not glue the two panels together.
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 400, y: 500, width: 2, height: 2))
        let detection = PanelDetector.detect(try #require(context.makeImage()))
        #expect(detection.panels.count == 2)
        for (found, expected) in zip(detection.panels, truth) { #expect(close(found, expected)) }

        let blank = try #require(SampleMedia.makeContext(width: 400, height: 600))
        blank.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        blank.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(PanelDetector.detect(try #require(blank.makeImage())).panels.isEmpty)
    }

    @Test func findsWhatMustStayInFrame() throws {
        let root = try comicScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("strip.png")
        let truth = try SampleMedia.writeComicStrip(to: url)
        let image = try Thumbnailer.loadImage(url)
        let analysis = SubjectFinder.analyse(image)
        #expect(analysis.panels.count == truth.count)
        // Panel 1's figure is drawn at 35% across; panel 2's at 62%. The content bounds follow them.
        let first = try #require(analysis.panels[0].subject), second = try #require(analysis.panels[1].subject)
        #expect(first.x < 0.36 && first.maxX > 0.36, "figure of panel 1 is inside its bounds: \(first)")
        #expect(second.x < 0.62 && second.maxX > 0.62, "figure of panel 2 is inside its bounds: \(second)")
        #expect(first.height > 0.3 && first.height < 0.95)
        // The numeral in the top-right corner counts as content too, so the bounds reach it.
        #expect(first.maxX > 0.85)
        #expect(SubjectFinder.contentBounds(in: image, panel: UnitRect(x: 0, y: 0, width: 0.001, height: 0.001)) == nil)
    }
}

@Suite("Review sheets and image exports")
struct SheetTests {
    static func strip() throws -> (CGImage, [ComicPanel], URL) {
        let root = try comicScratch("sheet\(UUID().uuidString.prefix(4))")
        let url = root.appendingPathComponent("strip.png")
        let truth = try SampleMedia.writeComicStrip(to: url)
        let panels = truth.enumerated().map { index, rect in
            ComicPanel(rect: rect, review: PanelReview(status: index == 1 ? .fail : .pass, strangerNote: "note"))
        }
        return (try Thumbnailer.loadImage(url), panels, root)
    }

    @Test func contactSheetShowsEveryPanel() throws {
        let (image, panels, root) = try Self.strip()
        defer { try? FileManager.default.removeItem(at: root) }
        let sheet = try #require(ComicSheets.contactSheet(image, panels: panels, columns: 2, cell: 300))
        #expect(sheet.width == 2 * 300 + 3 * 24)
        #expect(sheet.height == 2 * (300 + 44) + 3 * 24)
        #expect(ComicSheets.contactSheet(image, panels: []) == nil)
        let zoom = try #require(ComicSheets.panelZoom(image, panel: panels[1].rect))
        #expect(abs(Double(zoom.width) - 0.40 * 1024) < 3 && abs(Double(zoom.height) - 0.30 * 1536) < 3)
    }

    @Test func continuitySheetUsesOneScale() throws {
        let (image, _, root) = try Self.strip()
        defer { try? FileManager.default.removeItem(at: root) }
        // A tall region and one half as tall: the second must be drawn half as tall, not stretched.
        let regions = [UnitRect(x: 0.1, y: 0.05, width: 0.2, height: 0.2), UnitRect(x: 0.1, y: 0.4, width: 0.3, height: 0.1)]
        let sheet = try #require(ComicSheets.continuitySheet(image, regions: regions, height: 400))
        let scale = 400.0 / (0.2 * 1536)
        let expectedWidth = (0.2 * 1024 + 0.3 * 1024) * scale + 20 * 3
        #expect(abs(Double(sheet.width) - expectedWidth) < 4)
        #expect(sheet.height == 440)
        #expect(ComicSheets.continuitySheet(image, regions: []) == nil)
    }

    @Test func carouselSlidesAreFeedSizedAndOrdered() throws {
        let (image, panels, root) = try Self.strip()
        defer { try? FileManager.default.removeItem(at: root) }
        let slides = CarouselExporter.slides(image, panels: panels.map(\.rect), paper: .paper)
        #expect(slides.count == 5, "four panels plus the full strip")
        #expect(slides.allSatisfy { $0.width == 1080 && $0.height == 1350 })
        let urls = try CarouselExporter.write(slides, to: root.appendingPathComponent("carousel"))
        #expect(urls.map(\.lastPathComponent) == ["01.png", "02.png", "03.png", "04.png", "05.png"])
        #expect(CarouselExporter.slides(image, panels: panels.map(\.rect), paper: .paper, includeFullStrip: false).count == 4)

        // Safe margins: the outer 4% of every slide is untouched page colour.
        let slide = slides[0]
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(slide, in: CGRect(x: -20, y: -20, width: 1080, height: 1350))
        #expect(abs(Double(pixel[0]) / 255 - 0.957) < 0.03 && abs(Double(pixel[2]) / 255 - 0.859) < 0.03)
    }
}
