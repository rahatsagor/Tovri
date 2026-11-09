import XCTest
@testable import Tovri

final class MarkdownRendererTests: XCTestCase {
    private func render(_ text: String) -> String {
        var renderer = MarkdownRenderer(colors: [:])
        return renderer.render(text)
    }

    private func captures(_ pattern: String, in html: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    private func assertValidAnchors(_ html: String, file: StaticString = #filePath, line: UInt = #line) {
        let ids = captures(#"\bid="([^"]+)""#, in: html)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate HTML IDs: \(html)", file: file, line: line)
        for target in captures(##"href="#([^"]+)""##, in: html) {
            XCTAssertTrue(ids.contains(target), "Missing target \(target): \(html)", file: file, line: line)
        }
        XCTAssertFalse(html.contains("<!--tovri-toc-"), "Unresolved TOC: \(html)", file: file, line: line)
    }

    func testTOCUsesRenderedNestedSetextAndDuplicateHeadings() {
        let html = render("""
        [TOC]

        > # Same

        # Same

        Setext title
        ------------

        - ## List heading

        ```markdown
        # Hidden code heading
        ```

        [[TOC]]
        """)
        let ids = captures(#"<h[1-6] id="([^"]+)""#, in: html)
        XCTAssertEqual(ids, ["same", "same-1", "setext-title", "list-heading"])
        let links = captures(##"<li[^>]*><a href="#([^"]+)""##, in: html)
        XCTAssertEqual(links, ids + ids, html)
        assertValidAnchors(html)
    }

    func testGeneratedHeadingAndFootnoteIDsNeverCollide() {
        let html = render("""
        [TOC]

        # A

        # A-1

        # A

        # fn-ab

        # fnref-ab

        Reference[^ab].

        [^ab]: Body.
        """)
        XCTAssertTrue(html.contains("id=\"a-2\""), html)
        assertValidAnchors(html)
    }

    func testTOCLabelsKeepFormattingWithoutCopyingLinksOrReferenceIDs() throws {
        let html = render("""
        [TOC]

        # **Title** [link](https://example.com) ![icon](icon.png) <span id="custom">text</span>[^note]

        [^note]: Body.
        """)
        let start = try XCTUnwrap(html.range(of: "<nav class=\"toc\""))
        let end = try XCTUnwrap(html.range(of: "</nav>"))
        let toc = String(html[start.lowerBound..<end.upperBound])
        XCTAssertTrue(toc.contains("<strong>Title</strong> link icon text"), toc)
        XCTAssertEqual(captures(#"<a href="([^"]+)""#, in: toc).count, 1, toc)
        XCTAssertFalse(toc.contains("footnote-ref"), toc)
        XCTAssertFalse(toc.contains("id=\"custom\""), toc)
        XCTAssertEqual(captures(#"<sup class="footnote-ref"><a[^>]+id="([^"]+)""#, in: html).count, 1)
        assertValidAnchors(html)
    }

    func testDistinctFootnoteLabelsKeepDistinctDefinitionsAndReferences() {
        let html = render("""
        First[^a.b], second[^ab], third[^a-b], fourth[^a b], fifth[^!!!], sixth[^???].

        [^a.b]: First body.
        [^ab]: Second body.
        [^a-b]: Third body.
        [^a b]: Fourth body.
        [^!!!]: Fifth body.
        [^???]: Sixth body.
        """)
        let definitions = captures(#"<li id="([^"]+)""#, in: html)
        let targets = captures(##"<sup class="footnote-ref"><a href="#([^"]+)""##, in: html)
        XCTAssertEqual(definitions.count, 6)
        XCTAssertEqual(targets, definitions)
        assertValidAnchors(html)
    }

    func testNestedFootnotesAreNumberedBeforeUnusedDefinitions() {
        let html = render("""
        Text[^a].

        [^b]: Unused.
        [^a]: A refers to C[^c].
        [^c]: C body.
        """)
        XCTAssertEqual(captures(#"<li id="([^"]+)""#, in: html), ["fn-a", "fn-c", "fn-b"])
        XCTAssertTrue(html.contains("href=\"#fn-c\" id=\"fnref-c\">[2]</a>"), html)
        assertValidAnchors(html)
    }

    func testCyclicFootnotesRenderEachDefinitionOnce() {
        let html = render("""
        Text[^a].

        [^a]: A refers to itself[^a] and B[^b].
        [^b]: B refers back to A[^a].
        """)
        XCTAssertEqual(captures(#"<li id="([^"]+)""#, in: html), ["fn-a", "fn-b"])
        XCTAssertTrue(html.contains("href=\"#fn-b\" id=\"fnref-b\">[2]</a>"), html)
        assertValidAnchors(html)
    }

    func testRepeatedFootnotesLinkBackToEveryReference() {
        let html = render("""
        One[^note], two[^note], three[^note].

        [^note]: Body.
        """)
        let refs = captures(#"<sup class="footnote-ref"><a[^>]+id="([^"]+)""#, in: html)
        let backrefs = captures(##"<a href="#([^"]+)" class="footnote-backref""##, in: html)
        XCTAssertEqual(refs.count, 3)
        XCTAssertEqual(backrefs, refs)
        assertValidAnchors(html)
    }

    func testUnusedDefinitionsCanReferenceOtherFootnotesWithoutDanglingLinks() {
        let html = render("""
        [^unused]: Refers to another[^other].
        [^other]: Other body.
        """)
        XCTAssertEqual(captures(#"<li id="([^"]+)""#, in: html), ["fn-unused", "fn-other"])
        XCTAssertTrue(html.contains("href=\"#fn-other\" id=\"fnref-other\">[2]</a>"), html)
        assertValidAnchors(html)
    }

    func testRendererReuseResetsHeadingsAndFootnotes() {
        var renderer = MarkdownRenderer(colors: [:])
        _ = renderer.render("[TOC]\n\n# Same\n\nRef[^a].\n\n[^a]: Body.\n")
        let html = renderer.render("[TOC]\n\n# Same\n")
        XCTAssertTrue(html.contains("<h1 id=\"same\""), html)
        XCTAssertFalse(html.contains("footnotes"), html)
        XCTAssertFalse(html.contains("fn-a"), html)
        assertValidAnchors(html)
    }
}
