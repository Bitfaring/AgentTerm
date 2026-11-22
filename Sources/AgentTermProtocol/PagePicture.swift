import Foundation

/// What is the same, on the Mac that sends them and on the devices that
/// draw them, of the pictures of a page a device watches (`browserFrame`,
/// #107).
public enum PagePicture {
    /// The quality of the JPEG, of 100. A streamed picture has a pixel to
    /// the page's point and is drawn two or three times larger on a phone:
    /// at 55, which it was, what the JPEG loses is drawn larger too, and is
    /// the first thing seen. At 80 a picture is about half again to twice
    /// as large as at 55 (a page of text 448 points wide: some 100 KB
    /// rather than 60), sent ten times a second at most and only while the
    /// page changes.
    public static let quality = 80

    /// The most a picture may weigh. A message of more than 4 MB closes the
    /// connection (`maximumMessageSize`), and a picture is sent in base64,
    /// a third larger than it is: 2.5 MB leaves room for it.
    public static let mostBytes = 2_500_000

    /// The narrowest and the widest picture asked for, in pixels: the
    /// widest is an iPad Pro 13 lying on its side.
    public static let widths = 320...2752

    /// The width a device asks its pictures at: the pixels of the room it
    /// draws them in, `points` wide on a screen of `scale` pixels to the
    /// point. More would be made smaller again on the device, and fewer
    /// drawn larger, which is blurred.
    public static func width(points: Double, scale: Double) -> Int {
        let pixels = (points * max(scale, 1)).rounded(.up)
        guard pixels.isFinite else { return widths.lowerBound }
        return min(max(Int(pixels), widths.lowerBound), widths.upperBound)
    }
}

/// A picture of a page laid into the room a device has for it: all of it,
/// in the picture's own shape, as large as the room lets it be; and where a
/// point of what is drawn is in the page.
///
/// The shape is the picture's, counted from its pixels, never that of the
/// size sent with it: the size says how many CSS pixels wide the picture
/// is, by which a touch is placed, and a picture drawn in another shape
/// than its own is squeezed (#107).
public struct PageFit: Equatable, Sendable {
    /// The CSS pixels of the page the picture shows.
    public let pageWidth: Double
    public let pageHeight: Double
    /// The size it is drawn at, in the room's points: never more than the room.
    public let width: Double
    public let height: Double
    /// The room's points to one CSS pixel of the page.
    public let scale: Double

    /// `pageWidth`, `pageHeight`: the size sent with the picture.
    /// `pictureWidth`, `pictureHeight`: the picture's own, in any unit.
    /// Nil while there is nothing to draw or no room to draw it in.
    public init?(pageWidth: Double, pageHeight: Double, pictureWidth: Double, pictureHeight: Double, roomWidth: Double, roomHeight: Double) {
        guard pageWidth > 0, pageHeight > 0, roomWidth > 0, roomHeight > 0 else { return nil }
        let high = pictureWidth > 0 && pictureHeight > 0 ? pageWidth * pictureHeight / pictureWidth : pageHeight
        let scale = min(roomWidth / pageWidth, roomHeight / high)
        guard scale > 0, scale.isFinite else { return nil }
        self.pageWidth = pageWidth
        self.pageHeight = high
        self.scale = scale
        width = min(pageWidth * scale, roomWidth)
        height = min(high * scale, roomHeight)
    }

    /// The point of the page, in its CSS pixels, under a point of what is
    /// drawn, counted from its top left. A finger a little past an edge
    /// means the edge, not a point outside the page.
    public func pagePoint(x: Double, y: Double) -> (x: Double, y: Double) {
        (min(max(x / scale, 0), max(pageWidth - 1, 0)), min(max(y / scale, 0), max(pageHeight - 1, 0)))
    }

    /// How far the page goes, in its CSS pixels, for a way of the finger in
    /// points over a picture zoomed `zoom` times.
    public func pageDistance(_ points: Double, zoom: Double = 1) -> Double {
        points / scale / max(zoom, 1)
    }
}

/// When a picture is taken of a page that is streamed (#107). What Chromium
/// streams has a pixel to the page's point, whatever the screen has; a
/// picture taken has all the pixels the page is drawn with. So while the
/// page changes it is streamed, and once it has stood still for a moment
/// one picture is taken of it, sharp, which stays on the device until the
/// page changes again.
public struct PageStills: Sendable {
    /// How long the page stands still before its picture is taken: longer
    /// than the half second of a caret's blink, so that a field waiting for
    /// its text has no picture taken at each blink.
    public static let quiet: TimeInterval = 0.7

    /// The last picture streamed.
    private var last: Data?
    /// When the page last changed, while no picture was taken of it since.
    private var changed: Date?

    public init() {}

    /// A picture was streamed: whether it is sent. One the same as the last
    /// says nothing new, and is not: taking a picture has Chromium draw the
    /// page once more, which would otherwise count as the page changing,
    /// and have a picture taken again, without end.
    public mutating func streamed(_ jpeg: Data, at time: Date) -> Bool {
        guard jpeg != last else { return false }
        last = jpeg
        changed = time
        return true
    }

    /// Whether the page has stood still long enough for its picture.
    public func isDue(at time: Date) -> Bool {
        changed.map { time.timeIntervalSince($0) >= Self.quiet } ?? false
    }

    /// A picture begun at `began` was taken: whether it is sent. Not when
    /// the page changed meanwhile: the picture is then of what the page no
    /// longer shows, and the next is taken once it stands still again.
    public mutating func taken(began: Date) -> Bool {
        guard let changed, changed <= began else { return false }
        self.changed = nil
        return true
    }

    /// Whether taking a picture leaves what the Mac shows of the page as it
    /// is. Of a page shown as a device whose pixels are not the screen's,
    /// Chromium lays the page out again for each picture and the Mac shows
    /// it in between, the page shaking (#100): none is taken of it.
    /// `device`: the pixels to a point of the device the page is shown as,
    /// nil when it is shown as itself. `screen`: those of the Mac's screen.
    public static func leavesThePageAsItIs(device: Double?, screen: Double) -> Bool {
        guard let device else { return true }
        return abs(device - screen) < 0.01
    }

    /// Whether a picture taken has more pixels than what is streamed: the
    /// page is drawn with more than one to its point, the device's when it
    /// is shown as one, the screen's otherwise. With one, a picture taken
    /// is what was streamed, and none is.
    public static func isSharper(device: Double?, screen: Double) -> Bool {
        (device ?? screen) > 1.01
    }
}
