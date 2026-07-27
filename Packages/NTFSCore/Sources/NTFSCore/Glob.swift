import Foundation

/// Shell-style glob matching for file names (`ntfsctl find --name`).
///
/// Pure logic, no libc dependency, so the semantics are identical everywhere
/// and directly testable. Supported syntax (a subset of `fnmatch(3)`):
///
///   * `*`        — any run of characters, including none
///   * `?`        — exactly one character
///   * `[abc]`    — one character from the set
///   * `[a-z]`    — one character from the range
///   * `[!abc]`   — one character NOT in the set (`[^abc]` also accepted)
///   * `\x`       — literal `x` (escapes `*`, `?`, `[`, `\`)
///
/// `*` matches `/` as well: patterns apply to a single entry name, never to a
/// path, so the question never arises.
public enum Glob {

    /// Match `name` against `pattern`.
    ///
    /// `caseInsensitive` defaults to true because NTFS itself is
    /// case-insensitive — `find --name '*.JPG'` finding `img.jpg` is the
    /// behavior that matches how the volume treats those names as equal.
    public static func matches(
        pattern: String,
        name: String,
        caseInsensitive: Bool = true
    ) -> Bool {
        let p = Array(caseInsensitive ? pattern.lowercased() : pattern)
        let s = Array(caseInsensitive ? name.lowercased() : name)

        var pi = 0
        var si = 0
        // Backtrack point for the most recent `*`.
        var starPattern = -1
        var starSubject = -1

        while si < s.count {
            var advanced = false
            if pi < p.count {
                switch p[pi] {
                case "*":
                    starPattern = pi
                    starSubject = si
                    pi += 1
                    continue
                case "?":
                    pi += 1
                    si += 1
                    advanced = true
                case "[":
                    if let (isMatch, next) = matchClass(p, at: pi, character: s[si]) {
                        if isMatch {
                            pi = next
                            si += 1
                            advanced = true
                        }
                    } else if p[pi] == s[si] {   // unterminated '[' → literal
                        pi += 1
                        si += 1
                        advanced = true
                    }
                case "\\":
                    let literal = pi + 1 < p.count ? p[pi + 1] : "\\"
                    if literal == s[si] {
                        pi += (pi + 1 < p.count ? 2 : 1)
                        si += 1
                        advanced = true
                    }
                default:
                    if p[pi] == s[si] {
                        pi += 1
                        si += 1
                        advanced = true
                    }
                }
            }
            if advanced { continue }
            // Mismatch: let the last `*` swallow one more character.
            guard starPattern >= 0 else { return false }
            starSubject += 1
            si = starSubject
            pi = starPattern + 1
        }

        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Evaluate a `[...]` class starting at `open`. Returns the verdict and
    /// the pattern index just past the closing `]`, or nil if the class is
    /// unterminated (caller treats `[` as a literal).
    private static func matchClass(
        _ pattern: [Character],
        at open: Int,
        character: Character
    ) -> (Bool, Int)? {
        var i = open + 1
        var negated = false
        if i < pattern.count, pattern[i] == "!" || pattern[i] == "^" {
            negated = true
            i += 1
        }
        var found = false
        var first = true
        while i < pattern.count {
            if pattern[i] == "]" && !first {
                return (negated ? !found : found, i + 1)
            }
            first = false
            var lower = pattern[i]
            if lower == "\\", i + 1 < pattern.count {
                i += 1
                lower = pattern[i]
            }
            // Range `a-z` (a trailing `-` before `]` is a literal `-`).
            if i + 2 < pattern.count, pattern[i + 1] == "-", pattern[i + 2] != "]" {
                let upper = pattern[i + 2]
                if character >= lower && character <= upper { found = true }
                i += 3
            } else {
                if character == lower { found = true }
                i += 1
            }
        }
        return nil   // no closing ']'
    }
}
