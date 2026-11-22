import AgentTermProtocol
import XCTest

/// The pictures of a page a device watches (#107, BROWSER-55 in
/// docs/TESTING.md): how one is laid into the room a device has, where a
/// touch on it is in the page, how wide it is asked for, and when one is
/// taken of a page that is streamed.
final class PagePictureTests: XCTestCase {
    /// An iPhone's room in points, and an iPad's.
    private let phone = (width: 402.0, height: 874.0)
    private let pad = (width: 1032.0, height: 1376.0)

    private func fit(page: (Double, Double), picture: (Double, Double), room: (width: Double, height: Double)) throws -> PageFit {
        try XCTUnwrap(
            PageFit(pageWidth: page.0, pageHeight: page.1, pictureWidth: picture.0, pictureHeight: picture.1, roomWidth: room.width, roomHeight: room.height))
    }

    /// BROWSER-55: a page shown as a phone of 440 × 956, streamed with a
    /// pixel to its point, on an iPhone: all of it, in its own shape,
    /// within the room.
    func testAPageShownAsAPhoneFitsAPhonesRoomInItsShape() throws {
        let fit = try fit(page: (440, 956), picture: (440, 956), room: phone)
        XCTAssertEqual(fit.width / fit.height, 440.0 / 956.0, accuracy: 0.0001, "squeezed")
        XCTAssertLessThanOrEqual(fit.width, phone.width)
        XCTAssertLessThanOrEqual(fit.height, phone.height)
        // As large as the room lets it be: one of the two sides is the room's.
        XCTAssertTrue(abs(fit.width - phone.width) < 0.001 || abs(fit.height - phone.height) < 0.001, "smaller than the room lets it be")
        XCTAssertEqual(fit.scale, phone.width / 440, accuracy: 0.0001)
    }

    /// BROWSER-55: the same page on an iPad: as tall as the room, not as
    /// wide, nothing of it past the room's right edge.
    func testAPageShownAsAPhoneFitsAnIPadsRoomWhole() throws {
        let fit = try fit(page: (440, 956), picture: (1320, 2868), room: pad)
        XCTAssertEqual(fit.width / fit.height, 440.0 / 956.0, accuracy: 0.0001, "squeezed")
        XCTAssertEqual(fit.height, pad.height, accuracy: 0.001)
        XCTAssertLessThanOrEqual(fit.width, pad.width, "cut off at the right")
    }

    /// BROWSER-55: a page shown as an iPad, wider than it is tall in its
    /// pane, on an iPad: as wide as the room and no wider.
    func testAWidePageOfATabletIsNotCutOffOnAnIPad() throws {
        let fit = try fit(page: (1032, 700), picture: (1032, 700), room: pad)
        XCTAssertEqual(fit.width, pad.width, accuracy: 0.001)
        XCTAssertEqual(fit.height, 700, accuracy: 0.001)
        XCTAssertLessThanOrEqual(fit.width, pad.width, "cut off at the right")
    }

    /// BROWSER-55: a wide page of the Mac's on an iPhone: as wide as the
    /// room, in its shape, at the top.
    func testAWidePageFitsAPhonesWidth() throws {
        let fit = try fit(page: (1280, 800), picture: (2560, 1600), room: phone)
        XCTAssertEqual(fit.width, phone.width, accuracy: 0.001)
        XCTAssertEqual(fit.width / fit.height, 1280.0 / 800.0, accuracy: 0.0001, "squeezed")
        XCTAssertLessThanOrEqual(fit.height, phone.height)
    }

    /// BROWSER-55: the picture's shape is its own, not that of the size
    /// sent with it. A picture of the top 600 points of a phone's screen,
    /// sent with the whole screen's size, is drawn in the picture's shape:
    /// drawn in the size's, as it was, its words are narrow and tall.
    func testAPictureIsDrawnInItsOwnShapeWhateverTheSizeSentWithIt() throws {
        let fit = try fit(page: (440, 956), picture: (440, 600), room: phone)
        XCTAssertEqual(fit.width / fit.height, 440.0 / 600.0, accuracy: 0.0001, "drawn in the shape of the size sent, not the picture's")
        XCTAssertEqual(fit.pageHeight, 600, accuracy: 0.001)
        XCTAssertLessThanOrEqual(fit.height, phone.height)
    }

    /// BROWSER-55: nothing to draw, or no room, is no fit rather than a
    /// division by nothing.
    func testNoSizeOrNoRoomIsNoFit() {
        XCTAssertNil(PageFit(pageWidth: 0, pageHeight: 956, pictureWidth: 440, pictureHeight: 956, roomWidth: 402, roomHeight: 874))
        XCTAssertNil(PageFit(pageWidth: 440, pageHeight: 956, pictureWidth: 440, pictureHeight: 956, roomWidth: 0, roomHeight: 874))
        XCTAssertNil(PageFit(pageWidth: 440, pageHeight: 956, pictureWidth: 440, pictureHeight: 956, roomWidth: 402, roomHeight: 0))
        // A picture whose size is not known is drawn in the size sent with it.
        XCTAssertEqual(PageFit(pageWidth: 440, pageHeight: 956, pictureWidth: 0, pictureHeight: 0, roomWidth: 402, roomHeight: 874)?.pageHeight, 956)
    }

    /// BROWSER-55: a touch lands in the page where the finger is on the
    /// picture, whatever the picture's pixels: its middle is the page's
    /// middle, its corners the page's, and a finger past an edge is the edge.
    func testATouchLandsWhereTheFingerIs() throws {
        for picture in [(440.0, 956.0), (1320.0, 2868.0)] {
            let fit = try fit(page: (440, 956), picture: picture, room: phone)
            let middle = fit.pagePoint(x: fit.width / 2, y: fit.height / 2)
            XCTAssertEqual(middle.x, 220, accuracy: 0.01)
            XCTAssertEqual(middle.y, 478, accuracy: 0.01)
            let corner = fit.pagePoint(x: 0, y: 0)
            XCTAssertEqual(corner.x, 0)
            XCTAssertEqual(corner.y, 0)
            let past = fit.pagePoint(x: fit.width + 6, y: fit.height + 6)
            XCTAssertEqual(past.x, 439, accuracy: 0.001)
            XCTAssertEqual(past.y, 955, accuracy: 0.001)
            let before = fit.pagePoint(x: -4, y: -4)
            XCTAssertEqual(before.x, 0)
            XCTAssertEqual(before.y, 0)
        }
        // A wide page drawn small: a point of the room is several of the page's.
        let wide = try fit(page: (1280, 800), picture: (1280, 800), room: phone)
        XCTAssertEqual(wide.pagePoint(x: 201, y: 100).x, 640, accuracy: 0.01)
        XCTAssertEqual(wide.pagePoint(x: 201, y: 100).y, 100 * 1280.0 / 402, accuracy: 0.01)
    }

    /// BROWSER-55: the page scrolls as far as the finger went over it, and
    /// less far over a picture zoomed into.
    func testThePageScrollsAsFarAsTheFingerWent() throws {
        let fit = try fit(page: (1280, 800), picture: (1280, 800), room: phone)
        XCTAssertEqual(fit.pageDistance(40.2), 128, accuracy: 0.001)
        XCTAssertEqual(fit.pageDistance(40.2, zoom: 2), 64, accuracy: 0.001)
        XCTAssertEqual(fit.pageDistance(-40.2), -128, accuracy: 0.001)
    }

    /// BROWSER-55: a device asks for as many pixels as its room has, not
    /// the 1290 every device asked for: an iPad then drew a picture made
    /// for a phone over 2064 pixels.
    func testADeviceAsksForItsRoomsPixels() {
        XCTAssertEqual(PagePicture.width(points: 402, scale: 3), 1206)
        XCTAssertEqual(PagePicture.width(points: 1032, scale: 2), 2064)
        XCTAssertEqual(PagePicture.width(points: 1376, scale: 2), 2752)
        // Within what a picture may be, whatever is said of the room.
        XCTAssertEqual(PagePicture.width(points: 20, scale: 2), PagePicture.widths.lowerBound)
        XCTAssertEqual(PagePicture.width(points: 5000, scale: 3), PagePicture.widths.upperBound)
        XCTAssertEqual(PagePicture.width(points: .infinity, scale: 2), PagePicture.widths.lowerBound)
        XCTAssertEqual(PagePicture.width(points: 402, scale: 0), 402)
    }

    /// BROWSER-55: a picture in base64, a third larger than it is, with
    /// what the message has around it, is within the 4 MB a message may be.
    func testTheLargestPictureFitsAMessage() throws {
        let message = ServerMessage.browserFrame(tab: "123456", jpeg: Data(repeating: 0xA5, count: PagePicture.mostBytes), width: 1032.5, height: 1376.25)
        XCTAssertLessThan(try JSONEncoder().encode(message).count, 4 * 1024 * 1024)
    }

    /// BROWSER-55: a page that is streamed has one picture taken once it
    /// has stood still for a moment, and no other until it changes again.
    func testAPictureIsTakenOnceThePageStandsStill() {
        var stills = PageStills()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(stills.isDue(at: start), "a picture of a page nothing was streamed of")
        XCTAssertTrue(stills.streamed(Data([1]), at: start))
        XCTAssertFalse(stills.isDue(at: start.addingTimeInterval(0.3)), "the page may still be changing")
        // It changes again: the wait starts again.
        XCTAssertTrue(stills.streamed(Data([2]), at: start.addingTimeInterval(0.5)))
        XCTAssertFalse(stills.isDue(at: start.addingTimeInterval(1.0)))
        let began = start.addingTimeInterval(0.5 + PageStills.quiet)
        XCTAssertTrue(stills.isDue(at: began))
        XCTAssertTrue(stills.taken(began: began), "the picture of a page that stood still is sent")
        XCTAssertFalse(stills.isDue(at: began.addingTimeInterval(5)), "a second picture of a page that did not change")
    }

    /// BROWSER-55: taking a picture has Chromium draw the page once more,
    /// streamed the same as the last: it is not sent, and is not the page
    /// changing, or a picture would be taken again without end.
    func testWhatIsStreamedTheSameAsTheLastIsNotAChange() {
        var stills = PageStills()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(stills.streamed(Data([1, 2, 3]), at: start))
        let began = start.addingTimeInterval(1)
        XCTAssertTrue(stills.taken(began: began))
        XCTAssertFalse(stills.streamed(Data([1, 2, 3]), at: began.addingTimeInterval(0.1)), "the same picture sent again")
        XCTAssertFalse(stills.isDue(at: began.addingTimeInterval(5)), "a picture taken because one was taken")
        // The page really changes: streamed, and a picture taken again.
        XCTAssertTrue(stills.streamed(Data([4]), at: began.addingTimeInterval(6)))
        XCTAssertTrue(stills.isDue(at: began.addingTimeInterval(6 + PageStills.quiet)))
    }

    /// BROWSER-55: a picture of a page that changed while it was taken is
    /// of what the page no longer shows: not sent, and taken again later.
    func testAPictureOfAPageThatChangedMeanwhileIsNotSent() {
        var stills = PageStills()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(stills.streamed(Data([1]), at: start))
        let began = start.addingTimeInterval(1)
        XCTAssertTrue(stills.streamed(Data([2]), at: began.addingTimeInterval(0.05)))
        XCTAssertFalse(stills.taken(began: began), "a picture of what the page no longer shows was sent")
        XCTAssertTrue(stills.isDue(at: began.addingTimeInterval(0.05 + PageStills.quiet)), "no picture of the page as it is now")
        XCTAssertFalse(stills.taken(began: start), "a picture nothing asked for")
    }

    /// BROWSER-55 (#100): no picture is taken of a page shown as a device
    /// whose pixels are not the screen's, which would shake on the Mac.
    func testNoPictureIsTakenWhereItWouldShakeThePage() {
        XCTAssertTrue(PageStills.leavesThePageAsItIs(device: nil, screen: 2))
        XCTAssertTrue(PageStills.leavesThePageAsItIs(device: nil, screen: 1))
        XCTAssertTrue(PageStills.leavesThePageAsItIs(device: 2, screen: 2))
        XCTAssertFalse(PageStills.leavesThePageAsItIs(device: 3, screen: 2))
        XCTAssertFalse(PageStills.leavesThePageAsItIs(device: 2, screen: 1))
    }

    /// BROWSER-55: nor of a page drawn with a pixel to its point, whose
    /// picture taken is what was streamed.
    func testNoPictureIsTakenWhereItHasNoMorePixels() {
        XCTAssertTrue(PageStills.isSharper(device: nil, screen: 2))
        XCTAssertFalse(PageStills.isSharper(device: nil, screen: 1))
        XCTAssertTrue(PageStills.isSharper(device: 3, screen: 1))
        XCTAssertFalse(PageStills.isSharper(device: 1, screen: 2))
    }
}
