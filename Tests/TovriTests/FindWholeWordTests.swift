import AppKit
import XCTest
@testable import Tovri

final class FindWholeWordTests: XCTestCase {
    private func matches(_ query: String, in text: String, regex: Bool = false) -> [String] {
        let st = FindState()
        st.wholeWord = true
        st.regex = regex
        guard let re = st.makeRegex(query: query) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    func testWholeWordPatternMatchesQueriesWithPunctuationAtTheEdges() {
        XCTAssertEqual(matches("$var", in: "$var $variable x$var $var."), ["$var", "$var"])
        XCTAssertEqual(matches("foo.", in: "foo. foo.bar (foo.)"), ["foo.", "foo."])
        XCTAssertEqual(matches("name", in: "name names _name café_name name"), ["name", "name"])
        XCTAssertEqual(matches("é", in: "é aé é"), ["é", "é"])
        XCTAssertEqual(matches("a|b", in: "a ab b", regex: true), ["a", "b"])
    }
}
