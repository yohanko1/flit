import Testing
import Foundation
@testable import Flit

/// A store in its own temp directory, removed when the test ends.
private final class TempStore {
    let dir: URL
    let store: ClipboardStore

    init(maxTextBytes: Int = 2_000_000) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("flit-test-\(UUID().uuidString)")
        store = try ClipboardStore(directory: dir, maxTextBytes: maxTextBytes)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func text(_ s: String, at seconds: TimeInterval, app: String? = nil) -> Int64? {
        store.add(.text(s, rtf: nil, html: nil), app: app, now: Date(timeIntervalSince1970: seconds))
    }

    var texts: [String] { store.entries().map(\.text) }
}

struct ClipboardStoreTests {
    @Test func newestCopyComesFirst() throws {
        let t = try TempStore()
        t.text("first", at: 1)
        t.text("second", at: 2)
        #expect(t.texts == ["second", "first"])
    }

    @Test func copyingTheSameTextAgainMovesItToTheTopWithoutADuplicate() throws {
        let t = try TempStore()
        t.text("a", at: 1)
        t.text("b", at: 2)
        t.text("a", at: 3)
        #expect(t.texts == ["a", "b"])
        #expect(t.store.count == 2)
    }

    @Test func blankTextIsNotStored() throws {
        let t = try TempStore()
        #expect(t.text("  \n\t ", at: 1) == nil)
        #expect(t.store.count == 0)
    }

    @Test func textOverTheSizeLimitIsNotStored() throws {
        let t = try TempStore(maxTextBytes: 10)
        #expect(t.text("12345678901", at: 1) == nil)
        #expect(t.text("1234567890", at: 2) != nil)
    }

    @Test func searchNeedsEveryTermAndIgnoresCase() throws {
        let t = try TempStore()
        t.text("Hello World", at: 1)
        t.text("hello there", at: 2)
        t.text("goodbye world", at: 3)
        #expect(t.store.entries(matching: "WORLD hello").map(\.text) == ["Hello World"])
        #expect(t.store.entries(matching: "world").map(\.text) == ["goodbye world", "Hello World"])
        #expect(t.store.entries(matching: "   ").count == 3)
    }

    @Test func searchTreatsPercentAndUnderscoreAsPlainCharacters() throws {
        let t = try TempStore()
        t.text("100% sure", at: 1)
        t.text("1000 sure", at: 2)
        t.text("a_b", at: 3)
        t.text("axb", at: 4)
        #expect(t.store.entries(matching: "100%").map(\.text) == ["100% sure"])
        #expect(t.store.entries(matching: "a_b").map(\.text) == ["a_b"])
    }

    @Test func aLoneWebAddressIsALinkAndProseContainingOneIsText() throws {
        #expect(ClipKind.detect("https://example.com/a?b=1") == .link)
        #expect(ClipKind.detect("  http://example.com \n") == .link)
        #expect(ClipKind.detect("see https://example.com") == .text)
        #expect(ClipKind.detect("example.com") == .text)
        #expect(ClipKind.detect("https://") == .text)
        let t = try TempStore()
        t.text("https://example.com", at: 1)
        #expect(t.store.entries().first?.kind == .link)
    }

    @Test func rowTitleIsTheFirstNonEmptyLineTrimmed() throws {
        let t = try TempStore()
        t.text("  \n   first line  \nsecond line", at: 1)
        #expect(t.store.entries().first?.title == "first line")
    }

    @Test func longTextIsListedAsAPreviewButPastedInFull() throws {
        let t = try TempStore()
        let long = String(repeating: "abcdefghij", count: 500)
        let id = try #require(t.text(long, at: 1))
        let row = try #require(t.store.entries().first)
        #expect(row.text.count < long.count)
        #expect(long.hasPrefix(row.text))
        #expect(row.length == 5000)
        #expect(t.store.fullText(id: id) == long)
    }

    @Test func searchFindsTextBeyondThePreview() throws {
        let t = try TempStore()
        t.text(String(repeating: "x", count: 4000) + " needle", at: 1)
        #expect(t.store.entries(matching: "needle").count == 1)
    }

    @Test func sourceAppIsKept() throws {
        let t = try TempStore()
        t.text("from safari", at: 1, app: "com.apple.Safari")
        #expect(t.store.entries().first?.app == "com.apple.Safari")
    }

    @Test func richTextIsReturnedAndSurvivesAPlainRecopy() throws {
        let t = try TempStore()
        let rtf = Data("{\\rtf1 bold}".utf8)
        let id = try #require(t.store.add(.text("bold", rtf: rtf, html: nil), app: nil, now: Date(timeIntervalSince1970: 1)))
        #expect(t.store.rich(id: id).rtf == rtf)
        #expect(t.store.rich(id: id).html == nil)
        t.text("bold", at: 2)
        #expect(t.store.rich(id: id).rtf == rtf)
    }

    @Test func imageIsWrittenToDiskAndRemovedWithItsEntry() throws {
        let t = try TempStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let id = try #require(t.store.add(.image(png: png, width: 40, height: 30), app: nil, now: Date(timeIntervalSince1970: 1)))
        let row = try #require(t.store.entries().first)
        #expect(row.kind == .image)
        #expect(row.title == "Image 40×30")
        let url = try #require(t.store.imageURL(row))
        #expect(try Data(contentsOf: url) == png)
        t.store.delete(id: id)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(t.store.count == 0)
    }

    @Test func copiedFilesKeepEveryPathAndAreTitledByNameAndCount() throws {
        let t = try TempStore()
        let id = try #require(t.store.add(.files(["/tmp/report.pdf", "/tmp/notes.txt", "/tmp/c.png"]), app: nil, now: Date(timeIntervalSince1970: 1)))
        let row = try #require(t.store.entries().first)
        #expect(row.kind == .file)
        #expect(row.title == "report.pdf and 2 more")
        #expect(t.store.fullText(id: id) == "/tmp/report.pdf\n/tmp/notes.txt\n/tmp/c.png")
        #expect(t.store.entries(matching: "notes").count == 1)
    }

    @Test func usingAnEntryMovesItToTheTop() throws {
        let t = try TempStore()
        let a = try #require(t.text("a", at: 1))
        t.text("b", at: 2)
        t.store.touch(id: a, now: Date(timeIntervalSince1970: 3))
        #expect(t.texts == ["a", "b"])
    }

    @Test func pruneDropsEntriesOlderThanTheCutoffAndTheirImages() throws {
        let t = try TempStore()
        t.store.add(.image(png: Data([1, 2, 3]), width: 1, height: 1), app: nil, now: Date(timeIntervalSince1970: 10))
        let imageRow = try #require(t.store.entries().first)
        let url = try #require(t.store.imageURL(imageRow))
        t.text("old", at: 20)
        t.text("new", at: 100)
        t.store.prune(olderThan: Date(timeIntervalSince1970: 50), max: 1000)
        #expect(t.texts == ["new"])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func pruneKeepsOnlyTheNewestEntriesUpToTheLimit() throws {
        let t = try TempStore()
        for i in 1...5 { t.text("item \(i)", at: TimeInterval(i)) }
        t.store.prune(olderThan: Date(timeIntervalSince1970: 0), max: 2)
        #expect(t.texts == ["item 5", "item 4"])
    }

    @Test func historySurvivesReopeningTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flit-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let s = try ClipboardStore(directory: dir)
            s.add(.text("kept", rtf: nil, html: nil), app: nil, now: Date(timeIntervalSince1970: 1))
            s.addSnippet(name: "sig", text: "Regards")
        }
        let reopened = try ClipboardStore(directory: dir)
        #expect(reopened.entries().map(\.text) == ["kept"])
        #expect(reopened.snippets().map(\.name) == ["sig"])
    }

    @Test func clearEmptiesHistoryButKeepsSnippets() throws {
        let t = try TempStore()
        t.text("a", at: 1)
        t.store.add(.image(png: Data([9]), width: 1, height: 1), app: nil, now: Date(timeIntervalSince1970: 2))
        let imageRow = try #require(t.store.entries().first)
        let url = try #require(t.store.imageURL(imageRow))
        t.store.addSnippet(name: "sig", text: "Regards")
        t.store.clear()
        #expect(t.store.count == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(t.store.snippets().count == 1)
    }
}

struct SnippetStoreTests {
    @Test func snippetsAreListedByNameAndCanBeEditedAndDeleted() throws {
        let t = try TempStore()
        let b = t.store.addSnippet(name: "beta", text: "two")
        t.store.addSnippet(name: "Alpha", text: "one")
        #expect(t.store.snippets().map(\.name) == ["Alpha", "beta"])
        t.store.updateSnippet(Snippet(id: b, name: "zeta", text: "changed"))
        #expect(t.store.snippets().map(\.name) == ["Alpha", "zeta"])
        #expect(t.store.snippets().last?.text == "changed")
        t.store.deleteSnippet(id: b)
        #expect(t.store.snippets().map(\.name) == ["Alpha"])
    }

    @Test func snippetSearchLooksAtNameAndText() throws {
        let t = try TempStore()
        t.store.addSnippet(name: "address", text: "1 Infinite Loop")
        t.store.addSnippet(name: "sig", text: "Best regards")
        #expect(t.store.snippets(matching: "addr").map(\.name) == ["address"])
        #expect(t.store.snippets(matching: "REGARDS").map(\.name) == ["sig"])
        #expect(t.store.snippets(matching: "nothing").isEmpty)
    }

    @Test func placeholdersAreFilledAndUnknownOnesLeftAlone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9, minute: 5))!
        let out = SnippetExpander.expand("{date} {time} [{clipboard}] {other}", now: now, calendar: utc, clipboard: "copied")
        #expect(out == "2026-11-11 09:05 [copied] {other}")
    }

    @Test func clipboardPlaceholderIsEmptyWhenNothingIsCopied() {
        #expect(SnippetExpander.expand("a{clipboard}b", now: Date(), calendar: .current, clipboard: nil) == "ab")
    }
}
