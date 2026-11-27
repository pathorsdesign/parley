import Foundation

/// The per-word filler tally of the post-meeting 評分 report — a port of the
/// desktop's `src/lib/analysis/fillerWords.ts` (`countFillersByWord`,
/// `topFillers`), kept faithful so the phone and the Mac count the same
/// transcript the same way.
///
/// Three families, each folded onto one label per word:
/// - the lexical crutch words of the shared vocabulary (`shared/prompts/study.json`
///   `fillerWords`, both languages since speakers code-switch), longest entry
///   first so 就是說 never also counts 就是;
/// - the non-lexical hesitation sounds ("ummm" → um, 嗯嗯 → 嗯);
/// - rapid-fire agreement runs (對對對), a crutch in neither list.
///
/// Every regex runs over the string's UTF-16 view, as JavaScript's do, so match
/// positions and the "Latin word inside a longer word" check line up with the
/// desktop. JavaScript's `\b` only knows ASCII word characters while ICU's knows
/// every script, so the boundaries are spelled out as ASCII lookarounds: a 嗯
/// right before "um" is a boundary on the Mac and has to be one here too.
public enum FillerWords {
    /// The lexical vocabulary, as `shared/prompts/study.json` (`fillerWords`)
    /// has it. A test reads that file and fails when the two drift.
    public static let lexicon: [String: [String]] = [
        "zh-TW": [
            "那個", "這個", "就是", "就是說", "然後", "反正", "其實", "基本上", "怎麼講", "怎麼說",
            "你知道", "你知道嗎", "你懂嗎", "對不對", "對啊對啊", "這樣子", "之類的", "什麼的",
            "老實說", "說真的", "的部分", "的話",
        ],
        "en": [
            "like", "you know", "i mean", "basically", "actually", "literally", "sort of",
            "kind of", "kinda", "sorta", "you see", "i guess", "right?", "so yeah",
            "to be honest", "at the end of the day", "or whatever", "and stuff",
        ],
    ]

    /// JavaScript's `\b`: between an ASCII word character and anything else.
    static let wordBoundary =
        "(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"

    // MARK: hesitation sounds

    /// Latin hesitation shapes, index-aligned with `latinLabels`.
    private static let latinShapes = [
        "u+m+", "u+h+", "uh+m+", "e+r+m*", "h+m+", "m+m+", "a+h+", "e+h+",
    ]
    private static let latinLabels = ["um", "uh", "uhm", "er", "hmm", "mm", "ah", "eh"]

    /// Unambiguous Mandarin hesitation characters — a run of these is filler.
    private static let cjkFillerChars = "嗯唔呃痾疴欸誒呣"
    /// Particles that only read as hesitation when repeated (啊啊 / 喔喔).
    private static let cjkParticleChars = "啊喔哦呀"

    private static let soundPatterns: [NSRegularExpression] =
        latinShapes.map { regex("\(wordBoundary)(?:\($0))\(wordBoundary)", caseInsensitive: true) }
        + [
            regex("[\(cjkFillerChars)]+"),
            regex("([\(cjkParticleChars)])\\1+"),
        ]

    /// Three or more 對 in a row; two reads as an ordinary confirmation.
    private static let agreementRun = regex("對(?:[\\s,，、]*對){2,}")
    private static let agreementLabel = "對對對"

    // MARK: lexical words

    /// One alternation over every lexical filler, longest first (UTF-16 length,
    /// as the desktop sorts), so the engine prefers 就是說 over 就是.
    private static let lexicalPattern: NSRegularExpression = {
        var seen = Set<String>()
        var words: [String] = []
        for word in (lexicon["zh-TW"] ?? []) + (lexicon["en"] ?? []) {
            let lower = word.lowercased()
            if seen.insert(lower).inserted { words.append(lower) }
        }
        let ordered = words.enumerated()
            .sorted { a, b in
                let la = a.element.utf16.count
                let lb = b.element.utf16.count
                return la != lb ? la > lb : a.offset < b.offset
            }
            .map { NSRegularExpression.escapedPattern(for: $0.element) }
        return regex("(?:\(ordered.joined(separator: "|")))", caseInsensitive: true)
    }()

    // MARK: counting

    /// Tally every filler in a transcript fragment by label, adding into
    /// `counts` so a caller can fold a whole transcript into one map.
    public static func countByWord(_ text: String, into counts: inout [String: Int]) {
        guard !text.isEmpty else { return }
        let ns = text as NSString
        for (index, re) in soundPatterns.enumerated() {
            tally(re, ns, label: { soundLabel(index, ns.substring(with: $0.range)) }, into: &counts)
        }
        tally(agreementRun, ns, label: { _ in agreementLabel }, into: &counts)
        tally(lexicalPattern, ns, label: { lexicalLabel($0, ns) }, into: &counts)
    }

    /// The same, into a fresh map.
    public static func countByWord(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        countByWord(text, into: &counts)
        return counts
    }

    /// The `limit` most frequent fillers, most frequent first; ties go to the
    /// longer label, then alphabetical, so the order is stable.
    public static func top(_ counts: [String: Int], limit: Int = 5) -> [FillerCount] {
        let sorted = counts
            .filter { $0.value > 0 }
            .map { FillerCount(word: $0.key, count: $0.value) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                let la = a.word.utf16.count
                let lb = b.word.utf16.count
                if la != lb { return la > lb }
                return a.word.compare(b.word, locale: Locale(identifier: "en")) == .orderedAscending
            }
        return Array(sorted.prefix(max(0, limit)))
    }

    private static func tally(
        _ re: NSRegularExpression, _ text: NSString,
        label: (NSTextCheckingResult) -> String?, into counts: inout [String: Int]
    ) {
        for match in re.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            if let l = label(match) { counts[l, default: 0] += 1 }
        }
    }

    /// A hesitation-sound match, folded to its label.
    private static func soundLabel(_ patternIndex: Int, _ match: String) -> String {
        if patternIndex < latinLabels.count { return latinLabels[patternIndex] }
        // CJK runs: the first character names it (嗯嗯嗯 → 嗯); a repeated
        // particle keeps its doubled form (啊啊), since a single 啊 is not one.
        let first = match.unicodeScalars.first.map { String($0) } ?? match
        return patternIndex == latinLabels.count ? first : first + first
    }

    /// The label for a lexical match, or nil when a Latin entry sits inside a
    /// longer word ("like" in "likely").
    private static func lexicalLabel(_ m: NSTextCheckingResult, _ text: NSString) -> String? {
        let word = text.substring(with: m.range)
        if word.utf16.contains(where: isASCIILetter) {
            let before = m.range.location > 0 ? text.character(at: m.range.location - 1) : nil
            let afterIndex = m.range.location + m.range.length
            let after = afterIndex < text.length ? text.character(at: afterIndex) : nil
            if let before, isWordChar(before) { return nil }
            if let after, isWordChar(after) { return nil }
        }
        return word.lowercased()
    }

    private static func isASCIILetter(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }

    /// `[a-z0-9']`, case-insensitively.
    private static func isWordChar(_ c: unichar) -> Bool {
        isASCIILetter(c) || (c >= 48 && c <= 57) || c == 39
    }

    static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // The patterns are constants; one that fails to compile is a bug to
        // catch on the first test run, not a state to recover from.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
}

/// A filler label and how often it came up.
public struct FillerCount: Equatable, Sendable, Hashable {
    public let word: String
    public let count: Int

    public init(word: String, count: Int) {
        self.word = word
        self.count = count
    }
}
