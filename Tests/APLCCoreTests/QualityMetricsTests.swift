import XCTest
@testable import APLCCore

final class QualityMetricsTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUpWithError() throws { temp = try TempDirectory() }
    override func tearDown() { temp = nil }

    func testIdenticalImagesScorePerfectly() throws {
        let a = try TestImages.writeJPEG(at: temp.file("a.jpg"))
        let b = temp.file("b.jpg")
        try FileManager.default.copyItem(at: a, to: b)

        let score = try QualityMetrics.compare(a, b)
        XCTAssertEqual(score.ssim, 1.0, accuracy: 1e-9)
        XCTAssertFalse(score.psnr.isFinite, "identical images have no error, so PSNR is infinite")
    }

    func testHeavierCompressionScoresWorse() throws {
        let source = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 800, height: 600)

        let coarse = temp.file("coarse.heic")
        let fine = temp.file("fine.heic")
        _ = try Transcoder(quality: 0.3).transcode(source: source, destination: coarse)
        _ = try Transcoder(quality: 0.9).transcode(source: source, destination: fine)

        let coarseScore = try QualityMetrics.compare(source, coarse)
        let fineScore = try QualityMetrics.compare(source, fine)

        XCTAssertLessThan(coarseScore.ssim, fineScore.ssim)
        XCTAssertLessThan(coarseScore.psnr, fineScore.psnr)
    }

    func testMismatchedDimensionsThrow() throws {
        let a = try TestImages.writeJPEG(at: temp.file("a.jpg"), width: 640, height: 480)
        let b = try TestImages.writeJPEG(at: temp.file("b.jpg"), width: 320, height: 240)
        XCTAssertThrowsError(try QualityMetrics.compare(a, b)) { error in
            guard case QualityMetricsError.dimensionMismatch = error else {
                return XCTFail("expected a dimension mismatch, got \(error)")
            }
        }
    }

    // MARK: - Box blur

    func testBlurOfConstantPlaneIsUnchanged() {
        let w = 40, h = 30
        var plane = [Float](repeating: 0.42, count: w * h)
        var scratch = [Float](repeating: 0, count: w * h)

        QualityMetrics.boxBlur(&plane, &scratch, width: w, height: h, radius: 5)

        // Edge replication means even border pixels see only 0.42.
        for value in plane {
            XCTAssertEqual(value, 0.42, accuracy: 1e-5)
        }
    }

    func testBlurMatchesADirectClampedAverage() {
        let w = 17, h = 13, r = 3
        var plane = (0..<(w * h)).map { Float($0 % 7) / 7.0 }
        let original = plane
        var scratch = [Float](repeating: 0, count: w * h)

        QualityMetrics.boxBlur(&plane, &scratch, width: w, height: h, radius: r)

        // Independent O(k²) reference implementation of the same definition.
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0
                for dy in -r...r {
                    for dx in -r...r {
                        let sy = min(max(y + dy, 0), h - 1)
                        let sx = min(max(x + dx, 0), w - 1)
                        sum += Double(original[sy * w + sx])
                    }
                }
                let expected = Float(sum / Double((2 * r + 1) * (2 * r + 1)))
                XCTAssertEqual(plane[y * w + x], expected, accuracy: 1e-4,
                               "mismatch at (\(x), \(y))")
            }
        }
    }

    /// The strip-with-halo scheme must give the same answer as a single pass;
    /// otherwise the SSIM figures would depend on image height.
    func testStripedSSIMMatchesWholeImageSSIM() {
        let w = 64
        let h = QualityMetrics.stripHeight * 2 + 37  // spans several strips unevenly
        var a = [Float](repeating: 0, count: w * h)
        var b = [Float](repeating: 0, count: w * h)
        var seed: UInt64 = 12345
        for i in 0..<(w * h) {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            a[i] = Float(seed % 1000) / 1000.0
            b[i] = min(max(a[i] + Float((seed >> 32) % 50) / 1000.0 - 0.025, 0), 1)
        }

        let striped = QualityMetrics.meanSSIM(a, b, width: w, height: h, radius: 5)
        // The same computation forced into one pass over the whole image.
        let single = QualityMetrics.meanSSIM(a, b, width: w, height: h, radius: 5, stripRows: h)

        XCTAssertEqual(striped, single, accuracy: 1e-9)
    }
}
