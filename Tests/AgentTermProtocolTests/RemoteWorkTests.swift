import XCTest

@testable import AgentTermProtocol

/// GIT-76 (#116): what is asked of a folder's remotes while the app asks
/// them by itself is kept and begun when that is over, and the app's own
/// fetch holds no button. The Mac and the iPhone both go by `RemoteWork`.
final class RemoteWorkTests: XCTestCase {
    func testWhatIsAskedWhileTheAppFetchesByItselfIsKeptAndBegunAfter() {
        var work = RemoteWork<String>()
        XCTAssertTrue(work.beginQuietFetch(in: "/a"))
        XCTAssertTrue(work.isFetchingQuietly(in: "/a"))
        XCTAssertEqual(work.busy, [:], "the app's own fetch holds nothing")
        // Asked meanwhile: not thrown away, and not begun beside the fetch.
        XCTAssertEqual(work.ask("push", in: "/a", keeping: "the push"), .kept)
        XCTAssertEqual(work.busy, ["/a": "push"], "the folder is busy with what was asked for, from the asking on")
        // The fetch over: what was kept is handed back to be begun.
        XCTAssertEqual(work.quietFetchEnded(in: "/a"), "the push")
        XCTAssertFalse(work.isFetchingQuietly(in: "/a"))
        XCTAssertEqual(work.busy, ["/a": "push"])
        XCTAssertEqual(work.ended(in: "/a"), "push")
        XCTAssertEqual(work.busy, [:])
        // Handed back once.
        XCTAssertTrue(work.beginQuietFetch(in: "/a"))
        XCTAssertNil(work.quietFetchEnded(in: "/a"))
    }

    func testWithNoFetchOfTheAppsOwnItIsBegunAtOnce() {
        var work = RemoteWork<String>()
        XCTAssertEqual(work.ask("pull", in: "/a", keeping: "the pull"), .begin)
        XCTAssertEqual(work.busy, ["/a": "pull"])
        // Another folder's fetch keeps nothing of this one.
        XCTAssertTrue(work.beginQuietFetch(in: "/b"))
        XCTAssertEqual(work.ended(in: "/a"), "pull")
        XCTAssertEqual(work.ask("push", in: "/a", keeping: "the push"), .begin)
        XCTAssertNil(work.quietFetchEnded(in: "/b"))
    }

    func testOneThingOfTheUsersAtATimeInAFolder() {
        var work = RemoteWork<String>()
        XCTAssertEqual(work.ask("push", in: "/a", keeping: "the push"), .begin)
        XCTAssertEqual(work.ask("pull", in: "/a", keeping: "the pull"), .refused)
        XCTAssertEqual(work.busy, ["/a": "push"], "what is under way stays what the folder is busy with")
        // Nor does the app ask the remotes by itself beside it.
        XCTAssertFalse(work.beginQuietFetch(in: "/a"))
        // Another folder is free.
        XCTAssertEqual(work.ask("pull", in: "/b", keeping: "the pull"), .begin)
        XCTAssertNil(work.ended(in: "/c"), "nothing was under way there")
    }

    func testTheAppsOwnFetchIsNotBegunTwice() {
        var work = RemoteWork<String>()
        XCTAssertTrue(work.beginQuietFetch(in: "/a"))
        XCTAssertFalse(work.beginQuietFetch(in: "/a"))
        XCTAssertNil(work.quietFetchEnded(in: "/a"))
        XCTAssertTrue(work.beginQuietFetch(in: "/a"))
    }

    func testNothingKeptIsBegunOnceTheConnectionIsAnother() {
        var work = RemoteWork<String>()
        XCTAssertTrue(work.beginQuietFetch(in: "/a"))
        XCTAssertEqual(work.ask("push", in: "/a", keeping: "the push"), .kept)
        work.forgetAll()
        XCTAssertEqual(work.busy, [:])
        XCTAssertFalse(work.isFetchingQuietly(in: "/a"))
        // The answer of a fetch of the connection before, come late.
        XCTAssertNil(work.quietFetchEnded(in: "/a"))
    }

    func testWhatIsOverWhileItWasKeptIsNotBegun() {
        var work = RemoteWork<String>()
        XCTAssertTrue(work.beginQuietFetch(in: "/a"))
        XCTAssertEqual(work.ask("push", in: "/a", keeping: "the push"), .kept)
        // Said over before it began, a failure of the connection say.
        XCTAssertEqual(work.ended(in: "/a"), "push")
        XCTAssertNil(work.quietFetchEnded(in: "/a"))
    }
}
