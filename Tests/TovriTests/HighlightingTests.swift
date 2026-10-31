import AppKit
import XCTest
@testable import Tovri

final class HighlightingTests: XCTestCase {
    // MARK: - Swift

    func testSwiftDeclarationsTypesAndAttributes() {
        let h = Highlighted("swift", #"""
        import Foundation
        @MainActor final class Store<T>: ObservableObject where T: Hashable {
            private(set) var items: [T] = []
            func add(_ item: T) async throws -> Int { return 0 }
        }
        #if DEBUG
        print(nil, true, self)
        #endif
        """#)
        XCTAssertKind(h, "import", .keyword)
        XCTAssertKind(h, "@MainActor", .annotation)
        XCTAssertKind(h, "final", .storage)
        XCTAssertKind(h, "class", .storage)
        XCTAssertKind(h, "Store", .type)
        XCTAssertKind(h, "ObservableObject", .type)
        XCTAssertKind(h, "where", .keyword)
        XCTAssertKind(h, "Hashable", .type)
        XCTAssertKind(h, "func", .storage)
        XCTAssertKind(h, "add", .function)
        XCTAssertKind(h, "throws", .keyword)
        XCTAssertKind(h, "Int", .type)
        XCTAssertKind(h, "#if", .preprocessor)
        XCTAssertKind(h, "#endif", .preprocessor)
        XCTAssertKind(h, "print", .builtin)
        XCTAssertKind(h, "nil", .constant)
        XCTAssertKind(h, "true", .constant)
        XCTAssertKind(h, "items", .plain)
    }

    func testSwiftStringsEscapesInterpolationAndRawStrings() {
        let h = Highlighted("swift", #"""
        let s = "Hello \(user.name)!\n\u{1F600}"
        let d = "key: \(dict["k"] ?? "none") end"
        let raw = #"raw \n "quoted" \(x)"#
        let multi = """
            line \(count) "inner"
            """
        let after = 1
        """#)
        XCTAssertKind(h, "\"Hello ", .string)
        XCTAssertKind(h, #"\("#, .punctuation)
        XCTAssertKind(h, "user.name", .plain)
        XCTAssertKind(h, #"\n\u{1F600}"#, .escape)
        XCTAssertKind(h, "!", .string)
        XCTAssertKind(h, #""k""#, .string)
        XCTAssertKind(h, "??", .operatorSymbol)
        XCTAssertKind(h, #""none""#, .string)
        XCTAssertKind(h, " end\"", .string)
        XCTAssertKind(h, ##"#"raw \n "quoted" \(x)"#"##, .string)
        XCTAssertKind(h, "    line ", .string)
        XCTAssertKind(h, "count", .plain)
        XCTAssertKind(h, #" "inner""#, .string)
        XCTAssertKind(h, #"    """"#, .string)
        XCTAssertLine(h, "let after", "storage«let» after operatorSymbol«=» number«1»")
    }

    func testSwiftNumbersCommentsAndRegexLiterals() {
        let h = Highlighted("swift", #"""
        let n = 0x1F_FF + 1_000.5e-3 + 0b1010 + 0o17
        /* outer /* nested */ still a comment */ let after = 2
        /// Doc comment with "quotes" and 'apostrophes'
        let half = total / 2 / count
        let re = /[a-z]+\d/
        """#)
        XCTAssertKind(h, "0x1F_FF", .number)
        XCTAssertKind(h, "1_000.5e-3", .number)
        XCTAssertKind(h, "0b1010", .number)
        XCTAssertKind(h, "0o17", .number)
        XCTAssertKind(h, "/* outer /* nested */ still a comment */", .comment)
        XCTAssertKind(h, "after", .plain)
        XCTAssertKind(h, "2", .number)
        XCTAssertKind(h, #"/// Doc comment with "quotes" and 'apostrophes'"#, .comment)
        XCTAssertLine(h, "let half", "storage«let» half operatorSymbol«=» total operatorSymbol«/» number«2» operatorSymbol«/» count")
        XCTAssertKind(h, #"/[a-z]+\d/"#, .regex)
    }

    func testSwiftNestedBlockCommentSpansLines() {
        let h = Highlighted("swift", """
        /* level one
           /* level two */
           still level one
        */
        let x = 1
        """)
        XCTAssertKind(h, "still level one", .comment)
        XCTAssertKind(h, "*/", .comment, occurrence: 1)
        XCTAssertKind(h, "let", .storage)
        XCTAssertEqual(h.lineStates[4], 0)
    }

    // MARK: - JavaScript / TypeScript

    func testJavaScriptKeywordsStringsAndNumbers() {
        let h = Highlighted("javascript", #"""
        import { a } from "./mod.js";
        export async function load(url = 'it\'s') {
          const n = 0xFF + 1_000_000 + 1.5e10 + .5 + 10n;
          return await fetch(url)?.json() ?? null;
        }
        class A extends B { static get v() { return this.x; } }
        """#)
        XCTAssertKind(h, "import", .keyword)
        XCTAssertKind(h, "from", .keyword)
        XCTAssertKind(h, #""./mod.js""#, .string)
        XCTAssertKind(h, "export", .keyword)
        XCTAssertKind(h, "async", .storage)
        XCTAssertKind(h, "function", .storage)
        XCTAssertKind(h, "load", .function)
        XCTAssertKind(h, "'it", .string)
        XCTAssertKind(h, #"\'"#, .escape)
        XCTAssertKind(h, "s'", .string)
        XCTAssertKind(h, "const", .storage)
        for n in ["0xFF", "1_000_000", "1.5e10", ".5", "10n"] { XCTAssertKind(h, n, .number) }
        XCTAssertKind(h, "await", .keyword)
        XCTAssertKind(h, "fetch", .builtin)
        XCTAssertKind(h, "json", .function)
        XCTAssertKind(h, "??", .operatorSymbol)
        XCTAssertKind(h, "null", .constant)
        XCTAssertKind(h, "A", .type)
        XCTAssertKind(h, "extends", .storage)
        XCTAssertKind(h, "this", .constant)
    }

    func testJavaScriptRegexVersusDivision() {
        let h = Highlighted("javascript", #"""
        const re = /ab+c\/d[/]x/gi;
        const q = a / 2 / b;
        const m = x.map(y => y / 2);
        if (ok) return /^\s*$/.test(s);
        const r = s.replace(/"/g, "'");
        """#)
        XCTAssertKind(h, #"/ab+c\/d[/]x/gi"#, .regex)
        XCTAssertLine(h, "const q", "storage«const» q operatorSymbol«=» a operatorSymbol«/» number«2» operatorSymbol«/» b;")
        XCTAssertLine(h, "const m", "storage«const» m operatorSymbol«=» x.function«map»(y operatorSymbol«=>» y operatorSymbol«/» number«2»);")
        XCTAssertKind(h, #"/^\s*$/"#, .regex)
        XCTAssertKind(h, #"/"/g"#, .regex)
        XCTAssertKind(h, #""'""#, .string)
    }

    func testJavaScriptTemplateLiteralsWithNestedInterpolation() {
        let h = Highlighted("javascript", #"""
        const t = `sum: ${a + b} and ${cond ? `yes ${x}` : 'no'} tail`;
        const e = `\${literal} ${ {k: 1}.k }`;
        const multi = `first
        second ${value}
        third`;
        const after = 1;
        """#)
        XCTAssertKind(h, "`sum: ", .string)
        XCTAssertKind(h, "${", .punctuation)
        XCTAssertKind(h, "+", .operatorSymbol)
        XCTAssertKind(h, " and ", .string)
        XCTAssertKind(h, "?", .operatorSymbol)
        XCTAssertKind(h, "`yes ", .string)
        XCTAssertKind(h, "'no'", .string)
        XCTAssertKind(h, " tail`", .string)
        XCTAssertKind(h, ";", .plain)
        XCTAssertKind(h, #"\$"#, .escape)
        XCTAssertKind(h, "{literal} ", .string)
        XCTAssertKind(h, "1", .number)
        XCTAssertKind(h, "first", .string)
        XCTAssertKind(h, "second ", .string)
        XCTAssertKind(h, "value", .plain)
        XCTAssertKind(h, "third`", .string)
        XCTAssertKind(h, "const", .storage, occurrence: 3)
        XCTAssertKind(h, "1", .number, occurrence: 1)
    }

    func testJavaScriptCommentsDoNotHideCodeAndCarryAcrossLines() {
        let h = Highlighted("javascript", #"""
        // it's a line comment with "quotes"
        /** JSDoc @param {string} x */
        /* start
           middle 'quote' and `tick`
        end */ const d = "x";
        """#)
        XCTAssertKind(h, #"// it's a line comment with "quotes""#, .comment)
        XCTAssertKind(h, "/** JSDoc @param {string} x */", .comment)
        XCTAssertKind(h, "   middle 'quote' and `tick`", .comment)
        XCTAssertKind(h, "end */", .comment)
        XCTAssertKind(h, "const", .storage)
        XCTAssertKind(h, #""x""#, .string)
    }

    func testTypeScriptTypesAndDecorators() {
        let h = Highlighted("typescript", #"""
        interface User { name: string; age?: number }
        type Id = string | number;
        enum Color { Red = 1 }
        @Component({ selector: 'app' })
        export class C implements I { private readonly x: Readonly<User> = null as any; }
        """#)
        XCTAssertKind(h, "interface", .storage)
        XCTAssertKind(h, "User", .type)
        XCTAssertKind(h, "string", .type)
        XCTAssertKind(h, "number", .type)
        XCTAssertKind(h, "type", .storage)
        XCTAssertKind(h, "Id", .type)
        XCTAssertKind(h, "enum", .storage)
        XCTAssertKind(h, "Color", .type)
        XCTAssertKind(h, "@Component", .annotation)
        XCTAssertKind(h, "'app'", .string)
        XCTAssertKind(h, "implements", .storage)
        XCTAssertKind(h, "readonly", .storage)
        XCTAssertKind(h, "Readonly", .type)
        XCTAssertKind(h, "any", .type)
    }

    func testJSXAndTSXKeepCodeHighlighting() {
        let jsx = Highlighted("jsx", #"const el = <Button disabled={x / 2 > 1} label="Go">{`n: ${n}`}</Button>;"#)
        XCTAssertKind(jsx, "const", .storage)
        XCTAssertKind(jsx, "Button", .type)
        XCTAssertKind(jsx, #""Go""#, .string)
        XCTAssertKind(jsx, "/", .operatorSymbol)
        XCTAssertKind(jsx, "`n: ", .string)
        XCTAssertKind(jsx, "${", .punctuation)

        let tsx = Highlighted("tsx", #"""
        export const App = ({ title }: Props): JSX.Element => {
          return <div className="app" onClick={() => go(1)}>{title}</div>;
        };
        """#)
        XCTAssertKind(tsx, "export", .keyword)
        XCTAssertKind(tsx, "Props", .type)
        XCTAssertKind(tsx, #""app""#, .string)
        XCTAssertKind(tsx, "go", .function)
        XCTAssertKind(tsx, "1", .number)
    }

    // MARK: - Python

    func testPythonKeywordsDecoratorsAndBuiltins() {
        let h = Highlighted("python", #"""
        from typing import List
        @dataclass(frozen=True)
        class Foo(Base):
            async def bar(self, s: str = "a # b") -> List[int]:
                return [i for i in range(10) if i % 2]  # trailing
        print(None, __name__)
        """#)
        XCTAssertKind(h, "from", .keyword)
        XCTAssertKind(h, "import", .keyword)
        XCTAssertKind(h, "List", .type)
        XCTAssertKind(h, "@dataclass", .annotation)
        XCTAssertKind(h, "True", .constant)
        XCTAssertKind(h, "class", .storage, occurrence: 1)
        XCTAssertKind(h, "Foo", .type)
        XCTAssertKind(h, "Base", .type)
        XCTAssertKind(h, "async", .storage)
        XCTAssertKind(h, "def", .storage)
        XCTAssertKind(h, "bar", .function)
        XCTAssertKind(h, "self", .constant)
        XCTAssertKind(h, "str", .type)
        XCTAssertKind(h, #""a # b""#, .string)
        XCTAssertKind(h, "return", .keyword)
        XCTAssertKind(h, "for", .keyword)
        XCTAssertKind(h, "# trailing", .comment)
        XCTAssertKind(h, "print", .builtin)
        XCTAssertKind(h, "None", .constant)
    }

    func testPythonStringPrefixesRawBytesAndFStrings() {
        let h = Highlighted("python", #"""
        z = r"C:\path\n" + b'bytes\x00' + rb"\d+" + r'\'' + "tab\t"
        y = f"value {s!r} {d['k']:>10} {{literal}}"
        u = "plain {not_interpolated}"
        v = rf"\d{n}"
        """#)
        XCTAssertKind(h, #"r"C:\path\n""#, .string)
        XCTAssertKind(h, "b'bytes", .string)
        XCTAssertKind(h, #"\x00"#, .escape)
        XCTAssertKind(h, #"rb"\d+""#, .string)
        XCTAssertKind(h, #"r'\''"#, .string)
        XCTAssertKind(h, #"\t"#, .escape)
        XCTAssertLine(h, "y = f", #"y operatorSymbol«=» string«f"value »punctuation«{»soperatorSymbol«!»rpunctuation«}»string« »punctuation«{»d[string«'k'»]operatorSymbol«:>»number«10»punctuation«}»string« {{literal}}"»"#)
        XCTAssertKind(h, "\"plain {not_interpolated}\"", .string)
        XCTAssertLine(h, "v = rf", #"v operatorSymbol«=» string«rf"\d»punctuation«{»npunctuation«}»string«"»"#)
    }

    func testPythonTripleQuotedStringsAndHashInStrings() {
        let h = Highlighted("python", #"""
        """Module docstring with # not a comment
        and 'quotes' on a second line"""
        x = 0x_ff + 1_000 + 3.14e-2 + 10j
        s = '''single # triple'''
        t = "#not comment"  # real comment
        """#)
        XCTAssertKind(h, "\"\"\"Module docstring with # not a comment", .string)
        XCTAssertKind(h, "and 'quotes' on a second line\"\"\"", .string)
        for n in ["0x_ff", "1_000", "3.14e-2", "10j"] { XCTAssertKind(h, n, .number) }
        XCTAssertKind(h, "'''single # triple'''", .string)
        XCTAssertKind(h, "\"#not comment\"", .string)
        XCTAssertKind(h, "# real comment", .comment)
        XCTAssertEqual(h.lineStates[2], 0)
    }

    // MARK: - Go

    func testGo() {
        let h = Highlighted("go", #"""
        package main
        import "fmt"
        // Point is a point.
        type Point struct { X, Y int }
        func (p *Point) Add(o Point) Point {
        	s := `raw \n
        multi`
        	r := 'x'
        	n := 0x1F + 1_000 + 1.5e3 + 0o17
        	fmt.Println("hi\t", s, r, n, nil, len(s))
        	return Point{}
        }
        """#)
        XCTAssertKind(h, "package", .keyword)
        XCTAssertKind(h, #""fmt""#, .string)
        XCTAssertKind(h, "// Point is a point.", .comment)
        XCTAssertLine(h, "type Point", "storage«type» type«Point» storage«struct» { type«X», type«Y» type«int» }")
        XCTAssertKind(h, "func", .storage)
        XCTAssertKind(h, "Add", .function)
        XCTAssertKind(h, #"`raw \n"#, .string)
        XCTAssertKind(h, "multi`", .string)
        XCTAssertKind(h, "'x'", .string)
        for n in ["0x1F", "1_000", "1.5e3", "0o17"] { XCTAssertKind(h, n, .number) }
        XCTAssertKind(h, "Println", .function)
        XCTAssertKind(h, #"\t"#, .escape)
        XCTAssertKind(h, "nil", .constant)
        XCTAssertKind(h, "len", .builtin)
        XCTAssertKind(h, "return", .keyword)
    }

    // MARK: - Rust

    func testRustLifetimesCharsAndAttributes() {
        let h = Highlighted("rust", #"""
        #[derive(Debug, Clone)]
        pub struct Foo<'a> { s: &'a str }
        fn main() {
            let c = 'x'; let e = '\n'; let u = '\u{1F600}'; let bc = b'a';
            'outer: loop { break 'outer; }
            println!("{}", c);
        }
        """#)
        XCTAssertKind(h, "#[derive(Debug, Clone)]", .annotation)
        XCTAssertKind(h, "pub", .storage)
        XCTAssertKind(h, "'a", .annotation)
        XCTAssertKind(h, "'a", .annotation, occurrence: 1)
        XCTAssertKind(h, "str", .type, occurrence: 1)
        XCTAssertKind(h, "fn", .storage)
        XCTAssertKind(h, "main", .function)
        XCTAssertKind(h, "'x'", .string)
        XCTAssertKind(h, #"\n"#, .escape)
        XCTAssertKind(h, #"\u{1F600}"#, .escape)
        XCTAssertKind(h, "b'a'", .string)
        XCTAssertKind(h, "'outer", .annotation)
        XCTAssertKind(h, "loop", .keyword)
        XCTAssertKind(h, "'outer", .annotation, occurrence: 1)
        XCTAssertKind(h, "println", .builtin)
        XCTAssertKind(h, #""{}""#, .string)
    }

    func testRustStringsRawStringsNumbersAndNestedComments() {
        let h = Highlighted("rust", ##"""
        let s = "esc \" \n";
        let raw = r#"raw "quoted" \n"#;
        let hashes = r##"has "# inside"##;
        let path = r"C:\dir\"; let next = 1;
        let b = b"bytes"; let t = br#"bytes"#;
        let multi = r#"line
        one"#;
        let n = 0xFF_u8 + 1_000i32 + 1.5e-3f64;
        /* outer /* nested */ still */ let z = 1;
        """##)
        XCTAssertKind(h, #"\""#, .escape)
        XCTAssertKind(h, ##"r#"raw "quoted" \n"#"##, .string)
        XCTAssertKind(h, ###"r##"has "# inside"##"###, .string)
        XCTAssertKind(h, #"r"C:\dir\""#, .string)
        XCTAssertKind(h, "let", .storage, occurrence: 4)
        XCTAssertKind(h, "next", .plain)
        XCTAssertKind(h, "b\"bytes\"", .string)
        XCTAssertKind(h, ##"br#"bytes"#"##, .string)
        XCTAssertKind(h, "r#\"line", .string)
        XCTAssertKind(h, "one\"#", .string)
        for n in ["0xFF_u8", "1_000i32", "1.5e-3f64"] { XCTAssertKind(h, n, .number) }
        XCTAssertKind(h, "/* outer /* nested */ still */", .comment)
        XCTAssertKind(h, "z", .plain)
    }

    // MARK: - JVM

    func testJava() {
        let h = Highlighted("java", #"""
        package com.example;
        /** Javadoc {@link Foo} */
        @Override
        public final class Main {
            public static void main(String[] args) {
                char c = 'c';
                long n = 0xFFL + 1_000L + 1.5e3d + 3.0f;
                String block = """
                    Hello "text" \t
                    """;
                System.out.println(null);
            }
        }
        """#)
        XCTAssertKind(h, "package", .keyword)
        XCTAssertKind(h, "/** Javadoc {@link Foo} */", .comment)
        XCTAssertKind(h, "@Override", .annotation)
        XCTAssertKind(h, "public", .storage)
        XCTAssertKind(h, "class", .storage)
        XCTAssertKind(h, "Main", .type)
        XCTAssertKind(h, "void", .type)
        XCTAssertKind(h, "main", .function)
        XCTAssertKind(h, "String", .type)
        XCTAssertKind(h, "'c'", .string)
        for n in ["0xFFL", "1_000L", "1.5e3d", "3.0f"] { XCTAssertKind(h, n, .number) }
        XCTAssertKind(h, "Hello \"text\" ", .string)
        XCTAssertKind(h, #"\t"#, .escape)
        XCTAssertKind(h, "null", .constant)
        XCTAssertEqual(h.lineStates[10], 0)
    }

    func testKotlinStringTemplates() {
        let h = Highlighted("kotlin", #"""
        @Suppress("unused")
        data class User(val name: String, var age: Int = 0)
        fun main() {
            val s = "Hello $name and ${user.age + 1} ${map["k"]}"
            val price = "\$5"
            val raw = """
                raw $name ${1 + 2}
            """
            /* a /* nested */ b */ val c = 'c'
            println(s)
        }
        """#)
        XCTAssertKind(h, "@Suppress", .annotation)
        XCTAssertKind(h, "data", .storage)
        XCTAssertKind(h, "User", .type)
        XCTAssertKind(h, "fun", .storage)
        XCTAssertKind(h, "main", .function)
        XCTAssertKind(h, "\"Hello ", .string)
        XCTAssertKind(h, "$name", .variable)
        XCTAssertKind(h, "${", .punctuation)
        XCTAssertKind(h, "+", .operatorSymbol, occurrence: 0)
        XCTAssertKind(h, "1", .number, occurrence: 0)
        XCTAssertKind(h, #""k""#, .string)
        XCTAssertKind(h, #"\$"#, .escape)
        XCTAssertKind(h, "5\"", .string)
        XCTAssertKind(h, "        raw ", .string)
        XCTAssertKind(h, "$name", .variable, occurrence: 1)
        XCTAssertKind(h, "2", .number)
        XCTAssertKind(h, "/* a /* nested */ b */", .comment)
        XCTAssertKind(h, "'c'", .string)
        XCTAssertKind(h, "println", .builtin)
    }

    // MARK: - C family

    func testC() {
        let h = Highlighted("c", #"""
        #include <stdio.h>
        #define MAX(a, b) ((a) > (b) ? (a) : (b))
        /* block
           comment with "string" */
        static int count = 0x1F;
        int main(int argc, char **argv) {
            char c = '\n'; wchar_t w = L'w';
            const char *s = "hello \"world\"\n";
            float f = 1.5e-3f; unsigned long u = 10UL;
            printf("%d\n", MAX(1, 2)); // trailing
            return NULL;
        }
        """#)
        XCTAssertKind(h, "#include", .preprocessor)
        XCTAssertKind(h, "<stdio.h>", .string)
        XCTAssertKind(h, "#define", .preprocessor)
        XCTAssertKind(h, "   comment with \"string\" */", .comment)
        XCTAssertKind(h, "static", .storage)
        XCTAssertKind(h, "int", .type)
        XCTAssertKind(h, "0x1F", .number)
        XCTAssertKind(h, "main", .function)
        XCTAssertKind(h, "char", .type, occurrence: 1)
        XCTAssertKind(h, #"\n"#, .escape)
        XCTAssertKind(h, "L'w'", .string)
        XCTAssertKind(h, #"\"\n"#, .escape)
        XCTAssertKind(h, "1.5e-3f", .number)
        XCTAssertKind(h, "10UL", .number)
        XCTAssertKind(h, "printf", .builtin)
        XCTAssertKind(h, "// trailing", .comment)
        XCTAssertKind(h, "return", .keyword)
        XCTAssertKind(h, "NULL", .constant)
    }

    func testCpp() {
        let h = Highlighted("cpp", #"""
        #include <vector>
        namespace app {
        template <typename T>
        class Box : public Base {
        public:
            explicit Box(T v) : value(v) {}
            auto get() const -> T { return value; }
        };
        }
        auto raw = R"(raw \n "string")";
        auto x = u8"utf8"; std::string s = "s"; int n = 1'000'000; int h = 0xFF'FF;
        auto l = [](int a) noexcept { return a * 2; };
        """#)
        XCTAssertKind(h, "namespace", .storage)
        XCTAssertKind(h, "template", .storage)
        XCTAssertKind(h, "typename", .storage)
        XCTAssertKind(h, "class", .storage)
        XCTAssertKind(h, "Box", .type)
        XCTAssertKind(h, "explicit", .storage)
        XCTAssertKind(h, "const", .storage)
        XCTAssertKind(h, #"R"(raw \n "string")""#, .string)
        XCTAssertKind(h, #"u8"utf8""#, .string)
        XCTAssertKind(h, "std", .builtin)
        XCTAssertKind(h, "string", .type, occurrence: 1)
        XCTAssertKind(h, "1'000'000", .number)
        XCTAssertKind(h, "0xFF'FF", .number)
        XCTAssertKind(h, "noexcept", .keyword)
    }

    func testCSharp() {
        let h = Highlighted("csharp", #"""
        using System;
        /// <summary>Doc</summary>
        public sealed class Foo : IBar {
            public async Task<int> RunAsync(string name) {
                var s = $"Hello {name}! {{literal}} {value:N2}";
                var v = @"C:\path\";
                var both = $@"C:\{dir}\file";
                var q = @"say ""hi""";
                char c = 'c';
                #region Stuff
                return 0x1F + 1_000 + (int)1.5e3m;
            }
        }
        """#)
        XCTAssertKind(h, "using", .keyword)
        XCTAssertKind(h, "/// <summary>Doc</summary>", .comment)
        XCTAssertKind(h, "sealed", .storage)
        XCTAssertKind(h, "Foo", .type)
        XCTAssertKind(h, "async", .storage)
        XCTAssertKind(h, "Task", .type)
        XCTAssertKind(h, "RunAsync", .function)
        XCTAssertKind(h, "$\"Hello ", .string)
        XCTAssertKind(h, "{", .punctuation, occurrence: 2)
        XCTAssertKind(h, "name", .plain, occurrence: 1)
        XCTAssertKind(h, "! {{literal}} ", .string)
        XCTAssertKind(h, #"@"C:\path\""#, .string)
        XCTAssertKind(h, "var", .storage, occurrence: 2)
        XCTAssertKind(h, #"$@"C:\"#, .string)
        XCTAssertKind(h, "dir", .plain)
        XCTAssertKind(h, #"\file""#, .string)
        XCTAssertKind(h, #"@"say ""hi""""#, .string)
        XCTAssertKind(h, "'c'", .string)
        XCTAssertKind(h, "#region", .preprocessor)
        XCTAssertKind(h, "0x1F", .number)
        XCTAssertKind(h, "1.5e3m", .number)
    }

    // MARK: - PHP / Ruby / Shell

    func testPHP() {
        let h = Highlighted("php", #"""
        <?php
        // comment
        # hash comment
        class User extends Model {
            public function name(string $x): ?string {
                $s = "Hello $x and {$this->name}\n";
                $t = 'single $x';
                return $s . PHP_EOL;
            }
        }
        $doc = <<<EOT
          heredoc 'it's' # not a comment
          EOT;
        $now = <<<'NOW'
        raw
        NOW;
        echo $doc;
        """#)
        XCTAssertKind(h, "// comment", .comment)
        XCTAssertKind(h, "# hash comment", .comment)
        XCTAssertKind(h, "class", .storage)
        XCTAssertKind(h, "function", .storage)
        XCTAssertKind(h, "name", .function)
        XCTAssertKind(h, "$x", .variable)
        XCTAssertKind(h, "\"Hello ", .string)
        XCTAssertKind(h, "$x", .variable, occurrence: 1)
        XCTAssertKind(h, "$this", .variable)
        XCTAssertKind(h, #"\n"#, .escape)
        XCTAssertKind(h, "'single $x'", .string)
        XCTAssertKind(h, "PHP_EOL", .constant)
        XCTAssertKind(h, "EOT", .string)
        XCTAssertKind(h, "  heredoc 'it's' # not a comment", .string)
        XCTAssertKind(h, "EOT", .string, occurrence: 1)
        XCTAssertKind(h, "'NOW'", .string)
        XCTAssertKind(h, "raw", .string)
        XCTAssertKind(h, "echo", .keyword)
        XCTAssertKind(h, "$doc", .variable, occurrence: 1)
    }

    func testRuby() {
        let h = Highlighted("ruby", #"""
        # comment
        class Foo < Bar
          def initialize(name)
            @name = name
            @@count = 0
            $global = "str #{h["key"]} \n"
            s = 'single #{not}'
            n = 0x1F + 1_000 + 1.5e3
            arr << item
          end
          def valid? = !@name.nil?
          class << self; end
        end
        =begin
        block comment
        =end
        x = <<~HEREDOC
          text #{x} it's
        HEREDOC
        sql = <<-SQL.strip
          SELECT 1
          SQL
        puts x
        """#)
        XCTAssertKind(h, "# comment", .comment)
        XCTAssertKind(h, "Foo", .type)
        XCTAssertKind(h, "def", .storage)
        XCTAssertKind(h, "initialize", .function)
        XCTAssertKind(h, "@name", .variable)
        XCTAssertKind(h, "@@count", .variable)
        XCTAssertKind(h, "$global", .variable)
        XCTAssertKind(h, "\"str ", .string)
        XCTAssertKind(h, "#{", .punctuation)
        XCTAssertKind(h, #""key""#, .string)
        XCTAssertKind(h, #"\n"#, .escape)
        XCTAssertKind(h, "'single #{not}'", .string)
        XCTAssertKind(h, "1_000", .number)
        XCTAssertKind(h, "<<", .operatorSymbol)
        XCTAssertKind(h, "item", .plain)
        XCTAssertKind(h, "valid?", .function)
        XCTAssertKind(h, "self", .constant)
        XCTAssertKind(h, "block comment", .comment)
        XCTAssertKind(h, "HEREDOC", .string)
        XCTAssertKind(h, "  text #{x} it's", .string)
        XCTAssertKind(h, "HEREDOC", .string, occurrence: 1)
        XCTAssertKind(h, "SQL", .string)
        XCTAssertKind(h, "strip", .plain)
        XCTAssertKind(h, "  SELECT 1", .string)
        XCTAssertKind(h, "puts", .builtin)
        XCTAssertEqual(h.lineStates[h.lineStates.count - 1], 0)
    }

    func testShellStringsVariablesAndComments() {
        let h = Highlighted("shell", #"""
        #!/bin/bash
        set -euo pipefail
        NAME="world # not comment"
        echo "Hello ${NAME} $1 $@ $(date +%s)" # trailing
        echo "$(basename "$file")" done
        echo 'single $NAME' url#frag ${var#prefix} $#
        if [[ -f "$file" ]]; then
          local x=$((1 << 2))
        fi
        """#)
        XCTAssertKind(h, "#!/bin/bash", .comment)
        XCTAssertKind(h, "set", .builtin)
        XCTAssertKind(h, "\"world # not comment\"", .string)
        XCTAssertKind(h, "\"Hello ", .string)
        XCTAssertKind(h, "${NAME}", .variable)
        XCTAssertKind(h, "$1", .variable)
        XCTAssertKind(h, "$@", .variable)
        XCTAssertKind(h, "$(", .punctuation)
        XCTAssertKind(h, "date", .plain)
        XCTAssertKind(h, "# trailing", .comment)
        XCTAssertKind(h, "basename", .plain)
        XCTAssertKind(h, "$file", .variable)
        XCTAssertKind(h, "done", .keyword)
        XCTAssertKind(h, "'single $NAME'", .string)
        XCTAssertKind(h, "url#frag", .plain)
        XCTAssertKind(h, "${var#prefix}", .variable)
        XCTAssertKind(h, "$#", .variable)
        XCTAssertKind(h, "if", .keyword)
        XCTAssertKind(h, "then", .keyword)
        XCTAssertKind(h, "local", .storage)
        XCTAssertKind(h, "<<", .operatorSymbol)
        XCTAssertKind(h, "fi", .keyword, occurrence: 3)
        XCTAssertEqual(h.lineStates.last, 0)
    }

    func testShellHeredocs() {
        let h = Highlighted("shell", #"""
        cat <<EOF > out.txt
        it's here $NAME # not a comment
        EOF
        cat <<-'END'
        	"unbalanced
        	END
        cat << "SPACED"
        body
        SPACED
        grep foo <<< "$input"
        echo done
        """#)
        XCTAssertKind(h, "<<", .operatorSymbol)
        XCTAssertKind(h, "EOF", .string)
        XCTAssertKind(h, "out.txt", .plain)
        XCTAssertKind(h, "it's here $NAME # not a comment", .string)
        XCTAssertKind(h, "EOF", .string, occurrence: 1)
        XCTAssertKind(h, "<<-", .operatorSymbol)
        XCTAssertKind(h, "'END'", .string)
        XCTAssertKind(h, "\"unbalanced", .string)
        XCTAssertKind(h, "END", .string, occurrence: 1)
        XCTAssertKind(h, "\"SPACED\"", .string)
        XCTAssertKind(h, "body", .string)
        XCTAssertKind(h, "<<<", .operatorSymbol)
        XCTAssertKind(h, "$input", .variable)
        XCTAssertLine(h, "echo done", "builtin«echo» keyword«done»")
        XCTAssertEqual(h.lineStates.last, 0)
    }

    // MARK: - Markup and styles

    func testHTMLWithEmbeddedScriptAndStyle() {
        let h = Highlighted("html", #"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <!-- a comment -->
          <style>
            body { color: #fff; margin: 0 auto; }
          </style>
          <script type="module">
            const x = "</div>"; // comment
            const t = `multi
            line`;
          </script>
        </head>
        <body class="main" data-x='1'>&amp; it's text<br/></body>
        </html>
        """#)
        XCTAssertKind(h, "<!DOCTYPE html>", .preprocessor)
        XCTAssertKind(h, "html", .tag, occurrence: 1)
        XCTAssertKind(h, "lang", .attribute)
        XCTAssertKind(h, #""en""#, .string)
        XCTAssertKind(h, "<!-- a comment -->", .comment)
        XCTAssertKind(h, "style", .tag)
        XCTAssertKind(h, "color", .property)
        XCTAssertKind(h, "#fff", .number)
        XCTAssertKind(h, "auto", .constant)
        XCTAssertKind(h, "const", .storage)
        XCTAssertKind(h, #""</div>""#, .string)
        XCTAssertKind(h, "// comment", .comment)
        XCTAssertKind(h, "`multi", .string)
        XCTAssertKind(h, "    line`", .string)
        XCTAssertKind(h, "script", .tag, occurrence: 1)
        XCTAssertKind(h, "data-x", .attribute)
        XCTAssertKind(h, "'1'", .string)
        XCTAssertKind(h, "&amp;", .constant)
        XCTAssertKind(h, " it's text", .plain)
        XCTAssertKind(h, "br", .tag)
    }

    func testXML() {
        let h = Highlighted("xml", #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- multi
             line comment -->
        <root xmlns:x="urn:x">
          <x:item id="1" name='a'>Text &lt; more</x:item>
          <![CDATA[ raw <data> ]]>
          <empty/>
        </root>
        """#)
        XCTAssertKind(h, #"<?xml version="1.0" encoding="UTF-8"?>"#, .preprocessor)
        XCTAssertKind(h, "     line comment -->", .comment)
        XCTAssertKind(h, "root", .tag)
        XCTAssertKind(h, "xmlns:x", .attribute)
        XCTAssertKind(h, "x:item", .tag)
        XCTAssertKind(h, "'a'", .string)
        XCTAssertKind(h, "&lt;", .constant)
        XCTAssertKind(h, "Text", .plain)
        XCTAssertKind(h, "<![CDATA[ raw <data> ]]>", .string)
        XCTAssertKind(h, "empty", .tag)
    }

    func testCSS() {
        let h = Highlighted("css", #"""
        /* comment */
        @import url("theme.css");
        :root { --main-color: #ff0000; }
        .btn:hover, #id > a[href^="http"] {
          color: rgba(0, 0, 0, .5);
          margin: 0 auto !important;
          width: calc(100% - 10px);
          font-family: "Helvetica Neue", sans-serif;
        }
        @media (max-width: 600px) { a { display: none; } }
        """#)
        XCTAssertKind(h, "/* comment */", .comment)
        XCTAssertKind(h, "@import", .annotation)
        XCTAssertKind(h, "url", .builtin)
        XCTAssertKind(h, #""theme.css""#, .string)
        XCTAssertKind(h, "--main-color", .property)
        XCTAssertKind(h, "#ff0000", .number)
        XCTAssertKind(h, ".btn", .attribute)
        XCTAssertKind(h, "#id", .attribute)
        XCTAssertKind(h, #""http""#, .string)
        XCTAssertKind(h, "color", .property, occurrence: 1)
        XCTAssertKind(h, "sans-serif", .plain)
        XCTAssertKind(h, "rgba", .builtin)
        XCTAssertKind(h, ".5", .number)
        XCTAssertKind(h, "!important", .keyword)
        XCTAssertKind(h, "100%", .number)
        XCTAssertKind(h, "10px", .number)
        XCTAssertKind(h, "@media", .annotation)
        XCTAssertKind(h, "600px", .number)
        XCTAssertKind(h, "none", .constant)
    }

    func testSCSS() {
        let h = Highlighted("scss", #"""
        // line comment
        $primary: #333;
        @mixin flex($dir: row) { display: flex; flex-direction: $dir; }
        .card {
          &:hover { color: darken($primary, 10%); }
          .title { @include flex(column); }
        }
        """#)
        XCTAssertKind(h, "// line comment", .comment)
        XCTAssertKind(h, "$primary", .variable)
        XCTAssertKind(h, "#333", .number)
        XCTAssertKind(h, "@mixin", .annotation)
        XCTAssertKind(h, "$dir", .variable)
        XCTAssertKind(h, "display", .property)
        XCTAssertKind(h, ".card", .attribute)
        XCTAssertKind(h, "darken", .builtin)
        XCTAssertKind(h, "10%", .number)
        XCTAssertKind(h, "@include", .annotation)
    }

    func testMarkdown() {
        let h = Highlighted("markdown", #"""
        # Heading 1
        Some *emphasis*, **strong**, `inline code`, and a [link](http://x.com).
        - item one
        1. numbered
        > quote
        ```swift
        let x = "code" // comment
        ```
        ````markdown
        ```js
        not closed by the shorter fence
        ```
        ````
        ```python
        def f(): return 'x'
        ```
        Under_scored_word stays plain.
        """#)
        XCTAssertKind(h, "# Heading 1", .heading)
        XCTAssertKind(h, "*emphasis*", .emphasis)
        XCTAssertKind(h, "**strong**", .strong)
        XCTAssertKind(h, "`inline code`", .code)
        XCTAssertKind(h, "[link]", .link)
        XCTAssertKind(h, "(http://x.com)", .string)
        XCTAssertKind(h, "-", .keyword)
        XCTAssertKind(h, "1.", .keyword)
        XCTAssertKind(h, "```", .punctuation)
        XCTAssertKind(h, "swift", .keyword)
        XCTAssertKind(h, "let", .storage)
        XCTAssertKind(h, #""code""#, .string)
        XCTAssertKind(h, "// comment", .comment)
        XCTAssertKind(h, "```js", .code)
        XCTAssertKind(h, "not closed by the shorter fence", .code)
        XCTAssertKind(h, "def", .storage)
        XCTAssertKind(h, "'x'", .string)
        XCTAssertKind(h, "Under_scored_word stays plain.", .plain)
        XCTAssertEqual(h.lineStates.last, 0)
    }

    // MARK: - Data and configuration

    func testJSON() {
        let h = Highlighted("json", #"""
        {
          "name": "tovri",
          "version": 1.2e3,
          "neg": -5,
          "esc": "a\"b\\n\u00e9",
          "list": [true, false, null],
          "nested": { "k": "v" }
        }
        """#)
        XCTAssertKind(h, #""name""#, .property)
        XCTAssertKind(h, #""tovri""#, .string)
        XCTAssertKind(h, "1.2e3", .number)
        XCTAssertKind(h, "-", .operatorSymbol)
        XCTAssertKind(h, "5", .number)
        XCTAssertLine(h, "esc", #"  property«"esc"»operatorSymbol«:» string«"a»escape«\"»string«b»escape«\\»string«n»escape«\u00e9»string«"»,"#)
        XCTAssertKind(h, "true", .constant)
        XCTAssertKind(h, "null", .constant)
        XCTAssertKind(h, #""k""#, .property)
        XCTAssertKind(h, #""v""#, .string)
    }

    func testYAML() {
        let h = Highlighted("yaml", #"""
        # comment
        name: CI
        on:
          push:
            branches: [main, "release/*"]
        env:
          KEY: 'it''s'
          URL: http://example.com/#anchor # real comment
          NUM: 0x1F
          FLAG: true
        steps:
          - uses: actions/checkout@v4
          - run: |
              echo "hi" # part of the script
              key: not a key
            name: Build
          - &anchor value
          - *anchor
          - !!str 123
        folded: >-
          text
        after: 1
        """#)
        XCTAssertKind(h, "# comment", .comment)
        XCTAssertKind(h, "name", .property)
        XCTAssertKind(h, "on", .property)
        XCTAssertKind(h, "branches", .property)
        XCTAssertKind(h, #""release/*""#, .string)
        XCTAssertKind(h, "'it''s'", .string)
        XCTAssertKind(h, "http", .plain)
        XCTAssertKind(h, "//example.com/#anchor", .plain)
        XCTAssertKind(h, "# real comment", .comment)
        XCTAssertKind(h, "0x1F", .number)
        XCTAssertKind(h, "true", .constant)
        XCTAssertKind(h, "|", .operatorSymbol)
        XCTAssertKind(h, "echo \"hi\" # part of the script", .string)
        XCTAssertKind(h, "key: not a key", .string)
        XCTAssertKind(h, "name", .property, occurrence: 1)
        XCTAssertKind(h, "&anchor", .variable)
        XCTAssertKind(h, "*anchor", .variable)
        XCTAssertKind(h, "!!str", .annotation)
        XCTAssertKind(h, "text", .string)
        XCTAssertLine(h, "after", "property«after»operatorSymbol«:» number«1»")
    }

    func testTOML() {
        let h = Highlighted("toml", #"""
        # comment
        [package]
        name = "tovri"
        edition = 2021
        [dependencies]
        serde = { version = "1.0", features = ["derive"] }
        [[bin]]
        path = 'src\main.rs'
        multi = """
        line "one" \t
        """
        site.owner.name = "x"
        float = 6.626e-34
        hex = 0xDEAD_BEEF
        enabled = true
        """#)
        XCTAssertKind(h, "# comment", .comment)
        XCTAssertKind(h, "[package]", .heading)
        XCTAssertKind(h, "name", .property)
        XCTAssertKind(h, #""tovri""#, .string)
        XCTAssertKind(h, "2021", .number)
        XCTAssertKind(h, "serde", .property)
        XCTAssertKind(h, "version", .property)
        XCTAssertKind(h, "features", .property)
        XCTAssertKind(h, "[[bin]]", .heading)
        XCTAssertKind(h, #"'src\main.rs'"#, .string)
        XCTAssertKind(h, "line \"one\" ", .string)
        XCTAssertKind(h, #"\t"#, .escape)
        XCTAssertKind(h, "site.owner.name", .property)
        XCTAssertKind(h, "6.626e-34", .number)
        XCTAssertKind(h, "0xDEAD_BEEF", .number)
        XCTAssertKind(h, "true", .constant)
    }

    func testSQL() {
        let h = Highlighted("sql", #"""
        -- comment with 'quote'
        /* block
           comment */
        SELECT u.id, COUNT(*) AS total, 'it''s' AS s
        FROM users u LEFT JOIN orders o ON o.user_id = u.id
        WHERE u.score >= 1.5e2 AND u.name IS NOT NULL
        ORDER BY total DESC LIMIT 10;
        create table t (id serial primary key, name varchar(255));
        """#)
        XCTAssertKind(h, "-- comment with 'quote'", .comment)
        XCTAssertKind(h, "   comment */", .comment)
        XCTAssertKind(h, "SELECT", .keyword)
        XCTAssertKind(h, "COUNT", .builtin)
        XCTAssertKind(h, "AS", .keyword)
        XCTAssertKind(h, "'it''s'", .string)
        XCTAssertKind(h, "JOIN", .keyword)
        XCTAssertKind(h, "1.5e2", .number)
        XCTAssertKind(h, "NULL", .keyword)
        XCTAssertKind(h, "10", .number)
        XCTAssertKind(h, "create", .storage)
        XCTAssertKind(h, "serial", .type)
        XCTAssertKind(h, "varchar", .type)
    }

    func testDockerfile() {
        let h = Highlighted("dockerfile", #"""
        # syntax=docker/dockerfile:1
        FROM node:20-alpine AS build
        ARG VERSION=1.0
        ENV PATH="/app/bin:$PATH" URL=http://x.com/#frag
        RUN useradd -m user && echo copy from add \
            && echo "done # not comment"
        USER user
        CMD ["node", "server.js"]
        """#)
        XCTAssertKind(h, "# syntax=docker/dockerfile:1", .comment)
        XCTAssertKind(h, "FROM", .keyword)
        XCTAssertKind(h, "AS", .storage)
        XCTAssertKind(h, "ARG", .keyword)
        XCTAssertKind(h, "ENV", .keyword)
        XCTAssertKind(h, "\"/app/bin:", .string)
        XCTAssertKind(h, "$PATH", .variable)
        XCTAssertKind(h, "#frag", .plain)
        XCTAssertLine(h, "RUN", #"keyword«RUN» useradd operatorSymbol«-»m user operatorSymbol«&&» echo copy from add \"#)
        XCTAssertKind(h, "\"done # not comment\"", .string)
        XCTAssertKind(h, "USER", .keyword)
        XCTAssertKind(h, "CMD", .keyword)
        XCTAssertKind(h, #""server.js""#, .string)
    }

    func testMakefile() {
        let h = Highlighted("makefile", "# comment\nCC := gcc\nSRC = $(wildcard src/*.c)\n.PHONY: all\nall: $(TARGET)\n\t$(CC) $(CFLAGS) -o $@ $^ $< # comment\n\t@echo \"built $@\"\nifeq ($(OS),Windows_NT)\nendif\n")
        XCTAssertKind(h, "# comment", .comment)
        XCTAssertKind(h, ":=", .operatorSymbol)
        XCTAssertKind(h, "wildcard", .builtin)
        XCTAssertKind(h, "$(TARGET)", .variable)
        XCTAssertKind(h, "$(CC)", .variable)
        XCTAssertKind(h, "$(CFLAGS)", .variable)
        XCTAssertKind(h, "$@", .variable)
        XCTAssertKind(h, "$^", .variable)
        XCTAssertKind(h, "$<", .variable)
        XCTAssertKind(h, "# comment", .comment, occurrence: 1)
        XCTAssertKind(h, "\"built ", .string)
        XCTAssertKind(h, "$@", .variable, occurrence: 1)
        XCTAssertKind(h, "ifeq", .keyword)
        XCTAssertKind(h, "$(OS)", .variable)
        XCTAssertKind(h, "endif", .keyword)
    }

    func testDiff() {
        let h = Highlighted("diff", """
        diff --git a/f.txt b/f.txt
        index 83db48f..bf269f4 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@ func
         context "line"
        -removed line
        +added line
        """)
        XCTAssertKind(h, "diff --git a/f.txt b/f.txt", .heading)
        XCTAssertKind(h, "index 83db48f..bf269f4 100644", .comment)
        XCTAssertKind(h, "--- a/f.txt", .heading)
        XCTAssertKind(h, "+++ b/f.txt", .heading)
        XCTAssertKind(h, "@@ -1,3 +1,3 @@ func", .changed)
        XCTAssertKind(h, " context \"line\"", .plain)
        XCTAssertKind(h, "-removed line", .deleted)
        XCTAssertKind(h, "+added line", .inserted)
    }

    func testINIAndDotenv() {
        let ini = Highlighted("ini", #"""
        ; comment
        # also comment
        [section]
        key = value
        path = "C:\\dir"
        enabled = true
        port=8080
        name.first = John
        """#)
        XCTAssertKind(ini, "; comment", .comment)
        XCTAssertKind(ini, "# also comment", .comment)
        XCTAssertKind(ini, "[section]", .heading)
        XCTAssertKind(ini, "key", .property)
        XCTAssertKind(ini, "value", .plain)
        XCTAssertKind(ini, #"\\"#, .escape)
        XCTAssertKind(ini, "true", .constant)
        XCTAssertKind(ini, "port", .property)
        XCTAssertKind(ini, "8080", .number)
        XCTAssertKind(ini, "name.first", .property)

        let env = Highlighted("dotenv", #"""
        # comment
        export API_KEY="abc#123"
        DB_URL=postgres://user:pass@host/db#frag
        QUOTED='single $x'
        REF="${HOME}/dir"
        """#)
        XCTAssertKind(env, "# comment", .comment)
        XCTAssertKind(env, "export", .keyword)
        XCTAssertKind(env, "API_KEY", .property)
        XCTAssertKind(env, #""abc#123""#, .string)
        XCTAssertKind(env, "DB_URL", .property)
        XCTAssertKind(env, "postgres://user:pass@host/db#frag", .plain)
        XCTAssertKind(env, "'single $x'", .string)
        XCTAssertKind(env, "${HOME}", .variable)
        XCTAssertKind(env, "/dir\"", .string)
    }

    // MARK: - Engine state

    func testUnterminatedBlockCommentCarriesToTheNextLinesAndEndsCorrectly() {
        let h = Highlighted("c", "int a; /* starts here\nstill comment \"not a string\"\nends */ int b = 'x';\nint c;\n")
        XCTAssertKind(h, "/* starts here", .comment)
        XCTAssertKind(h, "still comment \"not a string\"", .comment)
        XCTAssertKind(h, "ends */", .comment)
        XCTAssertKind(h, "int", .type, occurrence: 1)
        XCTAssertKind(h, "'x'", .string)
        XCTAssertNotEqual(h.lineStates[1], 0)
        XCTAssertNotEqual(h.lineStates[2], 0)
        XCTAssertEqual(h.lineStates[3], 0)
    }

    func testEditingALineRelexesFollowingLinesAndConverges() {
        let source = (0..<40).map { "const v\($0) = \"s\($0)\"; // c\($0)" }.joined(separator: "\n") + "\n"
        let language = LanguageRegistry.shared.language(id: "javascript")!
        let doc = Document(text: source, name: "edit.js", language: language)
        func assertMatchesFreshLex(_ message: String, line: UInt = #line) {
            let incremental = Highlighted(document: doc)
            let fresh = Highlighted("javascript", doc.string as String)
            XCTAssertEqual(incremental.kinds, fresh.kinds, message, line: line)
            XCTAssertEqual(incremental.lineStates, fresh.lineStates, message, line: line)
        }
        XCTAssertKind(Highlighted(document: doc), "const", .storage, occurrence: 20)

        let line10 = doc.lines.start(of: 10)
        doc.textStorage.replaceCharacters(in: NSRange(location: line10, length: 0), with: "/* ")
        var h = Highlighted(document: doc)
        XCTAssertKind(h, "const v20 = \"s20\"; // c20", .comment)
        XCTAssertKind(h, "const", .storage, occurrence: 9)
        assertMatchesFreshLex("after opening a block comment")

        let line15 = doc.lines.start(of: 15)
        doc.textStorage.replaceCharacters(in: NSRange(location: line15, length: 0), with: "*/ ")
        h = Highlighted(document: doc)
        XCTAssertKind(h, "const v12", .comment)
        XCTAssertKind(h, "const", .storage, occurrence: 15)
        XCTAssertKind(h, "\"s20\"", .string)
        assertMatchesFreshLex("after closing it further down")

        doc.textStorage.replaceCharacters(in: NSRange(location: line10, length: 3), with: "")
        let close = (doc.string as NSString).range(of: "*/ ")
        doc.textStorage.replaceCharacters(in: close, with: "")
        h = Highlighted(document: doc)
        XCTAssertEqual(doc.string as String, source)
        XCTAssertKind(h, "const", .storage, occurrence: 12)
        assertMatchesFreshLex("after removing both")
    }

    func testEditingInsideATemplateLiteralAndHeredocConverges() {
        for (id, source, insert) in [
            ("javascript", "const a = 1;\nconst b = 2;\nconst c = 3;\n", "`"),
            ("shell", "echo one\necho two\necho three\n", "cat <<EOF\n"),
            ("python", "a = 1\nb = 2\nc = 3\n", "\"\"\""),
            ("yaml", "a: 1\nb: 2\nc: 3\n", "x: |\n"),
        ] {
            let doc = Document(text: source, name: "f", language: LanguageRegistry.shared.language(id: id)!)
            _ = Highlighted(document: doc)
            doc.textStorage.replaceCharacters(in: NSRange(location: doc.lines.start(of: 1), length: 0), with: insert)
            let edited = Highlighted(document: doc)
            XCTAssertEqual(edited.kinds, Highlighted(id, doc.string as String).kinds, id)
            XCTAssertNotEqual(edited.lineStates[2], 0, "\(id): the construct should stay open on the next line")
            doc.textStorage.replaceCharacters(in: NSRange(location: doc.lines.start(of: 1), length: (insert as NSString).length), with: "")
            let restored = Highlighted(document: doc)
            XCTAssertEqual(restored.kinds, Highlighted(id, source).kinds, id)
            XCTAssertEqual(restored.lineStates, Highlighted(id, source).lineStates, id)
        }
    }

    func testEmbeddedLexerStatesFitInSixteenBits() {
        // Markdown and HTML keep embedded lexer state in 16 bits.
        let samples: [(String, String)] = [
            ("javascript", "const t = `a ${b}\n"),
            ("python", "s = rf'''raw {x}\n"),
            ("shell", "cat <<'SOME_LONG_DELIMITER'\n"),
            ("yaml", String(repeating: " ", count: 300) + "key: |\n"),
            ("rust", "/* /* /* deep\n"),
        ]
        for (id, source) in samples {
            let h = Highlighted(id, source)
            XCTAssertNotEqual(h.lineStates[1], 0, id)
            XCTAssertEqual(h.lineStates[1] & 0xFFFF, h.lineStates[1], id)
        }
        let md = Highlighted("markdown", "```sh\ncat <<EOF\nit's text\nEOF\necho 'x'\n```\nafter *em*\n")
        XCTAssertKind(md, "it's text", .string)
        XCTAssertKind(md, "'x'", .string)
        XCTAssertKind(md, "*em*", .emphasis)
    }
}
