import Foundation
import Accelerate
import CoreGraphics
import ImageIO

public struct QualityScore: Sendable, Equatable {
    /// Mean structural similarity over the image, 1.0 being identical.
    public let ssim: Double
    /// Peak signal-to-noise ratio in dB; `.infinity` for identical images.
    public let psnr: Double
    public let width: Int
    public let height: Int

    public init(ssim: Double, psnr: Double, width: Int, height: Int) {
        self.ssim = ssim
        self.psnr = psnr
        self.width = width
        self.height = height
    }
}

public enum QualityMetricsError: Error, CustomStringConvertible {
    case cannotDecode(URL)
    case dimensionMismatch(a: (Int, Int), b: (Int, Int))

    public var description: String {
        switch self {
        case .cannotDecode(let u):
            return "cannot decode image for comparison: \(u.path)"
        case .dimensionMismatch(let a, let b):
            return "dimension mismatch: \(a.0)x\(a.1) vs \(b.0)x\(b.1)"
        }
    }
}

public enum QualityMetrics {
    /// Half-width of the SSIM window; 5 gives the conventional 11x11 window.
    public static let defaultRadius = 5

    /// Rows of output computed per pass. Bounds peak memory: a 20 MP image
    /// processed whole would need roughly 700 MB of intermediate float planes,
    /// whereas strips keep it to a few tens of MB.
    static let stripHeight = 256

    public static func compare(
        _ a: URL,
        _ b: URL,
        radius: Int = defaultRadius
    ) throws -> QualityScore {
        let (planeA, w, h) = try luminancePlane(a)
        let (planeB, w2, h2) = try luminancePlane(b)
        guard w == w2, h == h2 else {
            throw QualityMetricsError.dimensionMismatch(a: (w, h), b: (w2, h2))
        }

        let ssim = meanSSIM(planeA, planeB, width: w, height: h, radius: radius)
        let psnr = peakSNR(planeA, planeB)
        return QualityScore(ssim: ssim, psnr: psnr, width: w, height: h)
    }

    // MARK: - Decoding

    /// Decodes an image to a normalised single-channel luminance plane.
    ///
    /// Both sides of a comparison go through the identical path, so any bias the
    /// gray conversion introduces cancels out.
    static func luminancePlane(_ url: URL) throws -> (plane: [Float], width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            throw QualityMetricsError.cannotDecode(url)
        }

        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = bytes.withUnsafeMutableBytes({ buf -> CGContext? in
            CGContext(
                data: buf.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else {
            throw QualityMetricsError.cannotDecode(url)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var plane = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { plane[i] = Float(bytes[i]) / 255.0 }
        return (plane, w, h)
    }

    // MARK: - Metrics

    static func peakSNR(_ a: [Float], _ b: [Float]) -> Double {
        var sum = 0.0
        for i in 0..<a.count {
            let d = Double(a[i] - b[i])
            sum += d * d
        }
        let mse = sum / Double(a.count)
        guard mse > 0 else { return .infinity }
        return 10.0 * log10(1.0 / mse)
    }

    /// Mean SSIM over the whole image, computed strip by strip.
    ///
    /// Each strip carries a `radius`-row halo above and below, so every row that
    /// actually contributes to the mean sees the same neighbourhood it would
    /// have seen in a whole-image pass. The result is exact, not an approximation.
    /// `stripRows` is injectable so tests can prove that a striped run and a
    /// single whole-image pass agree exactly.
    static func meanSSIM(
        _ a: [Float], _ b: [Float],
        width w: Int, height h: Int,
        radius r: Int,
        stripRows: Int = stripHeight
    ) -> Double {
        guard w > 0, h > 0 else { return 1.0 }
        let stripRows = max(1, stripRows)
        // Windows wider than the image degenerate; compare globally instead.
        let radius = min(r, max(0, min(w, h) / 2))

        let c1 = 0.01 * 0.01
        let c2 = 0.03 * 0.03

        var total = 0.0
        var counted = 0

        var strip = 0
        while strip < h {
            let outStart = strip
            let outEnd = min(strip + stripRows, h)
            let inStart = max(0, outStart - radius)
            let inEnd = min(h, outEnd + radius)
            let sh = inEnd - inStart
            let base = inStart * w
            let n = sh * w

            var x = Array(a[base..<(base + n)])
            var y = Array(b[base..<(base + n)])

            // Through vDSP rather than one interleaved loop: measured 5.3x, and
            // the results are bit-identical because a Float multiply is a Float
            // multiply however it is issued. The interleaved version reads x and
            // y three times each and defeats vectorisation.
            var xx = [Float](repeating: 0, count: n)
            var yy = [Float](repeating: 0, count: n)
            var xy = [Float](repeating: 0, count: n)
            vDSP_vsq(x, 1, &xx, 1, vDSP_Length(n))
            vDSP_vsq(y, 1, &yy, 1, vDSP_Length(n))
            vDSP_vmul(x, 1, y, 1, &xy, 1, vDSP_Length(n))

            var tmp = [Float](repeating: 0, count: n)
            boxBlur(&x, &tmp, width: w, height: sh, radius: radius)
            boxBlur(&y, &tmp, width: w, height: sh, radius: radius)
            boxBlur(&xx, &tmp, width: w, height: sh, radius: radius)
            boxBlur(&yy, &tmp, width: w, height: sh, radius: radius)
            boxBlur(&xy, &tmp, width: w, height: sh, radius: radius)

            // Rows [outStart, outEnd) expressed as offsets into the strip.
            let rowOffset = outStart - inStart
            for row in rowOffset..<(rowOffset + (outEnd - outStart)) {
                let o = row * w
                for col in 0..<w {
                    let i = o + col
                    let mx = Double(x[i]), my = Double(y[i])
                    let vx = Double(xx[i]) - mx * mx
                    let vy = Double(yy[i]) - my * my
                    let cxy = Double(xy[i]) - mx * my

                    let num = (2 * mx * my + c1) * (2 * cxy + c2)
                    let den = (mx * mx + my * my + c1) * (vx + vy + c2)
                    total += den == 0 ? 1.0 : num / den
                    counted += 1
                }
            }
            strip = outEnd
        }

        return counted == 0 ? 1.0 : total / Double(counted)
    }

    // MARK: - Separable box blur

    /// In-place separable box blur with edge replication, O(pixels) regardless
    /// of window size thanks to a sliding running sum. `scratch` must be the
    /// same length as `plane` and is treated as undefined on return.
    ///
    /// Both passes keep a `Double` running sum, and that is not fussiness. The
    /// sums slide across thousands of elements, and in `Float` the accumulated
    /// rounding reaches the 1e-5 range — enough to break
    /// `testStripedSSIMMatchesWholeImageSSIM`, which requires a striped run and a
    /// whole-image run to agree to 1e-9 because the striping is meant to be an
    /// exact decomposition rather than an approximation. Measured: a `Float`
    /// accumulator is roughly twice as fast and moves the SSIM by ~3e-5. Do not
    /// take that trade without asking.
    static func boxBlur(_ plane: inout [Float], _ scratch: inout [Float], width w: Int, height h: Int, radius r: Int) {
        guard r > 0 else { return }
        let n = Float(2 * r + 1)

        // Horizontal: plane -> scratch. Already sequential, so it is left alone.
        for row in 0..<h {
            let o = row * w
            var sum = 0.0
            for k in -r...r { sum += Double(plane[o + min(max(k, 0), w - 1)]) }
            scratch[o] = Float(sum) / n
            for col in 1..<w {
                sum += Double(plane[o + min(col + r, w - 1)])
                sum -= Double(plane[o + max(col - r - 1, 0)])
                scratch[o + col] = Float(sum) / n
            }
        }

        // Vertical: scratch -> plane, a whole row of running sums slid down the
        // image together.
        //
        // The obvious way round — finish one column, then the next — reads every
        // value `w` floats from the last, so each read is its own cache line and
        // nothing vectorises. Sliding a row of accumulators instead touches
        // memory strictly in order and is **2.6x faster, measured, with the
        // result bit-identical**: each column's sum is still formed by the same
        // additions in the same sequence, only interleaved with its neighbours'.
        var acc = [Double](repeating: 0, count: w)
        scratch.withUnsafeBufferPointer { source in
            plane.withUnsafeMutableBufferPointer { destination in
                acc.withUnsafeMutableBufferPointer { sums in
                    for k in -r...r {
                        let o = min(max(k, 0), h - 1) * w
                        for c in 0..<w { sums[c] += Double(source[o + c]) }
                    }
                    for c in 0..<w { destination[c] = Float(sums[c]) / n }

                    for row in 1..<h {
                        let entering = min(row + r, h - 1) * w
                        let leaving = max(row - r - 1, 0) * w
                        let out = row * w
                        // Two statements, not `sums[c] += entering - leaving`.
                        // Floating point is not associative, and this way each
                        // column's sum is formed by exactly the additions the
                        // column-at-a-time version performed, in the same order,
                        // so the equality is a proof rather than a measurement.
                        for c in 0..<w {
                            sums[c] += Double(source[entering + c])
                            sums[c] -= Double(source[leaving + c])
                        }
                        for c in 0..<w { destination[out + c] = Float(sums[c]) / n }
                    }
                }
            }
        }
    }
}
