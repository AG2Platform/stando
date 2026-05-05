import Foundation

// Parser + writer for $SUTANDO_HOME/.env. The Settings window edits this
// file; preserves unknown keys (so manual edits to less-common settings —
// SUTANDO_TEAM_TIER_OWNER, model overrides, etc. — survive the round trip)
// and preserves blank lines + comments where possible.
//
// Format we accept:
//   KEY=value                         standard
//   KEY="quoted value"                quoted (used when value has spaces)
//   KEY='single quoted'               also accepted
//   # comment                         preserved on round trip
//   blank lines                       preserved on round trip
//
// Format we emit:
//   KEY=value                         when value has no special chars
//   KEY="value with spaces"           otherwise
//
// Not a full POSIX env-file parser (no expansion, no multi-line, no
// command substitution) — Sutando .env entries are flat key=value pairs.

struct EnvFile {
    /// Each line preserves its original surface form. Setting a managed key
    /// updates an existing line in place when present, otherwise appends.
    private(set) var lines: [Line]

    enum Line {
        case raw(String)             // comment, blank, or unparseable
        case kv(key: String, value: String, original: String?)
    }

    static func at(_ path: String) -> EnvFile {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            return EnvFile(lines: [])
        }
        var lines: [Line] = []
        for raw in data.components(separatedBy: "\n") {
            // Drop trailing \r for CRLF files.
            let stripped = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let parsed = parseLine(stripped) {
                lines.append(parsed)
            } else {
                lines.append(.raw(stripped))
            }
        }
        // Trailing newline produced an empty last element — drop it.
        if case .raw("") = lines.last { lines.removeLast() }
        return EnvFile(lines: lines)
    }

    func value(for key: String) -> String? {
        for line in lines {
            if case let .kv(k, v, _) = line, k == key { return v }
        }
        return nil
    }

    mutating func set(_ key: String, _ value: String?) {
        // Remove existing entry; we'll re-append at the end if value != nil.
        var didReplace = false
        for i in 0..<lines.count {
            if case let .kv(k, _, _) = lines[i], k == key {
                if let v = value, !v.isEmpty {
                    lines[i] = .kv(key: key, value: v, original: nil)
                    didReplace = true
                } else {
                    lines.remove(at: i)
                }
                break
            }
        }
        if !didReplace, let v = value, !v.isEmpty {
            lines.append(.kv(key: key, value: v, original: nil))
        }
    }

    func write(to path: String, mode: mode_t = 0o600) throws {
        var out = ""
        for line in lines {
            switch line {
            case .raw(let s):
                out += s + "\n"
            case let .kv(k, v, original):
                if let original = original {
                    out += original + "\n"
                } else {
                    out += "\(k)=\(quote(v))\n"
                }
            }
        }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = path + ".tmp"
        try out.write(toFile: tmp, atomically: true, encoding: .utf8)
        chmod(tmp, mode)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
    }

    // MARK: - Internals

    private static func parseLine(_ line: String) -> Line? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            return .raw(line)
        }
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        if key.isEmpty || !key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return nil
        }
        let rhs = String(line[line.index(after: eq)...])
        let value = unquote(rhs.trimmingCharacters(in: .whitespaces))
        return .kv(key: key, value: value, original: line)
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2 {
            let first = s.first!
            let last = s.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                return String(s.dropFirst().dropLast())
            }
        }
        // Strip trailing inline comment after unquoted value: KEY=value # comment
        if !s.hasPrefix("\"") && !s.hasPrefix("'"), let hashIdx = s.firstIndex(of: "#") {
            return String(s[..<hashIdx]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    private func quote(_ value: String) -> String {
        // Anything special → quoted. Otherwise plain.
        let safe = value.allSatisfy { ch in
            ch.isLetter || ch.isNumber || "._-:/+@=,".contains(ch)
        }
        if safe { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
