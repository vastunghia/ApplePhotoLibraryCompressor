import XCTest
@testable import APLCCore

final class EligibilityGateTests: XCTestCase {
    private func jpegTraits(_ mutate: (inout AssetTraits) -> Void = { _ in }) -> AssetTraits {
        var t = AssetTraits(
            localIdentifier: "ABC/L0/001",
            originalFilename: "IMG_0001.JPG",
            uniformTypeIdentifier: "public.jpeg"
        )
        mutate(&t)
        return t
    }

    private func facts(_ mutate: (inout ImageFacts) -> Void = { _ in }) -> ImageFacts {
        var f = ImageFacts(
            width: 4032, height: 3024, byteCount: 3_000_000,
            typeIdentifier: "public.jpeg",
            hasGainMap: false, hasEXIF: true, hasGPS: true, hasTIFF: true,
            orientation: 1, profileName: "sRGB IEC61966-2.1"
        )
        mutate(&f)
        return f
    }

    // MARK: - Pre-conditions

    func testPlainJPEGIsEligible() {
        XCTAssertEqual(EligibilityGate.evaluatePreConditions(jpegTraits()), .eligible)
    }

    func testNonJPEGIsSkipped() {
        let heic = jpegTraits { $0.uniformTypeIdentifier = "public.heic" }
        XCTAssertEqual(EligibilityGate.evaluatePreConditions(heic), .skip(.notAJPEG))

        let unknown = jpegTraits { $0.uniformTypeIdentifier = nil }
        XCTAssertEqual(EligibilityGate.evaluatePreConditions(unknown), .skip(.notAJPEG))
    }

    func testEditedAssetsAreSkipped() {
        XCTAssertEqual(
            EligibilityGate.evaluatePreConditions(jpegTraits { $0.hasAdjustments = true }),
            .skip(.hasAdjustments)
        )
        XCTAssertEqual(
            EligibilityGate.evaluatePreConditions(jpegTraits { $0.hasAdjustmentBaseResource = true }),
            .skip(.hasAdjustments)
        )
    }

    func testLivePhotosAndBurstsAreSkipped() {
        XCTAssertEqual(
            EligibilityGate.evaluatePreConditions(jpegTraits { $0.isLivePhoto = true }),
            .skip(.livePhotoOrBurst)
        )
        XCTAssertEqual(
            EligibilityGate.evaluatePreConditions(jpegTraits { $0.burstIdentifier = "burst-1" }),
            .skip(.livePhotoOrBurst)
        )
        XCTAssertEqual(
            EligibilityGate.evaluatePreConditions(jpegTraits { $0.hasPairedVideoResource = true }),
            .skip(.livePhotoOrBurst)
        )
    }

    func testCloudOnlyAssetIsSkippedWhenDownloadsAreDisabled() {
        let remote = jpegTraits { $0.isLocallyAvailable = false }
        XCTAssertEqual(
            EligibilityGate.evaluatePreConditions(remote, policy: GatePolicy(allowDownloads: false)),
            .skip(.notLocallyAvailable)
        )
        XCTAssertEqual(
            EligibilityGate.evaluatePreConditions(remote, policy: GatePolicy(allowDownloads: true)),
            .eligible
        )
    }

    // MARK: - Post-conditions

    private func post(
        source: ImageFacts, destination: ImageFacts,
        ssim: Double = 0.99, policy: GatePolicy = .default
    ) -> GateOutcome {
        EligibilityGate.evaluatePostConditions(
            source: source, destination: destination,
            quality: QualityScore(ssim: ssim, psnr: 45, width: source.width, height: source.height),
            policy: policy
        )
    }

    func testFaithfulSmallerHEICPasses() {
        let dst = facts { $0.typeIdentifier = "public.heic"; $0.byteCount = 900_000 }
        XCTAssertEqual(post(source: facts(), destination: dst), .eligible)
    }

    func testGeometryChangeIsRejected() {
        let dst = facts { $0.width = 2016; $0.byteCount = 900_000 }
        XCTAssertEqual(post(source: facts(), destination: dst), .skip(.geometryChanged))
    }

    func testDroppedGainMapIsRejected() {
        let src = facts { $0.hasGainMap = true }
        let dst = facts { $0.hasGainMap = false; $0.byteCount = 900_000 }
        XCTAssertEqual(post(source: src, destination: dst), .skip(.gainMapLost))
    }

    func testGainMapOnlyRequiredWhenSourceHadOne() {
        let dst = facts { $0.hasGainMap = false; $0.byteCount = 900_000 }
        XCTAssertEqual(post(source: facts(), destination: dst), .eligible)
    }

    func testDroppedMetadataIsRejected() {
        let smaller: (inout ImageFacts) -> Void = { $0.byteCount = 900_000 }

        XCTAssertEqual(
            post(source: facts(), destination: facts { smaller(&$0); $0.hasEXIF = false }),
            .skip(.exifLost)
        )
        XCTAssertEqual(
            post(source: facts(), destination: facts { smaller(&$0); $0.hasGPS = false }),
            .skip(.gpsLost)
        )
        XCTAssertEqual(
            post(source: facts(), destination: facts { smaller(&$0); $0.hasTIFF = false }),
            .skip(.tiffLost)
        )
        XCTAssertEqual(
            post(source: facts(), destination: facts { smaller(&$0); $0.profileName = nil }),
            .skip(.colorProfileLost)
        )
    }

    func testMetadataAbsentFromSourceIsNotRequired() {
        var src = facts()
        src.hasGPS = false
        src.profileName = nil
        let dst = facts { $0.hasGPS = false; $0.profileName = nil; $0.byteCount = 900_000 }
        XCTAssertEqual(post(source: src, destination: dst), .eligible)
    }

    func testMissingOrientationIsTreatedAsUpright() {
        // A source tagged "1" and a destination with no tag mean the same thing.
        let dst = facts { $0.orientation = nil; $0.byteCount = 900_000 }
        XCTAssertEqual(post(source: facts(), destination: dst), .eligible)

        let rotated = facts { $0.orientation = 6; $0.byteCount = 900_000 }
        XCTAssertEqual(post(source: facts(), destination: rotated), .skip(.orientationChanged))
    }

    func testProfileNameMismatchOnlyMattersInStrictMode() {
        let dst = facts { $0.profileName = "Display P3"; $0.byteCount = 900_000 }
        XCTAssertEqual(post(source: facts(), destination: dst), .eligible)
        XCTAssertEqual(
            post(source: facts(), destination: dst,
                 policy: GatePolicy(requireExactProfileMatch: true)),
            .skip(.colorProfileLost)
        )
    }

    /// Above roughly q=0.95 ImageIO produces a HEIC larger than the JPEG.
    /// That conversion is pointless and must be rejected, not merely noted.
    func testHEICLargerThanJPEGIsRejected() {
        let dst = facts { $0.byteCount = 7_600_000 }
        XCTAssertEqual(post(source: facts(), destination: dst), .skip(.insufficientSaving))
    }

    func testMarginalSavingIsRejected() {
        let dst = facts { $0.byteCount = 2_910_000 }  // 97% of the original
        XCTAssertEqual(post(source: facts(), destination: dst), .skip(.insufficientSaving))
    }

    func testLowSSIMIsRejected() {
        let dst = facts { $0.byteCount = 900_000 }
        XCTAssertEqual(post(source: facts(), destination: dst, ssim: 0.80),
                       .skip(.qualityBelowThreshold))
    }

    func testEverySkipReasonHasAnExplanation() {
        for reason in SkipReason.allCases {
            XCTAssertFalse(reason.explanation.isEmpty, "\(reason) lacks an explanation")
        }
    }
}
