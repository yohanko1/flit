import Foundation
import CryptoKit

enum ClipKind: Int, CaseIterable {
    case text = 0, link = 1, image = 2, file = 3

    /// A lone http(s) address is a link; prose that merely contains one is text.
    static func detect(_ text: String) -> ClipKind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("http://") || t.hasPrefix("https://"),
              t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let host = URL(string: t)?.host, !host.isEmpty else { return .text }
        return .link
    }
}

/// What came off the pasteboard.
enum ClipContent {
    case text(String, rtf: Data?, html: Data?)
    case image(png: Data, width: Int, height: Int)
    case files([String])
}

/// One history row as the list shows it. `text` is only the start of long
/// content; `ClipboardStore.fullText(id:)` returns all of it.
struct ClipEntry: Identifiable, Equatable {
    let id: Int64
    var kind: ClipKind
    var text: String
    /// Characters in the full text.
    var length: Int
    /// Image file name inside the store's blob directory.
    var blob: String?
    /// Bundle ID of the app that was frontmost when this was copied.
    var app: String?
    /// Image pixel size; for files, `width` is the number of files.
    var width: Int
    var height: Int
    var bytes: Int
    var created: Date
    var used: Date

    var title: String {
        switch kind {
        case .image:
            return "Image \(width)×\(height)"
        case .file:
            let first = text.split(separator: "\n").first.map { ($0 as NSString).lastPathComponent } ?? "File"
            return width > 1 ? "\(first) and \(width - 1) more" : first
        case .text, .link:
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct Snippet: Identifiable, Equatable {
    var id: Int64
    var name: String
    var text: String
}

/// Fills `{date}`, `{time}` and `{clipboard}` when a snippet is pasted.
enum SnippetExpander {
    static func expand(_ text: String, now: Date, calendar: Calendar, clipboard: String?) -> String {
        guard text.contains("{") else { return text }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let date = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return text
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{clipboard}", with: clipboard ?? "")
    }
}

/// Clipboard history and snippets, on disk. Nothing is held in memory between
/// calls: the list asks for a page of rows, and long text, rich text and
/// images are read only when an entry is previewed or pasted.
final class ClipboardStore {
    /// Characters of each entry the list loads.
    private static let previewLength = 600

    let directory: URL
    private let blobs: URL
    private let db: SQLite
    private let maxTextBytes: Int

    init(directory: URL, maxTextBytes: Int = 2_000_000) throws {
        self.directory = directory
        self.maxTextBytes = maxTextBytes
        blobs = directory.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        db = try SQLite(path: directory.appendingPathComponent("clipboard.sqlite").path)
        try db.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA cache_size = -256;
            CREATE TABLE IF NOT EXISTS entries(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind INTEGER NOT NULL,
                text TEXT NOT NULL,
                hash TEXT NOT NULL UNIQUE,
                blob TEXT,
                rtf BLOB,
                html BLOB,
                app TEXT,
                width INTEGER NOT NULL DEFAULT 0,
                height INTEGER NOT NULL DEFAULT 0,
                bytes INTEGER NOT NULL DEFAULT 0,
                created REAL NOT NULL,
                used REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS entries_used ON entries(used DESC);
            CREATE TABLE IF NOT EXISTS snippets(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                text TEXT NOT NULL
            );
            """)
    }

    // MARK: History

    /// Stores a copy. Content already in history moves to the top instead of
    /// being stored twice. Returns nil for content that isn't kept: blank
    /// text, or text over the size limit.
    @discardableResult
    func add(_ content: ClipContent, app: String?, now: Date) -> Int64? {
        let kind: ClipKind
        let text: String
        let hash: String
        var blob: String?
        var rtf: Data?
        var html: Data?
        var width = 0, height = 0, bytes = 0
        var imageData: Data?

        switch content {
        case .text(let s, let r, let h):
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.utf8.count <= maxTextBytes else { return nil }
            kind = ClipKind.detect(s)
            text = s
            hash = "t:" + Self.digest(Data(s.utf8))
            rtf = r
            html = h
            bytes = s.utf8.count
        case .image(let png, let w, let h):
            guard !png.isEmpty else { return nil }
            kind = .image
            text = ""
            let digest = Self.digest(png)
            hash = "i:" + digest
            blob = digest + ".png"
            width = w; height = h; bytes = png.count
            imageData = png
        case .files(let paths):
            guard !paths.isEmpty else { return nil }
            kind = .file
            text = paths.joined(separator: "\n")
            hash = "f:" + Self.digest(Data(text.utf8))
            width = paths.count
            bytes = text.utf8.count
        }

        let stamp = now.timeIntervalSince1970
        if let existing = db.run("SELECT id FROM entries WHERE hash = ?", [.text(hash)]).first?.first?.int {
            // A plain re-copy must not wipe the formatting stored earlier.
            db.run("UPDATE entries SET used = ?, app = COALESCE(?, app), rtf = COALESCE(?, rtf), html = COALESCE(?, html) WHERE id = ?",
                   [.real(stamp), SQLValue(app), SQLValue(rtf), SQLValue(html), .int(existing)])
            return existing
        }
        if let imageData, let blob {
            do { try imageData.write(to: blobs.appendingPathComponent(blob), options: .atomic) } catch {
                Log.info("clipboard image write failed: \(error)")
                return nil
            }
        }
        db.run("""
            INSERT INTO entries(kind, text, hash, blob, rtf, html, app, width, height, bytes, created, used)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.int(Int64(kind.rawValue)), .text(text), .text(hash), SQLValue(blob), SQLValue(rtf), SQLValue(html),
                  SQLValue(app), .int(Int64(width)), .int(Int64(height)), .int(Int64(bytes)), .real(stamp), .real(stamp)])
        return db.lastInsertID
    }

    /// Most recently used first. Every whitespace-separated term of `query`
    /// must appear somewhere in the full text, in any letter case.
    func entries(matching query: String = "", limit: Int = 200) -> [ClipEntry] {
        let (clause, params) = Self.likeClause(query, columns: ["text"])
        let sql = """
            SELECT id, kind, substr(text, 1, \(Self.previewLength)), length(text), blob, app, width, height, bytes, created, used
            FROM entries \(clause) ORDER BY used DESC, id DESC LIMIT ?
            """
        return db.run(sql, params + [.int(Int64(limit))]).compactMap { r in
            guard r.count == 11, let id = r[0].int, let kind = ClipKind(rawValue: Int(r[1].int ?? 0)) else { return nil }
            return ClipEntry(id: id, kind: kind, text: r[2].string ?? "", length: Int(r[3].int ?? 0),
                             blob: r[4].string, app: r[5].string,
                             width: Int(r[6].int ?? 0), height: Int(r[7].int ?? 0), bytes: Int(r[8].int ?? 0),
                             created: Date(timeIntervalSince1970: r[9].double ?? 0),
                             used: Date(timeIntervalSince1970: r[10].double ?? 0))
        }
    }

    var count: Int {
        Int(db.run("SELECT COUNT(*) FROM entries").first?.first?.int ?? 0)
    }

    func fullText(id: Int64) -> String? {
        db.run("SELECT text FROM entries WHERE id = ?", [.int(id)]).first?.first?.string
    }

    func rich(id: Int64) -> (rtf: Data?, html: Data?) {
        guard let row = db.run("SELECT rtf, html FROM entries WHERE id = ?", [.int(id)]).first, row.count == 2 else {
            return (nil, nil)
        }
        return (row[0].data, row[1].data)
    }

    func imageURL(_ entry: ClipEntry) -> URL? {
        entry.blob.map { blobs.appendingPathComponent($0) }
    }

    /// Marks an entry as just used, which moves it to the top.
    func touch(id: Int64, now: Date) {
        db.run("UPDATE entries SET used = ? WHERE id = ?", [.real(now.timeIntervalSince1970), .int(id)])
    }

    func delete(id: Int64) {
        removeBlobs(db.run("SELECT blob FROM entries WHERE id = ?", [.int(id)]))
        db.run("DELETE FROM entries WHERE id = ?", [.int(id)])
    }

    func clear() {
        removeBlobs(db.run("SELECT blob FROM entries WHERE blob IS NOT NULL"))
        db.run("DELETE FROM entries")
    }

    /// Drops entries last used before `cutoff`, then the oldest beyond `max`.
    func prune(olderThan cutoff: Date, max: Int) {
        let stamp = cutoff.timeIntervalSince1970
        removeBlobs(db.run("SELECT blob FROM entries WHERE used < ? AND blob IS NOT NULL", [.real(stamp)]))
        db.run("DELETE FROM entries WHERE used < ?", [.real(stamp)])
        let overflow = "SELECT id FROM entries ORDER BY used DESC, id DESC LIMIT -1 OFFSET ?"
        removeBlobs(db.run("SELECT blob FROM entries WHERE blob IS NOT NULL AND id IN (\(overflow))", [.int(Int64(max))]))
        db.run("DELETE FROM entries WHERE id IN (\(overflow))", [.int(Int64(max))])
    }

    private func removeBlobs(_ rows: [[SQLValue]]) {
        for row in rows {
            if let name = row.first?.string {
                try? FileManager.default.removeItem(at: blobs.appendingPathComponent(name))
            }
        }
    }

    // MARK: Snippets

    func snippets(matching query: String = "") -> [Snippet] {
        let (clause, params) = Self.likeClause(query, columns: ["name", "text"])
        return db.run("SELECT id, name, text FROM snippets \(clause) ORDER BY name COLLATE NOCASE, id", params).compactMap { r in
            guard r.count == 3, let id = r[0].int else { return nil }
            return Snippet(id: id, name: r[1].string ?? "", text: r[2].string ?? "")
        }
    }

    @discardableResult
    func addSnippet(name: String, text: String) -> Int64 {
        db.run("INSERT INTO snippets(name, text) VALUES(?, ?)", [.text(name), .text(text)])
        return db.lastInsertID
    }

    func updateSnippet(_ s: Snippet) {
        db.run("UPDATE snippets SET name = ?, text = ? WHERE id = ?", [.text(s.name), .text(s.text), .int(s.id)])
    }

    func deleteSnippet(id: Int64) {
        db.run("DELETE FROM snippets WHERE id = ?", [.int(id)])
    }

    // MARK: Helpers

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `WHERE` clause requiring every term in at least one of `columns`, with
    /// LIKE's wildcards escaped so `%` and `_` match themselves.
    private static func likeClause(_ query: String, columns: [String]) -> (String, [SQLValue]) {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return ("", []) }
        var params: [SQLValue] = []
        let parts = terms.map { term -> String in
            let escaped = term
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let any = columns.map { column -> String in
                params.append(.text("%\(escaped)%"))
                return "\(column) LIKE ? ESCAPE '\\'"
            }
            return "(" + any.joined(separator: " OR ") + ")"
        }
        return ("WHERE " + parts.joined(separator: " AND "), params)
    }
}
