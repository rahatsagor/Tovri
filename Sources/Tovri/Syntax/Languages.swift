import Foundation

enum Languages {
    static let all: [Language] = build()

    private static func build() -> [Language] {
        var a: [Language] = []
        cFamily(&a)
        jvmAndDotNet(&a)
        systems(&a)
        scripting(&a)
        shells(&a)
        functional(&a)
        lisps(&a)
        web(&a)
        styles(&a)
        markup(&a)
        documents(&a)
        data(&a)
        config(&a)
        buildTools(&a)
        hardware(&a)
        misc(&a)
        return a
    }

    private static func w(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    private static let dq = StringRule("\"")
    private static let dqMulti = StringRule("\"", multiline: true)
    private static let sq = StringRule("'")
    private static let sqRaw = StringRule("'", escape: false)
    private static let charLit = StringRule("'", isChar: true)
    private static let backtickRaw = StringRule("`", escape: false, multiline: true)

    private static func cComments(_ l: Language) {
        l.lineComment = ["//"]
        l.blockComment = [("/*", "*/")]
    }

    private static let cFunctionSymbol =
        #"^[A-Za-z_][\w\s\*&:<>,~]*?\b([A-Za-z_~][\w:~]*)\s*\([^;]*$"#
    private static let cTypeSymbol =
        #"^[ \t]*(?:typedef\s+)?(?:struct|union|enum|class|namespace)\s+([A-Za-z_]\w*)\s*[:{]?"#

    // MARK: - C family

    private static let cKeywords = "if else for while do switch case default break continue return goto sizeof typeof typeof_unqual alignof _Alignof _Generic offsetof"
    private static let cStorage = "auto const extern register static volatile inline restrict struct union enum typedef signed unsigned _Atomic _Noreturn noreturn _Thread_local thread_local _Static_assert static_assert alignas _Alignas constexpr __attribute__ __declspec __inline __restrict __volatile__ __asm__ asm"
    private static let cTypes = "void char short int long float double _Bool bool _Complex _Imaginary size_t ssize_t ptrdiff_t intptr_t uintptr_t intmax_t uintmax_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t int_least8_t int_fast8_t wchar_t wint_t char16_t char32_t FILE va_list off_t pid_t time_t clock_t mode_t dev_t ino_t uid_t gid_t socklen_t max_align_t nullptr_t"
    private static let cConstants = "NULL true false nullptr EOF stdin stdout stderr __FILE__ __LINE__ __func__ __DATE__ __TIME__ __STDC__ __STDC_VERSION__ errno SEEK_SET SEEK_CUR SEEK_END EXIT_SUCCESS EXIT_FAILURE INT_MAX INT_MIN UINT_MAX LONG_MAX LONG_MIN SIZE_MAX CHAR_BIT"
    private static let cBuiltins = "printf fprintf sprintf snprintf vprintf vfprintf vsnprintf scanf fscanf sscanf malloc calloc realloc free aligned_alloc memcpy memset memmove memcmp memchr strlen strnlen strcpy strncpy strcmp strncmp strcat strncat strchr strrchr strstr strtok strdup strndup strerror fopen fclose fread fwrite fgets fputs fputc fgetc fseek ftell rewind fflush feof ferror puts putchar getchar perror exit abort atexit assert atoi atol atof strtol strtoul strtoll strtod qsort bsearch abs labs rand srand time clock sleep getenv setenv system signal raise setjmp longjmp va_start va_arg va_end va_copy isalpha isdigit isspace isupper islower toupper tolower"

    private static func cBase(_ l: Language) {
        cComments(l)
        l.strings = [dq, charLit]
        l.stringPrefixes = "uUL8"
        l.preprocessor = true
        l.quoteDigitSeparators = true
        l.keywords = w(cKeywords)
        l.storage = w(cStorage)
        l.types = w(cTypes)
        l.constants = w(cConstants)
        l.builtins = w(cBuiltins)
        l.typeDefKeywords = w("struct union enum")
        l.symbolPattern = cFunctionSymbol
    }

    private static let cppKeywords = "new delete throw try catch co_await co_return co_yield requires noexcept decltype typeid static_cast dynamic_cast const_cast reinterpret_cast and or not xor bitand bitor compl and_eq or_eq not_eq xor_eq using operator"
    private static let cppStorage = "class namespace template typename public private protected virtual override final friend mutable explicit consteval constinit concept export import module"
    private static let cppTypes = "string wstring string_view u8string vector map unordered_map multimap set unordered_set multiset list forward_list deque array queue priority_queue stack pair tuple unique_ptr shared_ptr weak_ptr optional variant any function span bitset thread mutex atomic future promise chrono ostream istream iostream fstream ifstream ofstream stringstream ostringstream istringstream exception runtime_error logic_error invalid_argument out_of_range iterator size_type char8_t initializer_list"
    private static let cppBuiltins = "std cout cin cerr clog endl make_unique make_shared make_pair make_tuple move forward swap sort find begin end min max to_string stoi stod getline accumulate transform for_each copy fill emplace_back push_back"

    private static func cFamily(_ a: inout [Language]) {
        a.append(Language.make("c", "C") { l in
            cBase(l)
            l.extensions = w("c h")
            l.aliases = ["h"]
        })
        a.append(Language.make("cpp", "C++") { l in
            cBase(l)
            l.extensions = w("cpp cc cxx c++ cp hpp hh hxx h++ hp ipp tpp inl ixx cppm ino")
            l.aliases = w("c++ cc cxx hpp arduino ino")
            l.strings = [StringRule("R\"(", ")\"", escape: false, multiline: true), dq, charLit]
            l.stringPrefixes = "uUL8R"
            l.keywords = w(cKeywords + " " + cppKeywords)
            l.storage = w(cStorage + " " + cppStorage)
            l.types = w(cTypes + " " + cppTypes)
            l.constants = w(cConstants + " this")
            l.builtins = w(cBuiltins + " " + cppBuiltins)
            l.typeDefKeywords = w("class struct union enum namespace concept")
        })
        let objcStorage = "in out inout bycopy byref oneway nonatomic atomic strong weak copy assign retain readonly readwrite nullable nonnull null_resettable null_unspecified _Nullable _Nonnull __block __weak __strong __unsafe_unretained __kindof IBOutlet IBAction IBInspectable IB_DESIGNABLE NS_ASSUME_NONNULL_BEGIN NS_ASSUME_NONNULL_END"
        let objcTypes = "id SEL IMP BOOL Class Protocol instancetype NSInteger NSUInteger CGFloat NSTimeInterval dispatch_queue_t dispatch_block_t"
        let objcConstants = "self super nil Nil YES NO"
        let objcBuiltins = "NSLog NSAssert NSParameterAssert NSStringFromClass NSClassFromString NSSelectorFromString NSStringFromSelector dispatch_async dispatch_sync dispatch_get_main_queue dispatch_once CFRelease CFRetain"
        let objcSymbol = #"^(?:[ \t]*@(?:interface|implementation|protocol)\s+|[-+]\s*\([^)]*\)\s*)([A-Za-z_]\w*)"#
        a.append(Language.make("objective-c", "Objective-C") { l in
            cBase(l)
            l.extensions = ["m"]
            l.aliases = w("objc objectivec obj-c")
            l.annotationPrefix = "@"
            l.stringPrefixes = "@uUL8"
            l.capitalizedTypes = true
            l.storage = w(cStorage + " " + objcStorage)
            l.types = w(cTypes + " " + objcTypes)
            l.constants = w(cConstants + " " + objcConstants)
            l.builtins = w(cBuiltins + " " + objcBuiltins)
            l.symbolPattern = objcSymbol
        })
        a.append(Language.make("objective-cpp", "Objective-C++") { l in
            cBase(l)
            l.extensions = ["mm"]
            l.aliases = w("objc++ objective-c++ objectivecpp")
            l.annotationPrefix = "@"
            l.stringPrefixes = "@uUL8R"
            l.capitalizedTypes = true
            l.keywords = w(cKeywords + " " + cppKeywords)
            l.storage = w(cStorage + " " + cppStorage + " " + objcStorage)
            l.types = w(cTypes + " " + cppTypes + " " + objcTypes)
            l.constants = w(cConstants + " this " + objcConstants)
            l.builtins = w(cBuiltins + " " + cppBuiltins + " " + objcBuiltins)
            l.symbolPattern = objcSymbol
        })
    }

    // MARK: - JVM and .NET

    private static func jvmAndDotNet(_ a: inout [Language]) {
        a.append(Language.make("java", "Java") { l in
            cComments(l)
            l.extensions = ["java"]
            l.strings = [StringRule("\"\"\"", multiline: true), dq, charLit]
            l.annotationPrefix = "@"
            l.capitalizedTypes = true
            l.keywords = w("if else for while do switch case default break continue return throw try catch finally new instanceof import package assert yield when")
            l.storage = w("class interface enum record extends implements public private protected static final abstract native synchronized transient volatile strictfp throws var sealed permits non-sealed module requires exports opens uses provides with to transitive default")
            l.types = w("void boolean byte char short int long float double String Object Integer Long Double Float Boolean Character Byte Short Number Math System Thread Runnable Iterable Iterator Collection List ArrayList LinkedList Map HashMap TreeMap LinkedHashMap Set HashSet TreeSet Optional Stream Exception RuntimeException Throwable Error Class Void StringBuilder")
            l.constants = w("true false null this super")
            l.builtins = w("out err println printf print length size")
            l.typeDefKeywords = w("class interface enum record")
            l.symbolPattern = #"^[ \t]*(?:(?:public|private|protected|static|final|abstract|synchronized|native|default|sealed|strictfp)\s+)*(?:(?:class|interface|enum|record)\s+|(?!(?:return|new|throw|else)\b)(?:<[^>]*>\s*)?[\w<>\[\],.?]+\s+)([A-Za-z_]\w*)(?=\s*(?:[({<]|extends\b|implements\b|$))"#
        })
        a.append(Language.make("kotlin", "Kotlin") { l in
            cComments(l)
            l.nestedComments = true
            l.extensions = w("kt kts")
            l.aliases = w("kt kts")
            l.strings = [StringRule("\"\"\"", escape: false, multiline: true, interpolation: .dollarBrace, variables: true),
                         StringRule("\"", interpolation: .dollarBrace, variables: true), charLit]
            l.variablePrefixes = "$"
            l.annotationPrefix = "@"
            l.capitalizedTypes = true
            l.autoPairs = "()[]{}\"\"''``"
            l.keywords = w("if else when for while do break continue return throw try catch finally in is as import package by where")
            l.storage = w("val var fun class interface object enum data sealed inner open abstract final override private protected public internal companion lateinit const suspend inline noinline crossinline reified tailrec operator infix external annotation typealias vararg init constructor get set value expect actual out")
            l.types = w("Int Long Short Byte Double Float Boolean Char String Unit Any Nothing Number Array List MutableList Map MutableMap Set MutableSet Sequence Pair Triple IntArray LongArray ByteArray DoubleArray FloatArray BooleanArray CharArray Iterable Collection Comparable Lazy Result Throwable Exception")
            l.constants = w("true false null this super it")
            l.builtins = w("println print readLine listOf mutableListOf arrayListOf mapOf mutableMapOf hashMapOf setOf mutableSetOf arrayOf emptyList emptyMap emptySet sequenceOf require requireNotNull check checkNotNull error lazy run let apply also with takeIf takeUnless repeat TODO maxOf minOf buildList buildString")
            l.functionDefKeywords = ["fun"]
            l.typeDefKeywords = w("class interface object typealias")
            l.symbolPattern = #"^[ \t]*(?:(?:public|private|protected|internal|open|abstract|final|override|data|sealed|enum|inner|inline|suspend|operator|infix|tailrec|external|annotation|companion|value|expect|actual)\s+)*(?:fun\s+(?:<[^>]*>\s*)?(?:[\w.]+\.)?|class\s+|interface\s+|object\s+|typealias\s+)([A-Za-z_]\w*)"#
        })
        a.append(Language.make("scala", "Scala") { l in
            cComments(l)
            l.nestedComments = true
            l.extensions = w("scala sc sbt")
            l.strings = [StringRule("\"\"\"", escape: false, multiline: true), dq, charLit]
            l.stringPrefixes = "sf"
            l.annotationPrefix = "@"
            l.capitalizedTypes = true
            l.autoPairs = "()[]{}\"\"``"
            l.keywords = w("if else for while do match case try catch finally throw return yield new import package then end extends with forSome derives")
            l.storage = w("def val var lazy class object trait enum given using implicit sealed abstract final override private protected type extension inline opaque transparent export infix open")
            l.types = w("Int Long Short Byte Double Float Boolean Char String Unit Any AnyRef AnyVal Nothing Null Option Some List Seq IndexedSeq Vector Map Set Array Either Left Right Future Try Success Failure Iterator Iterable Tuple2 BigInt BigDecimal")
            l.constants = w("true false null this super None Nil")
            l.builtins = w("println print require assert assume implicitly summon")
            l.functionDefKeywords = ["def"]
            l.typeDefKeywords = w("class object trait enum type")
        })
        a.append(Language.make("groovy", "Groovy") { l in
            cComments(l)
            l.extensions = w("groovy gradle gvy gy gsh")
            l.filenames = ["Jenkinsfile"]
            l.aliases = w("gradle jenkinsfile")
            l.shebangs = ["groovy"]
            l.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), dq, sq]
            l.annotationPrefix = "@"
            l.capitalizedTypes = true
            l.keywords = w("if else for while do switch case default break continue return throw try catch finally new instanceof import package assert as in")
            l.storage = w("def var class interface enum trait extends implements public private protected static final abstract synchronized transient volatile throws")
            l.types = w("void boolean byte char short int long float double String Object Integer Long Double Float Boolean List Map Set Closure")
            l.constants = w("true false null this super it")
            l.builtins = w("println print each collect find findAll inject sleep apply plugins dependencies repositories implementation testImplementation api compileOnly runtimeOnly task pipeline stage stages steps agent sh echo")
            l.functionDefKeywords = ["def"]
            l.typeDefKeywords = w("class interface enum trait")
        })
        a.append(Language.make("csharp", "C#") { l in
            cComments(l)
            l.extensions = w("cs csx cake")
            l.aliases = w("cs c# csharp")
            l.strings = [StringRule("\"\"\"", escape: false, multiline: true, interpolation: .brace),
                         StringRule("\"", interpolation: .brace), charLit]
            l.stringPrefixes = "@$"
            l.rawStringPrefixes = "@"
            l.interpolationPrefixes = "$"
            l.preprocessor = true
            l.capitalizedTypes = true
            l.keywords = w("if else for foreach while do switch case default break continue return throw try catch finally goto new typeof sizeof nameof is as in out ref await yield using when where checked unchecked lock fixed stackalloc select from group into orderby join let on equals by ascending descending with not and or")
            l.storage = w("class struct interface enum record namespace delegate event public private protected internal static readonly const sealed abstract virtual override extern unsafe volatile async partial params implicit explicit operator get set init var dynamic required file scoped global")
            l.types = w("void bool byte sbyte char short ushort int uint long ulong float double decimal string object nint nuint String Object Int32 Int64 Boolean Double Task ValueTask List Dictionary HashSet IEnumerable IList IDictionary Action Func Span ReadOnlySpan Exception DateTime TimeSpan Guid")
            l.constants = w("true false null this base value")
            l.builtins = w("Console Math WriteLine Write ReadLine")
            l.typeDefKeywords = w("class struct interface enum record namespace delegate")
            l.symbolPattern = #"^[ \t]*(?:\[[^\]]*\]\s*)*(?:(?:public|private|protected|internal|static|readonly|sealed|abstract|virtual|override|async|partial|unsafe|extern|new|file|required)\s+)*(?:(?:class|struct|interface|enum|record|namespace)\s+|(?!(?:return|new|throw|else|await|yield)\b)[\w<>\[\],.?]+\s+)([A-Za-z_]\w*)\s*(?:[(<{:]|$)"#
        })
        a.append(Language.make("fsharp", "F#") { l in
            l.lineComment = ["//"]
            l.blockComment = [("(*", "*)")]
            l.nestedComments = true
            l.extensions = w("fs fsi fsx fsscript")
            l.aliases = w("f# fs")
            l.strings = [StringRule("\"\"\"", escape: false, multiline: true), dq, charLit]
            l.stringPrefixes = "@$"
            l.identifierPartChars = "'"
            l.capitalizedTypes = true
            l.autoPairs = "()[]{}\"\""
            l.keywords = w("if then else elif match with for to downto in do done while try finally raise return yield function fun when not and or as begin end upcast downcast use open lazy assert")
            l.storage = w("let rec mutable type module namespace member static abstract override default val new inherit interface private public internal inline extern struct class exception of")
            l.types = w("int int8 int16 int32 int64 uint8 uint16 uint32 uint64 byte sbyte float float32 double decimal bool char string unit obj option list array seq Map Set Result Async Task")
            l.constants = w("true false null this base None Some Ok Error")
            l.builtins = w("printfn printf sprintf failwith failwithf ignore id fst snd raise box unbox string int float List Array Seq Option")
            l.typeDefKeywords = w("type module namespace exception")
            l.symbolPattern = #"^\s*(?:let(?:\s+(?:rec|inline|private|mutable))*|member(?:\s+\w+\.)?|type|module)\s+([A-Za-z_][\w']*)"#
        })
    }

    // MARK: - Systems languages

    private static func systems(_ a: inout [Language]) {
        a.append(Language.make("swift", "Swift") { l in
            cComments(l)
            l.nestedComments = true
            l.extensions = ["swift"]
            l.shebangs = ["swift"]
            l.strings = [StringRule("#\"\"\"", "\"\"\"#", escape: false, multiline: true),
                         StringRule("\"\"\"", multiline: true, interpolation: .backslashParen),
                         StringRule("#\"", "\"#", escape: false), StringRule("\"", interpolation: .backslashParen)]
            l.annotationPrefix = "@"
            l.preprocessor = true
            l.regexLiterals = true
            l.capitalizedTypes = true
            l.keywords = w("if else guard switch case default for in while repeat break continue fallthrough return throw throws rethrows try catch do defer where as is await import")
            l.storage = w("let var func class struct enum protocol extension actor typealias associatedtype init deinit subscript operator public private fileprivate internal open package static final override mutating nonmutating lazy weak unowned inout indirect convenience required dynamic optional async nonisolated isolated some any consume borrowing consuming sending macro precedencegroup infix prefix postfix get set willSet didSet")
            l.types = w("Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float Float80 Bool String Substring Character Array Dictionary Set Optional Any AnyObject AnyClass Void Never Error Result Data Date URL UUID CGFloat CGPoint CGSize CGRect Range ClosedRange Sequence Collection Equatable Hashable Comparable Codable Decodable Encodable Identifiable Sendable")
            l.constants = w("true false nil self Self super")
            l.builtins = w("print debugPrint dump fatalError precondition preconditionFailure assert assertionFailure min max abs zip stride type swap withUnsafePointer withUnsafeMutablePointer withUnsafeBytes withAnimation withExtendedLifetime unsafeBitCast numericCast sequence repeatElement")
            l.functionDefKeywords = ["func"]
            l.typeDefKeywords = w("class struct enum protocol extension actor typealias associatedtype")
            l.symbolPattern = #"^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|package|static|class|final|override|mutating|nonmutating|convenience|required|dynamic|indirect|nonisolated|lazy|weak)\s+)*(?:func|class|struct|enum|protocol|extension|actor|typealias|macro)\s+([A-Za-z_][\w.]*)"#
        })
        a.append(Language.make("rust", "Rust") { l in
            cComments(l)
            l.nestedComments = true
            l.extensions = ["rs"]
            l.aliases = ["rs"]
            // With the r prefix: r#"..."#, r##"..."##.
            l.strings = [StringRule("##\"", "\"##", escape: false, multiline: true),
                         StringRule("#\"", "\"#", escape: false, multiline: true), dqMulti, charLit]
            l.stringPrefixes = "brc"
            l.rawStringPrefixes = "r"
            l.hashAttributes = true
            l.capitalizedTypes = true
            l.autoPairs = "()[]{}\"\""
            l.keywords = w("as break continue else for if in loop match return while where await yield use become do")
            l.storage = w("fn let mut const static struct enum trait impl type mod pub crate extern unsafe async move ref dyn union macro_rules box abstract final override virtual")
            l.types = w("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box Rc Arc Weak RefCell Cell Mutex RwLock HashMap HashSet BTreeMap BTreeSet VecDeque BinaryHeap Cow Path PathBuf OsString OsStr Duration Instant Default Clone Copy Debug Display Iterator IntoIterator From Into TryFrom TryInto Send Sync Sized Drop Fn FnMut FnOnce PartialEq Eq PartialOrd Ord Hash AsRef AsMut Deref DerefMut Error Future Pin PhantomData")
            l.constants = w("true false self Self super crate None Some Ok Err")
            l.builtins = w("println print eprintln eprint format write writeln vec panic assert assert_eq assert_ne debug_assert debug_assert_eq debug_assert_ne unreachable unimplemented todo matches dbg include include_str include_bytes env option_env concat stringify cfg line file column module_path format_args thread_local compile_error drop std core alloc")
            l.functionDefKeywords = ["fn"]
            l.typeDefKeywords = w("struct enum trait type union mod")
            l.symbolPattern = #"^[ \t]*(?:pub(?:\([\w:\s]+\))?\s+)?(?:(?:async|const|unsafe|default|extern(?:\s+"[^"]*")?)\s+)*(?:fn|struct|enum|trait|type|mod|union|macro_rules!)\s+([A-Za-z_]\w*)"#
        })
        a.append(Language.make("go", "Go") { l in
            cComments(l)
            l.extensions = ["go"]
            l.aliases = ["golang"]
            l.strings = [dq, backtickRaw, charLit]
            l.capitalizedTypes = true
            l.autoPairs = "()[]{}\"\"''``"
            l.keywords = w("break case continue default defer else fallthrough for go goto if range return select switch import package")
            l.storage = w("func var const type struct interface map chan")
            l.types = w("bool byte rune string int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32 float64 complex64 complex128 error any comparable")
            l.constants = w("true false nil iota")
            l.builtins = w("append cap clear close complex copy delete imag len make max min new panic print println real recover")
            l.functionDefKeywords = ["func"]
            l.typeDefKeywords = ["type"]
            l.symbolPattern = #"^(?:func\s+(?:\([^)]*\)\s*)?|type\s+)([A-Za-z_]\w*)"#
        })
        a.append(Language.make("go-mod", "Go Module") { l in
            l.lineComment = ["//"]
            l.filenames = w("go.mod go.work go.sum")
            l.aliases = w("gomod go.mod")
            l.strings = [dq, backtickRaw]
            l.functionCalls = false
            l.keywords = w("module go require replace exclude retract toolchain godebug use")
            l.constants = ["indirect"]
            l.symbolPattern = #"^\s*module\s+(\S+)"#
        })
        a.append(Language.make("zig", "Zig") { l in
            l.lineComment = ["//"]
            l.extensions = w("zig zon")
            l.strings = [dq, charLit]
            l.annotationPrefix = "@"
            l.capitalizedTypes = true
            l.keywords = w("if else for while switch break continue return try catch orelse defer errdefer unreachable and or async await suspend resume nosuspend comptime test usingnamespace")
            l.storage = w("fn const var pub extern export inline noinline struct enum union error opaque packed align linksection threadlocal volatile allowzero noalias callconv anytype")
            l.types = w("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f16 f32 f64 f80 f128 bool void noreturn type anyerror anyopaque comptime_int comptime_float c_int c_uint c_long c_ulong c_char c_short")
            l.constants = w("true false null undefined")
            l.builtins = w("std")
            l.functionDefKeywords = ["fn"]
            l.symbolPattern = #"^[ \t]*(?:pub\s+)?(?:(?:extern|export|inline)\s+)?(?:fn\s+|const\s+(?=[A-Za-z_]\w*\s*=\s*(?:packed\s+|extern\s+)?(?:struct|enum|union|opaque)))([A-Za-z_]\w*)"#
        })
        a.append(Language.make("odin", "Odin") { l in
            cComments(l)
            l.nestedComments = true
            l.extensions = ["odin"]
            l.strings = [dq, backtickRaw, charLit]
            l.annotationPrefix = "@"
            l.capitalizedTypes = true
            l.keywords = w("if else when for in not_in switch case break continue fallthrough return defer do using import package foreign or_else or_return or_break or_continue cast transmute auto_cast")
            l.storage = w("proc struct enum union bit_set bit_field map dynamic distinct matrix")
            l.types = w("int i8 i16 i32 i64 i128 uint u8 u16 u32 u64 u128 uintptr f16 f32 f64 bool b8 b16 b32 b64 rune string cstring rawptr typeid any byte complex64 complex128 quaternion256")
            l.constants = w("true false nil context")
            l.builtins = w("len cap size_of align_of offset_of type_of type_info_of typeid_of make new free delete append clear min max abs clamp fmt")
            l.symbolPattern = #"^\s*([A-Za-z_]\w*)\s*::\s*(?:proc|struct|enum|union|distinct|#force_inline\s+proc)"#
        })
        a.append(Language.make("v", "V") { l in
            cComments(l)
            l.extensions = w("v vsh")
            l.aliases = ["vlang"]
            l.strings = [dq, sq, StringRule("`", isChar: true)]
            l.stringPrefixes = "rc"
            l.capitalizedTypes = true
            l.keywords = w("if else for in match break continue return defer go spawn select or unsafe goto import module assert is as lock rlock")
            l.storage = w("fn mut pub const struct enum interface type union shared static volatile global")
            l.types = w("bool string i8 i16 int i32 i64 i128 u8 u16 u32 u64 u128 rune f32 f64 isize usize voidptr byteptr charptr any")
            l.constants = w("true false none")
            l.builtins = w("println print eprintln eprint panic exit len cap sizeof typeof isreftype")
            l.functionDefKeywords = ["fn"]
            l.typeDefKeywords = w("struct enum interface type union")
        })
        a.append(Language.make("d", "D") { l in
            l.lineComment = ["//"]
            l.blockComment = [("/*", "*/"), ("/+", "+/")]
            l.nestedComments = true
            l.extensions = w("d di")
            l.aliases = ["dlang"]
            l.strings = [dqMulti, StringRule("`", escape: false, multiline: true), charLit]
            l.stringPrefixes = "rxq"
            l.annotationPrefix = "@"
            l.capitalizedTypes = true
            l.keywords = w("if else for foreach foreach_reverse while do switch case default break continue return goto throw try catch finally with new delete cast is in out typeof typeid import module assert mixin version debug asm")
            l.storage = w("auto const immutable shared static final abstract override public private protected package export extern alias class struct union enum interface template function delegate ref scope lazy nothrow pure synchronized deprecated align inout __gshared")
            l.types = w("void bool byte ubyte short ushort int uint long ulong cent ucent float double real char wchar dchar string wstring dstring size_t ptrdiff_t")
            l.constants = w("true false null this super __FILE__ __LINE__ __MODULE__ __FUNCTION__")
            l.builtins = w("writeln writefln write writef readln assert std")
            l.typeDefKeywords = w("class struct union enum interface template")
        })
        a.append(Language.make("nim", "Nim") { l in
            l.lineComment = ["#"]
            l.blockComment = [("#[", "]#")]
            l.nestedComments = true
            l.extensions = w("nim nims nimble")
            l.strings = [StringRule("\"\"\"", escape: false, multiline: true), dq, charLit]
            l.stringPrefixes = "rR"
            l.capitalizedTypes = true
            l.indentAfterColon = true
            l.indentAfter = "{[(="
            l.keywords = w("if elif else when case of for while break continue return yield try except finally raise discard defer block do and or not xor in notin is isnot div mod shl shr import from include export as cast addr bind mixin static using asm")
            l.storage = w("proc func method iterator template macro converter type var let const object enum tuple ref ptr distinct concept out")
            l.types = w("int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float float32 float64 bool char string cstring pointer seq array set openArray varargs void auto any untyped typed Natural Positive range")
            l.constants = w("true false nil result")
            l.builtins = w("echo len add del high low inc dec ord chr new newSeq assert doAssert quit sizeof repr toSeq items pairs")
            l.functionDefKeywords = w("proc func method iterator template macro converter")
            l.symbolPattern = #"^\s*(?:proc|func|method|iterator|template|macro|converter)\s+`?([A-Za-z_]\w*)"#
        })
        a.append(Language.make("crystal", "Crystal") { l in
            l.lineComment = ["#"]
            l.extensions = ["cr"]
            l.shebangs = ["crystal"]
            l.strings = [dqMulti, charLit, StringRule("`", multiline: true)]
            l.variablePrefixes = "@$"
            l.identifierPartChars = "?!"
            l.capitalizedTypes = true
            l.keywords = w("if else elsif unless case when in then while until for do end begin rescue ensure raise return break next yield and or not loop require include extend select")
            l.storage = w("def class module struct enum lib fun alias annotation macro abstract private protected getter setter property record")
            l.types = w("Int Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64 Float32 Float64 String Char Bool Nil Symbol Array Hash Set Tuple NamedTuple Proc Range Regex Pointer Void NoReturn Object")
            l.constants = w("true false nil self")
            l.builtins = w("puts print p pp gets sleep spawn typeof sizeof raise")
            l.functionDefKeywords = ["def"]
            l.typeDefKeywords = w("class module struct enum lib alias")
            l.symbolPattern = #"^\s*(?:private\s+|protected\s+|abstract\s+)*(?:def|class|module|struct|enum|macro)\s+([\w.:?!]+)"#
        })
        a.append(Language.make("vala", "Vala") { l in
            cComments(l)
            l.extensions = w("vala vapi")
            l.strings = [StringRule("\"\"\"", escape: false, multiline: true), dq, charLit]
            l.preprocessor = true
            l.capitalizedTypes = true
            l.keywords = w("if else for foreach while do switch case default break continue return throw try catch finally new delete is as in out ref yield lock typeof sizeof using")
            l.storage = w("class struct interface enum namespace delegate signal public private protected internal static const abstract virtual override async owned unowned weak var construct get set errordomain")
            l.types = w("void bool char uchar int uint short ushort long ulong int8 uint8 int16 uint16 int32 uint32 int64 uint64 float double size_t ssize_t string unichar")
            l.constants = w("true false null this base")
            l.builtins = w("print stdout stderr GLib")
            l.typeDefKeywords = w("class struct interface enum namespace")
        })
        a.append(Language.make("mojo", "Mojo") { l in
            pythonBase(l)
            l.extensions = ["mojo"]
            l.storage = w(pyStorage + " fn struct trait var alias inout owned borrowed mut out ref raises capturing")
            l.types = w(pyTypes + " Int Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64 Float32 Float64 Bool String SIMD DType List Dict Optional")
            l.functionDefKeywords = w("def fn")
            l.typeDefKeywords = w("class struct trait")
            l.symbolPattern = #"^\s*(?:def|fn|class|struct|trait)\s+([A-Za-z_]\w*)"#
        })
        a.append(Language.make("solidity", "Solidity") { l in
            cComments(l)
            l.extensions = ["sol"]
            l.strings = [dq, sq]
            l.capitalizedTypes = true
            l.keywords = w("if else for while do break continue return throw try catch revert require assert emit new delete import from as using is returns unchecked assembly")
            l.storage = w("function contract interface library struct enum event error modifier constructor fallback receive mapping public private internal external pure view payable constant immutable override virtual abstract memory storage calldata indexed anonymous pragma type")
            l.types = w("address bool string bytes byte int int8 int16 int32 int64 int128 int256 uint uint8 uint16 uint32 uint64 uint128 uint256 bytes1 bytes4 bytes8 bytes16 bytes32 fixed ufixed")
            l.constants = w("true false this super wei gwei ether seconds minutes hours days weeks")
            l.builtins = w("msg block tx abi keccak256 sha256 ripemd160 ecrecover addmod mulmod selfdestruct gasleft blockhash")
            l.functionDefKeywords = w("function modifier event")
            l.typeDefKeywords = w("contract interface library struct enum error")
            l.symbolPattern = #"^\s*(?:abstract\s+)?(?:contract|interface|library|struct|enum|event|error|modifier|function)\s+([A-Za-z_]\w*)"#
        })
        a.append(Language.make("move", "Move") { l in
            cComments(l)
            l.extensions = ["move"]
            l.strings = [dq]
            l.stringPrefixes = "bx"
            l.hashAttributes = true
            l.capitalizedTypes = true
            l.keywords = w("if else while loop break continue return abort as use friend spec move copy acquires")
            l.storage = w("fun struct module script public entry native const let mut has key store drop inline macro enum")
            l.types = w("u8 u16 u32 u64 u128 u256 bool address signer vector")
            l.constants = w("true false Self")
            l.builtins = w("assert borrow_global borrow_global_mut exists move_from move_to freeze")
            l.functionDefKeywords = ["fun"]
            l.typeDefKeywords = w("struct module enum")
        })
        a.append(Language.make("haxe", "Haxe") { l in
            cComments(l)
            l.extensions = ["hx"]
            l.strings = [dqMulti, StringRule("'", multiline: true)]
            l.annotationPrefix = "@"
            l.preprocessor = true
            l.capitalizedTypes = true
            l.keywords = w("if else for while do switch case default break continue return throw try catch new in is cast untyped import package using macro")
            l.storage = w("var final function class interface enum abstract typedef extends implements public private static inline override dynamic extern operator")
            l.types = w("Int Float String Bool Dynamic Void Array Map Null Any Iterator Iterable")
            l.constants = w("true false null this super")
            l.builtins = w("trace Std Math Reflect Type")
            l.functionDefKeywords = ["function"]
            l.typeDefKeywords = w("class interface enum abstract typedef")
        })
    }

    // MARK: - Scripting languages

    private static let pyKeywords = "and as assert await break continue del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case print_function"
    private static let pyStorage = "def class async"
    private static let pyTypes = "int float complex str bytes bytearray bool list dict set frozenset tuple object type range memoryview slice Exception BaseException ValueError TypeError KeyError IndexError AttributeError RuntimeError StopIteration StopAsyncIteration NotImplementedError OSError IOError FileNotFoundError FileExistsError ImportError ModuleNotFoundError ZeroDivisionError AssertionError KeyboardInterrupt SystemExit GeneratorExit LookupError ArithmeticError OverflowError PermissionError TimeoutError ConnectionError UnicodeError UnicodeDecodeError UnicodeEncodeError RecursionError NameError Warning DeprecationWarning UserWarning Any Optional Union List Dict Set Tuple Callable Iterable Iterator Generator AsyncIterator Awaitable Sequence Mapping MutableMapping Literal TypeVar Generic Protocol Self ClassVar Final Annotated"
    private static let pyConstants = "True False None self cls NotImplemented Ellipsis __name__ __file__ __doc__ __all__ __dict__ __class__ __init__ __main__ __slots__ __debug__"
    private static let pyBuiltins = "abs aiter all anext any ascii bin breakpoint callable chr classmethod compile delattr dir divmod enumerate eval exec filter format getattr globals hasattr hash help hex id input isinstance issubclass iter len locals map max min next oct open ord pow print property repr reversed round setattr sorted staticmethod sum super vars zip __import__"

    private static func pythonBase(_ l: Language) {
        l.lineComment = ["#"]
        l.strings = [StringRule("\"\"\"", multiline: true, interpolation: .brace), StringRule("'''", multiline: true, interpolation: .brace),
                     StringRule("\"", interpolation: .brace), StringRule("'", interpolation: .brace)]
        l.stringPrefixes = "rRbBfFuUtT"
        l.rawStringPrefixes = "rR"
        l.rawStringBackslashQuotes = true
        l.interpolationPrefixes = "fFtT"
        l.annotationPrefix = "@"
        l.capitalizedTypes = true
        l.indentAfterColon = true
        l.keywords = w(pyKeywords)
        l.storage = w(pyStorage)
        l.types = w(pyTypes)
        l.constants = w(pyConstants)
        l.builtins = w(pyBuiltins)
        l.functionDefKeywords = ["def"]
        l.typeDefKeywords = ["class"]
        l.symbolPattern = #"^\s*(?:async\s+)?(?:def|class)\s+([A-Za-z_]\w*)"#
    }

    private static func scripting(_ a: inout [Language]) {
        a.append(Language.make("python", "Python") { l in
            pythonBase(l)
            l.extensions = w("py pyw pyi pyx pxd pxi gyp gypi rpy")
            l.filenames = w("SConstruct SConscript .pythonrc .pythonstartup")
            l.aliases = w("py python3 python2 py3 cython")
            l.shebangs = w("python python3 python2 pypy pypy3 uv")
            l.storage = w(pyStorage + " type")
        })
        a.append(Language.make("starlark", "Starlark") { l in
            pythonBase(l)
            l.extensions = w("bzl star bazel sky")
            l.filenames = w("BUILD BUILD.bazel WORKSPACE WORKSPACE.bazel MODULE.bazel BUCK Tiltfile")
            l.aliases = w("bazel skylark")
            l.builtins = w(pyBuiltins + " load struct select glob package workspace rule provider aspect depset fail native attr cc_library cc_binary cc_test py_library py_binary py_test java_library java_binary genrule filegroup exports_files module bazel_dep http_archive git_repository")
        })
        a.append(Language.make("gdscript", "GDScript") { l in
            pythonBase(l)
            l.extensions = ["gd"]
            l.aliases = ["godot"]
            l.storage = w("func class class_name extends var const static enum signal export onready setget tool remote master puppet")
            l.keywords = w("if elif else for while match break continue pass return and or not in is as await yield preload breakpoint")
            l.types = w("int float bool String Vector2 Vector2i Vector3 Vector3i Vector4 Color Rect2 Transform2D Transform3D Basis Quaternion Array Dictionary PackedStringArray PackedByteArray PackedInt32Array PackedFloat32Array PackedVector2Array Node Node2D Node3D Object Resource Callable Signal NodePath StringName void")
            l.constants = w("true false null self PI TAU INF NAN")
            l.builtins = w("print printerr push_error push_warning len range str int float load preload get_node is_instance_valid typeof abs clamp lerp min max randf randi")
            l.functionDefKeywords = ["func"]
            l.typeDefKeywords = w("class class_name extends")
            l.symbolPattern = #"^\s*(?:static\s+)?(?:func|class|class_name|signal)\s+([A-Za-z_]\w*)"#
        })
        a.append(Language.make("ruby", "Ruby") { l in
            l.lineComment = ["#"]
            l.blockComment = [("=begin", "=end")]
            l.extensions = w("rb rake gemspec ru podspec rbi jbuilder thor")
            l.filenames = w("Gemfile Rakefile Podfile Brewfile Vagrantfile Fastfile Appfile Matchfile Pluginfile Dangerfile Guardfile Capfile Berksfile Thorfile Steepfile .irbrc .pryrc")
            l.aliases = w("rb jruby")
            l.shebangs = w("ruby jruby rbx")
            l.strings = [StringRule("\"", multiline: true, interpolation: .hashBrace), StringRule("'", multiline: true),
                         StringRule("`", multiline: true, interpolation: .hashBrace)]
            l.heredoc = "<<"
            l.variablePrefixes = "@$"
            l.identifierPartChars = "?!"
            l.capitalizedTypes = true
            l.keywords = w("if else elsif unless case when then while until for in do end begin rescue ensure raise retry redo return break next yield and or not defined? super alias undef BEGIN END loop require require_relative include extend prepend using")
            l.storage = w("def class module attr_reader attr_writer attr_accessor private public protected module_function private_constant lambda proc")
            l.constants = w("true false nil self __FILE__ __LINE__ __dir__ __method__ __ENCODING__ ARGV ENV STDIN STDOUT STDERR")
            l.builtins = w("puts print p pp gets format sprintf printf require load catch throw sleep rand srand exit abort at_exit binding block_given? freeze frozen? dup clone respond_to? send public_send instance_variable_get instance_variable_set define_method method_missing")
            l.functionDefKeywords = ["def"]
            l.typeDefKeywords = w("class module")
            l.symbolPattern = #"^\s*(?:def|class|module)\s+([\w.:?!]+)"#
        })
        a.append(Language.make("php", "PHP") { l in
            l.lineComment = ["//", "#"]
            l.blockComment = [("/*", "*/")]
            l.extensions = w("php phtml php3 php4 php5 php7 php8 phps phpt")
            l.shebangs = ["php"]
            l.strings = [StringRule("\"", multiline: true, variables: true), StringRule("'", multiline: true), StringRule("`", multiline: true)]
            l.heredoc = "<<<"
            l.variablePrefixes = "$"
            l.capitalizedTypes = true
            l.keywords = w("if else elseif endif while endwhile do for endfor foreach endforeach as switch endswitch case default break continue return throw try catch finally new instanceof match yield from goto declare enddeclare include include_once require require_once use namespace insteadof echo print and or xor clone list array isset unset empty fn php")
            l.storage = w("function class interface trait enum extends implements abstract final static public private protected const var readonly global")
            l.types = w("int float bool string array object callable iterable void mixed never self parent static")
            l.constants = w("true false null TRUE FALSE NULL __CLASS__ __DIR__ __FILE__ __FUNCTION__ __LINE__ __METHOD__ __NAMESPACE__ __TRAIT__ PHP_EOL PHP_VERSION PHP_INT_MAX E_ALL")
            l.builtins = w("strlen count var_dump var_export print_r json_encode json_decode array_map array_filter array_reduce array_merge array_keys array_values array_key_exists in_array array_push array_pop explode implode str_replace str_contains str_starts_with substr strpos trim sprintf printf die exit file_get_contents file_put_contents is_array is_string is_int is_null intval strval define defined compact extract")
            l.functionDefKeywords = ["function"]
            l.typeDefKeywords = w("class interface trait enum")
        })
        a.append(Language.make("perl", "Perl") { l in
            l.lineComment = ["#"]
            l.blockComment = [("=pod", "=cut"), ("=head1", "=cut"), ("=begin", "=cut")]
            l.extensions = w("pl pm t pod psgi")
            l.aliases = w("pl perl5")
            l.shebangs = w("perl perl5")
            l.strings = [dqMulti, StringRule("'", multiline: true), StringRule("`", multiline: true)]
            l.variablePrefixes = "$@%"
            l.keywords = w("if elsif else unless while until for foreach do last next redo return goto and or not xor eq ne lt gt le ge cmp use no require BEGIN END x qw q qq")
            l.storage = w("my our local state sub package")
            l.constants = w("__PACKAGE__ __FILE__ __LINE__ __DATA__ __END__ STDIN STDOUT STDERR undef")
            l.builtins = w("print printf say open close die warn chomp chop push pop shift unshift splice split join keys values each exists delete defined length substr index rindex lc uc lcfirst ucfirst sprintf ref bless scalar wantarray map grep sort reverse eval exit sleep time localtime system exec binmode")
            l.functionDefKeywords = ["sub"]
            l.typeDefKeywords = ["package"]
            l.symbolPattern = #"^\s*(?:sub|package)\s+([\w:]+)"#
        })
        a.append(Language.make("raku", "Raku") { l in
            l.lineComment = ["#"]
            l.extensions = w("raku rakumod rakutest rakudoc p6 pm6 pl6")
            l.aliases = w("perl6")
            l.shebangs = w("raku rakudo perl6")
            l.strings = [dqMulti, StringRule("'", multiline: true)]
            l.variablePrefixes = "$@%&"
            l.identifierPartChars = "-'"
            l.capitalizedTypes = true
            l.keywords = w("if elsif else unless with orwith without while until loop repeat for given when default last next redo return die fail try catch CATCH CONTROL LEAVE and or not xor eq ne lt gt le ge cmp leg use need require import gather take")
            l.storage = w("my our has state sub method submethod multi proto only class role grammar module package token rule regex constant enum subset is does")
            l.types = w("Int Num Rat Str Bool Array Hash List Map Set Bag Any Mu Cool Range Seq Pair Code Block Callable")
            l.constants = w("True False Nil self Empty")
            l.builtins = w("say print put note dd exit")
            l.functionDefKeywords = w("sub method submethod")
            l.typeDefKeywords = w("class role grammar module")
        })
        a.append(Language.make("lua", "Lua") { l in
            l.lineComment = ["--"]
            l.blockComment = [("--[[", "]]")]
            l.extensions = w("lua luau rockspec")
            l.filenames = w(".luacheckrc .luarc")
            l.shebangs = w("lua luajit")
            l.strings = [StringRule("[[", "]]", escape: false, multiline: true), dq, sq]
            l.keywords = w("and break do else elseif end for goto if in not or repeat return then until while")
            l.storage = w("local function")
            l.constants = w("true false nil self _G _ENV _VERSION")
            l.builtins = w("print pairs ipairs next type tostring tonumber require select error assert pcall xpcall setmetatable getmetatable rawget rawset rawequal rawlen unpack load loadfile dofile collectgarbage string table math io os coroutine debug utf8 package")
            l.functionDefKeywords = ["function"]
            l.symbolPattern = #"function\s+([\w.:]+)"#
        })
        a.append(Language.make("r", "R") { l in
            l.lineComment = ["#"]
            l.extensions = w("r rprofile")
            l.filenames = w(".Rprofile")
            l.aliases = w("rscript splus")
            l.shebangs = ["Rscript"]
            l.strings = [dqMulti, StringRule("'", multiline: true), StringRule("`", escape: false)]
            l.identifierPartChars = "."
            l.keywords = w("if else for while repeat break next return function in library require")
            l.constants = w("TRUE FALSE NULL NA NaN Inf NA_integer_ NA_real_ NA_character_ T F")
            l.builtins = w("c list vector matrix data.frame factor print cat paste paste0 length names nrow ncol head tail summary str apply lapply sapply vapply mapply Map Reduce Filter seq seq_len seq_along rep sum mean median sd var min max range abs sqrt exp log round is.na which unique sort order rev table read.csv write.csv stop warning message tryCatch invisible return ifelse switch")
            l.types = w("numeric integer character logical complex double")
            l.symbolPattern = #"^\s*([A-Za-z_.][\w.]*)\s*(?:<-|=)\s*function"#
        })
        a.append(Language.make("julia", "Julia") { l in
            l.lineComment = ["#"]
            l.blockComment = [("#=", "=#")]
            l.nestedComments = true
            l.extensions = ["jl"]
            l.shebangs = ["julia"]
            l.strings = [StringRule("\"\"\"", multiline: true), dqMulti, charLit, StringRule("`")]
            l.annotationPrefix = "@"
            l.identifierPartChars = "!"
            l.capitalizedTypes = true
            l.keywords = w("if elseif else for while break continue return try catch finally end do begin let in isa where import using export as baremodule quote")
            l.storage = w("function macro struct mutable abstract primitive type module const global local")
            l.types = w("Int Int8 Int16 Int32 Int64 Int128 UInt UInt8 UInt16 UInt32 UInt64 UInt128 Float16 Float32 Float64 Bool Char String Symbol Any Nothing Missing Vector Matrix Array Dict Set Tuple NamedTuple Function Number Real Integer AbstractFloat AbstractString AbstractArray AbstractVector Complex Rational")
            l.constants = w("true false nothing missing NaN Inf pi im")
            l.builtins = w("println print show display length size push! pop! append! map filter reduce collect sum prod zip enumerate typeof isa convert parse string error throw rand zeros ones fill eachindex keys values haskey get")
            l.functionDefKeywords = w("function macro")
            l.typeDefKeywords = w("struct type module")
            l.symbolPattern = #"^\s*(?:function|macro|(?:mutable\s+)?struct|abstract\s+type|module)\s+([A-Za-z_][\w!.]*)"#
        })
        a.append(Language.make("matlab", "MATLAB") { l in
            l.lineComment = ["%", "#"]
            l.blockComment = [("%{", "%}")]
            l.extensions = ["matlab"]
            l.aliases = w("octave")
            l.strings = [StringRule("'", escape: false), dq]
            l.keywords = w("if elseif else end for parfor while switch case otherwise break continue return try catch do until unwind_protect")
            l.storage = w("function classdef properties methods events enumeration global persistent")
            l.constants = w("true false pi Inf NaN eps i j end")
            l.builtins = w("disp fprintf sprintf printf zeros ones eye rand randn size length numel abs sqrt sum mean max min plot figure hold xlabel ylabel title legend grid subplot error warning isempty strcat num2str str2num cell struct fieldnames")
            l.functionDefKeywords = ["function"]
            l.typeDefKeywords = ["classdef"]
            l.symbolPattern = #"^\s*(?:function\s+(?:\[?[\w,\s]*\]?\s*=\s*)?|classdef\s+)([A-Za-z_]\w*)"#
        })
        a.append(Language.make("tcl", "Tcl") { l in
            l.lineComment = ["#"]
            l.extensions = w("tcl tk tm itcl")
            l.shebangs = w("tclsh wish expect")
            l.strings = [dqMulti]
            l.variablePrefixes = "$"
            l.keywords = w("if then else elseif for foreach while switch break continue return catch try finally error throw eval uplevel upvar namespace package source")
            l.storage = w("proc set unset global variable array dict list")
            l.builtins = w("puts gets open close read string lindex llength lappend lrange lsearch lsort concat join split expr incr append format scan regexp regsub file glob exec after info clock exit")
            l.functionDefKeywords = ["proc"]
            l.symbolPattern = #"^\s*proc\s+([\w:]+)"#
        })
        a.append(Language.make("awk", "AWK") { l in
            l.lineComment = ["#"]
            l.extensions = w("awk gawk mawk nawk")
            l.shebangs = w("awk gawk mawk nawk")
            l.strings = [dq]
            l.variablePrefixes = "$"
            l.regexLiterals = true
            l.keywords = w("if else for while do break continue next nextfile exit return in delete getline BEGIN END BEGINFILE ENDFILE")
            l.storage = w("function func")
            l.constants = w("NR NF FS OFS RS ORS FILENAME FNR SUBSEP RSTART RLENGTH ENVIRON ARGC ARGV CONVFMT OFMT")
            l.builtins = w("print printf length substr index split sub gsub match sprintf tolower toupper sin cos atan2 exp log sqrt int rand srand system close fflush gensub strftime systime")
            l.functionDefKeywords = w("function func")
        })
        a.append(Language.make("coffeescript", "CoffeeScript") { l in
            l.lineComment = ["#"]
            l.blockComment = [("###", "###")]
            l.extensions = w("coffee cson iced litcoffee")
            l.filenames = ["Cakefile"]
            l.aliases = w("coffee coffee-script")
            l.shebangs = ["coffee"]
            l.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), dqMulti, StringRule("'", multiline: true), StringRule("`", multiline: true)]
            l.variablePrefixes = "@"
            l.identifierChars = "$"
            l.regexLiterals = true
            l.capitalizedTypes = true
            l.indentAfterColon = true
            l.keywords = w("if else unless then for in of own by when while until loop switch break continue return throw try catch finally new delete typeof instanceof and or not is isnt yes no on off do import export from as await yield super extends")
            l.storage = w("class")
            l.constants = w("true false null undefined this NaN Infinity")
            l.builtins = w("console window document require module exports process Math JSON Object Array String Number Promise")
            l.typeDefKeywords = ["class"]
            l.symbolPattern = #"^\s*(?:class\s+|(?=[A-Za-z_$][\w$]*\s*[:=]\s*(?:\([^)]*\)\s*)?[-=]>))([A-Za-z_$][\w$.]*)"#
        })
        a.append(Language.make("applescript", "AppleScript") { l in
            l.lineComment = ["--", "#"]
            l.blockComment = [("(*", "*)")]
            l.nestedComments = true
            l.extensions = ["applescript"]
            l.aliases = ["osascript"]
            l.shebangs = ["osascript"]
            l.strings = [dq]
            l.caseInsensitive = true
            l.autoPairs = "()[]{}\"\""
            l.keywords = w("if then else end repeat with from to by times while until in exit return try error considering ignoring tell of and or not is contains does equal equals greater less than starts ends begins the a an as copy set get into put after before")
            l.storage = w("on to property global local script use")
            l.types = w("text string integer real number boolean list record date alias file application")
            l.constants = w("true false missing value me my it result return space tab linefeed quote pi")
            l.builtins = w("display dialog alert notification activate quit run launch open close delay say beep log count")
            l.functionCalls = false
            l.functionDefKeywords = w("on to")
            l.symbolPattern = #"^\s*(?:on|to)\s+([A-Za-z_]\w*)"#
        })
        a.append(Language.make("vim", "Vim Script") { l in
            l.lineComment = ["\" "]
            l.extensions = ["vim"]
            l.filenames = w(".vimrc .gvimrc _vimrc _gvimrc .exrc .ideavimrc")
            l.aliases = w("viml vimscript")
            l.strings = [dq, sqRaw]
            l.identifierPartChars = "#:"
            l.keywords = w("if elseif else endif for endfor in while endwhile try catch finally endtry throw return break continue call execute exe normal silent autocmd augroup echo echom let unlet set setlocal map nmap vmap imap noremap nnoremap vnoremap inoremap xnoremap command source runtime syntax highlight hi filetype")
            l.storage = w("function endfunction func endfunc def enddef const var abort range dict closure")
            l.constants = w("v:true v:false v:null")
            l.builtins = w("exists has expand getline setline line col len strlen split join substitute matchstr match printf type empty get add remove filter map keys values range")
            l.functionDefKeywords = w("function func def")
            l.symbolPattern = #"^\s*(?:fu(?:nction)?|def)!?\s+([\w:#.<>]+)"#
        })
    }

    // MARK: - Shells

    private static func shells(_ a: inout [Language]) {
        a.append(Language.make("shell", "Shell Script") { l in
            l.lineComment = ["#"]
            l.extensions = w("sh bash zsh ksh mksh command bats ebuild eclass")
            l.filenames = w(".bashrc .bash_profile .bash_logout .bash_aliases .bash_functions .zshrc .zshenv .zprofile .zlogin .zlogout .profile .kshrc .envrc .xprofile .xinitrc .xsession PKGBUILD APKBUILD")
            l.aliases = w("sh bash zsh ksh shell console shellscript")
            l.shebangs = w("bash sh zsh ksh mksh dash ash")
            l.strings = [StringRule("\"", multiline: true, interpolation: .dollarParen, variables: true),
                         StringRule("'", escape: false, multiline: true), StringRule("`", multiline: true)]
            l.heredoc = "<<"
            l.heredocAllowsSpace = true
            l.commentsNeedSpace = true
            l.variablePrefixes = "$"
            l.autoPairs = "()[]{}\"\"''``"
            l.keywords = w("if then else elif fi case esac for select while until do done in function time coproc return exit break continue")
            l.storage = w("local export readonly declare typeset unset alias")
            l.builtins = w("echo printf read cd pwd source eval exec shift trap set test wait kill getopts let ulimit umask type command hash history jobs fg bg pushd popd dirs shopt complete compgen mapfile readarray true false ls cat grep egrep sed awk find xargs sort uniq head tail cut tr wc tee mkdir rmdir rm cp mv chmod chown ln touch curl wget git tar gzip unzip sudo ssh scp rsync make docker kubectl brew apt npm bun yarn pip python node")
            l.functionDefKeywords = ["function"]
            l.symbolPattern = #"^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)"#
        })
        a.append(Language.make("fish", "Fish") { l in
            l.lineComment = ["#"]
            l.extensions = ["fish"]
            l.shebangs = ["fish"]
            l.strings = [dqMulti, StringRule("'", multiline: true)]
            l.variablePrefixes = "$"
            l.keywords = w("if else end for in while switch case function return break continue and or not begin exit")
            l.storage = w("set function")
            l.builtins = w("echo printf set_color string math test contains status functions source cd count abbr alias argparse builtin command emit eval exec read fish_add_path type random path")
            l.constants = w("true false")
            l.functionDefKeywords = ["function"]
            l.symbolPattern = #"^\s*function\s+([\w-]+)"#
        })
        a.append(Language.make("powershell", "PowerShell") { l in
            l.lineComment = ["#"]
            l.blockComment = [("<#", "#>")]
            l.extensions = w("ps1 psm1 psd1")
            l.aliases = w("ps1 pwsh posh ps")
            l.shebangs = w("pwsh powershell")
            l.strings = [StringRule("@\"", "\"@", escape: false, multiline: true), StringRule("@'", "'@", escape: false, multiline: true),
                         StringRule("\"", escape: false, multiline: true), StringRule("'", escape: false, multiline: true)]
            l.variablePrefixes = "$"
            l.identifierPartChars = "-"
            l.caseInsensitive = true
            l.keywords = w("if elseif else switch foreach for while do until break continue return throw try catch finally trap exit in begin process end dynamicparam filter workflow data")
            l.storage = w("function class enum using module param hidden static")
            l.types = w("string int long bool double decimal array hashtable object psobject pscustomobject datetime void char byte scriptblock switch")
            l.builtins = w("Write-Host Write-Output Write-Error Write-Warning Write-Verbose Write-Debug Get-ChildItem Set-Location Get-Location Get-Content Set-Content Add-Content Get-Item New-Item Remove-Item Copy-Item Move-Item Rename-Item Test-Path Join-Path Split-Path Resolve-Path Select-Object Where-Object ForEach-Object Sort-Object Group-Object Measure-Object Get-Process Start-Process Stop-Process Get-Service Invoke-WebRequest Invoke-RestMethod Invoke-Expression Import-Module Export-ModuleMember Out-File Out-Null ConvertTo-Json ConvertFrom-Json Get-Date Read-Host Start-Sleep New-Object Get-Member")
            l.functionDefKeywords = w("function filter")
            l.typeDefKeywords = w("class enum")
            l.symbolPattern = #"(?i)^\s*(?:function|filter|class|enum)\s+([\w-]+)"#
        })
        a.append(Language.make("batch", "Batch File") { l in
            l.lineComment = ["REM ", "rem ", "Rem ", "@REM ", "@rem ", "::"]
            l.extensions = w("bat cmd")
            l.aliases = w("bat cmd dosbatch")
            l.strings = [StringRule("\"", escape: false)]
            l.variablePrefixes = "%!"
            l.caseInsensitive = true
            l.functionCalls = false
            l.keywords = w("if else for in do goto call exit not exist defined errorlevel equ neq lss leq gtr geq nul con")
            l.storage = w("set setlocal endlocal enabledelayedexpansion enableextensions shift")
            l.builtins = w("echo cd chdir pushd popd dir copy xcopy robocopy move del erase ren rename md mkdir rd rmdir type cls pause start title color prompt path where find findstr choice timeout tasklist taskkill")
            l.constants = w("on off")
            l.symbolPattern = #"^:([A-Za-z_]\w*)"#
        })
    }

    // MARK: - Functional languages

    private static func haskellLike(_ l: Language) {
        l.lineComment = ["--"]
        l.blockComment = [("{-", "-}")]
        l.nestedComments = true
        l.strings = [dqMulti, charLit]
        l.identifierPartChars = "'"
        l.capitalizedTypes = true
        l.autoPairs = "()[]{}\"\""
        l.symbolPattern = #"^(?:(?:data|newtype|type(?:\s+(?:family|alias))?|class)\s+)?([A-Za-z_][\w']*)\s*(?:::|\s.*=|=)"#
    }

    private static func functional(_ a: inout [Language]) {
        a.append(Language.make("haskell", "Haskell") { l in
            haskellLike(l)
            l.extensions = w("hs hs-boot hsig")
            l.aliases = ["hs"]
            l.shebangs = w("runhaskell runghc stack")
            l.keywords = w("if then else case of let in where do module import qualified as hiding deriving via forall mdo rec proc infix infixl infixr")
            l.storage = w("data newtype type class instance family default foreign pattern")
            l.types = w("Int Integer Float Double Bool Char String IO Maybe Either Ordering Word Rational Num Eq Ord Show Read Functor Applicative Monad Foldable Traversable Semigroup Monoid Text ByteString")
            l.constants = w("True False Nothing Just Left Right LT EQ GT otherwise undefined")
            l.builtins = w("map filter foldr foldl foldl' head tail null length reverse concat concatMap zip zipWith unzip lookup elem fst snd show read print putStrLn putStr getLine return pure fmap mapM mapM_ forM forM_ sequence error id const flip not and or any all sum product maximum minimum take drop splitAt span lines unlines words unwords")
            l.typeDefKeywords = w("data newtype type class instance")
        })
        a.append(Language.make("purescript", "PureScript") { l in
            haskellLike(l)
            l.extensions = ["purs"]
            l.aliases = ["purs"]
            l.keywords = w("if then else case of let in where do ado module import as hiding derive forall infix infixl infixr")
            l.storage = w("data newtype type class instance foreign")
            l.types = w("Int Number Boolean Char String Array Effect Aff Maybe Either Unit Record")
            l.constants = w("true false Nothing Just Left Right unit")
            l.builtins = w("map pure bind log show discard")
            l.typeDefKeywords = w("data newtype type class instance")
        })
        a.append(Language.make("elm", "Elm") { l in
            haskellLike(l)
            l.extensions = ["elm"]
            l.keywords = w("if then else case of let in module import exposing as port effect where")
            l.storage = w("type alias")
            l.types = w("Int Float Bool Char String List Maybe Result Cmd Sub Html Msg Model Dict Set Array Task Never")
            l.constants = w("True False Nothing Just Ok Err")
            l.builtins = w("identity always not toString round floor ceiling abs min max negate modBy remainderBy")
            l.typeDefKeywords = w("type alias")
        })
        a.append(Language.make("ocaml", "OCaml") { l in
            l.blockComment = [("(*", "*)")]
            l.nestedComments = true
            l.extensions = w("ml mli mll mly")
            l.shebangs = w("ocaml ocamlrun")
            l.strings = [dqMulti, charLit]
            l.identifierPartChars = "'"
            l.capitalizedTypes = true
            l.autoPairs = "()[]{}\"\""
            l.keywords = w("if then else match with when function fun for to downto do done while try raise begin end in as of assert lazy open include and or not mod land lor lxor lsl lsr asr")
            l.storage = w("let rec type module sig struct functor val external mutable private virtual method object class inherit initializer constraint new exception")
            l.types = w("int float bool char string bytes unit list array option result ref exn format")
            l.constants = w("true false None Some Ok Error")
            l.builtins = w("print_string print_endline print_int print_float print_newline printf sprintf failwith invalid_arg ignore fst snd not raise List Array String Printf Hashtbl Option Result Seq Map Set")
            l.typeDefKeywords = w("type module exception")
            l.symbolPattern = #"^\s*(?:let(?:\s+rec)?|and|type|module(?:\s+type)?|exception|val|external)\s+([A-Za-z_][\w']*)"#
        })
        a.append(Language.make("reason", "ReasonML") { l in
            cComments(l)
            l.nestedComments = true
            l.extensions = w("re rei res resi")
            l.aliases = w("reasonml rescript")
            l.strings = [dqMulti, charLit, StringRule("`", multiline: true)]
            l.capitalizedTypes = true
            l.autoPairs = "()[]{}\"\""
            l.keywords = w("if else switch for while try raise in to downto open include assert lazy when as and")
            l.storage = w("let rec type module external mutable exception and")
            l.types = w("int float bool char string unit list array option result")
            l.constants = w("true false None Some Ok Error")
            l.builtins = w("print_endline Js Belt Console")
            l.typeDefKeywords = w("type module")
            l.symbolPattern = #"^\s*(?:let(?:\s+rec)?|type|module)\s+([A-Za-z_][\w']*)"#
        })
        a.append(Language.make("erlang", "Erlang") { l in
            l.lineComment = ["%"]
            l.extensions = w("erl hrl escript")
            l.filenames = w("rebar.config rebar.lock sys.config")
            l.shebangs = ["escript"]
            l.strings = [dqMulti, StringRule("'", kind: .constant)]
            l.autoPairs = "()[]{}\"\""
            l.keywords = w("if case of end receive after when fun try catch throw begin and andalso or orelse not xor band bor bxor bnot bsl bsr div rem maybe else")
            l.storage = w("module export import record define include include_lib behaviour behavior spec type opaque callback")
            l.constants = w("true false undefined ok error")
            l.builtins = w("spawn spawn_link send self exit link unlink register whereis apply length hd tl element setelement tuple_size list_to_atom atom_to_list integer_to_list list_to_integer is_atom is_list is_tuple is_integer is_binary is_function is_pid io lists maps gen_server supervisor ets")
            l.symbolPattern = #"^([a-z]\w*)\s*\("#
        })
        a.append(Language.make("elixir", "Elixir") { l in
            l.lineComment = ["#"]
            l.extensions = w("ex exs")
            l.filenames = ["mix.lock"]
            l.aliases = w("ex exs iex")
            l.shebangs = w("elixir iex")
            l.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), dqMulti, sq]
            l.annotationPrefix = "@"
            l.identifierPartChars = "?!"
            l.capitalizedTypes = true
            l.keywords = w("if else unless case cond with for try catch rescue after raise throw receive do end fn when in and or not import alias require use quote unquote unquote_splicing")
            l.storage = w("def defp defmodule defmacro defmacrop defguard defguardp defstruct defprotocol defimpl defdelegate defexception defoverridable")
            l.constants = w("true false nil __MODULE__ __ENV__ __DIR__ __CALLER__ __STACKTRACE__")
            l.builtins = w("IO Enum Map List String Kernel Process Agent GenServer Task Supervisor Stream Keyword Integer Float Tuple is_atom is_binary is_list is_map is_integer is_nil is_function length hd tl elem put_elem spawn spawn_link send self inspect apply raise to_string")
            l.functionDefKeywords = w("def defp defmacro defmacrop defguard defguardp defdelegate")
            l.typeDefKeywords = w("defmodule defprotocol defimpl")
            l.symbolPattern = #"^\s*(?:def|defp|defmodule|defmacro|defmacrop|defprotocol|defimpl|defguard)\s+([\w.?!]+)"#
        })
        a.append(Language.make("gleam", "Gleam") { l in
            l.lineComment = ["//"]
            l.extensions = ["gleam"]
            l.strings = [dqMulti]
            l.annotationPrefix = "@"
            l.capitalizedTypes = true
            l.keywords = w("case if as use import todo panic assert echo let")
            l.storage = w("fn pub type const opaque external")
            l.types = w("Int Float String Bool List Result Option Nil BitArray Dict")
            l.constants = w("True False Nil Ok Error")
            l.builtins = w("io list string int float result option dict")
            l.functionDefKeywords = ["fn"]
            l.typeDefKeywords = ["type"]
            l.symbolPattern = #"^\s*(?:pub\s+)?(?:opaque\s+)?(?:fn|type|const)\s+([A-Za-z_]\w*)"#
        })
    }

    // MARK: - Lisps

    private static func lispBase(_ l: Language) {
        l.lineComment = [";"]
        l.strings = [dqMulti]
        l.identifierChars = "-"
        l.identifierPartChars = "?!*+<>=/:%.&"
        l.operatorChars = ""
        l.functionCalls = false
        l.autoPairs = "()[]{}\"\""
    }

    private static func lisps(_ a: inout [Language]) {
        a.append(Language.make("lisp", "Lisp") { l in
            lispBase(l)
            l.blockComment = [("#|", "|#")]
            l.nestedComments = true
            l.extensions = w("lisp cl el scm ss rkt rktl lsp sld sls asd")
            l.filenames = w(".emacs .sbclrc .spacemacs")
            l.aliases = w("common-lisp commonlisp elisp emacs-lisp emacslisp scheme racket guile")
            l.shebangs = w("racket guile sbcl clisp csi scheme")
            l.keywords = w("if cond case when unless and or not let let* letrec letrec* flet labels lambda progn prog1 begin do dolist dotimes loop return return-from block catch throw unwind-protect handler-case condition-case ignore-errors quote quasiquote unquote function setq setf set! incf decf push pop require provide import module use-package in-package with-open-file")
            l.storage = w("defun defmacro defvar defparameter defconstant defclass defstruct defgeneric defmethod defpackage defcustom defgroup defface defalias defsubst define define-syntax define-record-type define-values define-module")
            l.constants = w("t nil #t #f true false")
            l.builtins = w("car cdr cons list append length nth mapcar mapc map apply funcall format print princ prin1 message display newline eq eql equal null listp consp atom vector make-hash-table gethash error assert concat string-append number->string")
            l.symbolPattern = #"^\s*\((?:defun|defmacro|defvar|defparameter|defconstant|defclass|defstruct|defgeneric|defmethod|defcustom|defalias|define(?:-syntax|-record-type|-values)?)\s+\(?([^\s()]+)"#
        })
        a.append(Language.make("clojure", "Clojure") { l in
            lispBase(l)
            l.identifierPartChars = "?!*+<>=/.'#"
            l.extensions = w("clj cljs cljc cljd edn bb")
            l.filenames = ["project.clj"]
            l.aliases = w("clj cljs clojurescript edn")
            l.shebangs = w("bb clojure clj")
            l.keywords = w("if if-not if-let if-some when when-not when-let when-some cond condp case and or not let letfn loop recur do fn fn* try catch finally throw quote var binding doseq dotimes for while ns require import use refer")
            l.storage = w("def defn defn- defmacro defmulti defmethod defprotocol defrecord deftype defonce definterface declare")
            l.constants = w("true false nil")
            l.builtins = w("map filter reduce first rest next cons conj assoc dissoc get get-in assoc-in update update-in keys vals count seq vec into str println print prn pr-str apply partial comp identity atom swap! reset! deref range take drop concat mapcat some every? empty? nil? merge select-keys")
            l.symbolPattern = #"^\s*\((?:defn-?|defmacro|defmulti|defprotocol|defrecord|deftype|defonce|def|ns)\s+(?:\^\S+\s+)?([^\s()\[\]]+)"#
        })
        a.append(Language.make("fennel", "Fennel") { l in
            lispBase(l)
            l.extensions = ["fnl"]
            l.shebangs = ["fennel"]
            l.keywords = w("if when unless and or not let do while for each icollect collect accumulate fn lambda λ match case values require import-macros quote")
            l.storage = w("local var global set fn macro macros")
            l.constants = w("true false nil")
            l.builtins = w("print pairs ipairs table string math tostring tonumber type length")
            l.symbolPattern = #"^\s*\((?:fn|local|global|macro|var)\s+([^\s()\[\]]+)"#
        })
        a.append(Language.make("janet", "Janet") { l in
            lispBase(l)
            l.lineComment = ["#"]
            l.strings = [dqMulti, StringRule("`", escape: false, multiline: true)]
            l.extensions = ["janet"]
            l.shebangs = ["janet"]
            l.keywords = w("if when unless cond case and or not let do while loop each for fn try match break quote import use")
            l.storage = w("def defn defn- defmacro var varfn")
            l.constants = w("true false nil")
            l.builtins = w("print printf pp map filter reduce length get put array tuple table struct string keys values")
            l.symbolPattern = #"^\s*\((?:defn-?|defmacro|def|var)\s+([^\s()\[\]]+)"#
        })
    }

    // MARK: - JavaScript family

    private static let jsKeywords = "if else for while do switch case default break continue return throw try catch finally new delete typeof instanceof in of void yield await import export from as with debugger"
    private static let jsStorage = "var let const function class extends static async get set"
    private static let jsTypes = "Object Array String Number Boolean Symbol BigInt Function Promise Map Set WeakMap WeakSet WeakRef Date RegExp Error TypeError RangeError SyntaxError ReferenceError EvalError URIError AggregateError Reflect Proxy Intl ArrayBuffer SharedArrayBuffer DataView Int8Array Uint8Array Uint8ClampedArray Int16Array Uint16Array Int32Array Uint32Array Float32Array Float64Array BigInt64Array BigUint64Array URL URLSearchParams Request Response Headers FormData Blob File Event EventTarget Element HTMLElement Node"
    private static let jsConstants = "true false null undefined this super NaN Infinity arguments"
    private static let jsBuiltins = "console window document globalThis process require module exports __dirname __filename Math JSON parseInt parseFloat isNaN isFinite encodeURIComponent decodeURIComponent encodeURI decodeURI setTimeout setInterval clearTimeout clearInterval setImmediate queueMicrotask requestAnimationFrame structuredClone fetch alert confirm prompt navigator location history localStorage sessionStorage performance crypto Deno Bun Buffer atob btoa"
    private static let tsStorage = "interface type enum namespace declare abstract implements public private protected readonly keyof infer is asserts satisfies override module unique accessor"
    private static let tsTypes = "string number boolean any unknown never void object bigint symbol Partial Required Readonly Record Pick Omit Exclude Extract NonNullable ReturnType Parameters InstanceType Awaited Uppercase Lowercase Capitalize Uncapitalize ThisType ConstructorParameters NoInfer"

    private static func jsBase(_ l: Language, typescript: Bool) {
        cComments(l)
        l.strings = [dq, sq, StringRule("`", multiline: true, interpolation: .dollarBrace)]
        l.identifierChars = "$"
        l.annotationPrefix = "@"
        l.regexLiterals = true
        l.capitalizedTypes = true
        l.autoPairs = "()[]{}\"\"''``"
        l.keywords = w(jsKeywords)
        l.storage = w(typescript ? jsStorage + " " + tsStorage : jsStorage)
        l.types = w(typescript ? jsTypes + " " + tsTypes : jsTypes)
        l.constants = w(jsConstants)
        l.builtins = w(jsBuiltins)
        l.functionDefKeywords = ["function"]
        l.typeDefKeywords = w(typescript ? "class interface type enum namespace" : "class")
        l.symbolPattern = #"^[ \t]*(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?(?:async\s+)?(?:function\*?\s*|class\s+|interface\s+|type\s+(?=[\w$]+\s*[=<])|enum\s+|namespace\s+|(?:const|let|var)\s+(?=[\w$]+\s*(?::[^=]+)?=\s*(?:async\s*)?(?:function\b|\([^)]*\)\s*(?::[^=]+)?=>|[\w$]+\s*=>)))([A-Za-z_$][\w$]*)"#
    }

    private static func web(_ a: inout [Language]) {
        a.append(Language.make("javascript", "JavaScript") { l in
            jsBase(l, typescript: false)
            l.extensions = w("js mjs cjs es6 es jsb")
            l.aliases = w("js node nodejs mjs cjs ecmascript")
            l.shebangs = w("node nodejs deno bun qjs")
        })
        a.append(Language.make("jsx", "JavaScript JSX") { l in
            jsBase(l, typescript: false)
            l.extensions = ["jsx"]
            l.aliases = w("javascriptreact react")
        })
        a.append(Language.make("typescript", "TypeScript") { l in
            jsBase(l, typescript: true)
            l.extensions = w("ts mts cts d.ts d.mts d.cts")
            l.aliases = w("ts mts cts")
            l.shebangs = w("ts-node tsx")
        })
        a.append(Language.make("tsx", "TypeScript JSX") { l in
            jsBase(l, typescript: true)
            l.extensions = ["tsx"]
            l.aliases = ["typescriptreact"]
        })
        a.append(Language.make("json", "JSON") { l in
            l.extensions = w("json webmanifest code-workspace geojson topojson har avsc jsonl ndjson mcmeta gltf ipynb")
            l.filenames = w(".prettierrc .watchmanconfig .arcconfig composer.lock flake.lock Pipfile.lock .all-contributorsrc .lintstagedrc")
            l.strings = [dq]
            l.propertyKeys = .jsonKeys
            l.functionCalls = false
            l.operatorChars = ":-"
            l.constants = w("true false null")
            l.symbolPattern = #"^\s{0,4}"([^"]+)"\s*:"#
        })
        a.append(Language.make("jsonc", "JSON with Comments") { l in
            cComments(l)
            l.extensions = ["jsonc"]
            l.filenames = w("tsconfig.json jsconfig.json .eslintrc .eslintrc.json .babelrc .babelrc.json .swcrc .jshintrc .jscsrc .hintrc settings.json keybindings.json launch.json tasks.json extensions.json devcontainer.json .devcontainer.json api-extractor.json tslint.json typedoc.json")
            l.aliases = ["json-with-comments"]
            l.strings = [dq]
            l.propertyKeys = .jsonKeys
            l.functionCalls = false
            l.operatorChars = ":-"
            l.constants = w("true false null")
            l.symbolPattern = #"^\s{0,4}"([^"]+)"\s*:"#
        })
        a.append(Language.make("json5", "JSON5") { l in
            cComments(l)
            l.extensions = ["json5"]
            l.strings = [dq, sq]
            l.propertyKeys = .jsonKeys
            l.functionCalls = false
            l.operatorChars = ":-+"
            l.constants = w("true false null Infinity NaN")
        })
    }

    // MARK: - Stylesheets

    private static let cssConstants = "auto none inherit initial unset revert normal bold italic block inline inline-block flex inline-flex grid inline-grid contents hidden visible absolute relative fixed sticky static center left right top bottom middle baseline stretch start end space-between space-around space-evenly wrap nowrap row column solid dashed dotted double transparent currentColor pointer default uppercase lowercase capitalize underline ease ease-in ease-out ease-in-out linear infinite forwards backwards both alternate !important important"
    private static let cssBuiltins = "rgb rgba hsl hsla hwb lab lch oklab oklch color-mix url var calc min max clamp attr env translate translateX translateY translateZ translate3d rotate rotateX rotateY rotateZ scale scaleX scaleY skew matrix perspective linear-gradient radial-gradient conic-gradient repeating-linear-gradient cubic-bezier steps repeat minmax fit-content blur brightness contrast drop-shadow grayscale invert opacity saturate sepia format local selector supports"

    private static func cssBase(_ l: Language) {
        l.blockComment = [("/*", "*/")]
        l.strings = [dq, sq]
        l.cssMode = true
        l.propertyKeys = .colon
        l.identifierChars = "-"
        // Lets numbers take a % unit (100%).
        l.identifierPartChars = "%"
        l.annotationPrefix = "@"
        l.operatorChars = "+*/%=&|^!<>~?:"
        l.keywords = w("and not only or from to through if else each for while in return")
        l.constants = w(cssConstants)
        l.builtins = w(cssBuiltins)
        l.symbolPattern = #"^([^\s{}@/][^{};]*?)\s*\{"#
    }

    private static func styles(_ a: inout [Language]) {
        a.append(Language.make("css", "CSS") { l in
            cssBase(l)
            l.extensions = w("css pcss postcss wxss")
        })
        a.append(Language.make("scss", "SCSS") { l in
            cssBase(l)
            l.lineComment = ["//"]
            l.extensions = ["scss"]
            l.variablePrefixes = "$"
            l.storage = w("@mixin @include @function @return @extend @use @forward @import @if @else @each @for @while")
            l.builtins = w(cssBuiltins + " map-get map-merge map-has-key nth length append join lighten darken mix rgba percentage round ceil floor if unquote quote type-of")
        })
        a.append(Language.make("sass", "Sass") { l in
            cssBase(l)
            l.lineComment = ["//"]
            l.extensions = ["sass"]
            l.variablePrefixes = "$"
            l.indentAfter = ""
            l.dedentChars = ""
            l.symbolPattern = #"^([.#&%A-Za-z][^:\n]*?)\s*$"#
        })
        a.append(Language.make("less", "Less") { l in
            cssBase(l)
            l.lineComment = ["//"]
            l.extensions = ["less"]
            l.variablePrefixes = "@"
            l.annotationPrefix = ""
            l.builtins = w(cssBuiltins + " lighten darken saturate desaturate fade fadein fadeout spin mix tint shade e escape percentage round ceil floor")
        })
        a.append(Language.make("stylus", "Stylus") { l in
            cssBase(l)
            l.lineComment = ["//"]
            l.extensions = w("styl stylus")
            l.aliases = ["styl"]
            l.variablePrefixes = "$"
        })
    }

    // MARK: - Markup and templates

    private static func markupBase(_ l: Language) {
        l.style = .markup
        l.blockComment = [("<!--", "-->")]
        l.strings = [dq, sq]
        l.embeddedScript = "javascript"
        l.embeddedStyle = "css"
        l.symbolPattern = #"id="([^"]+)""#
    }

    private static func markup(_ a: inout [Language]) {
        a.append(Language.make("html", "HTML") { l in
            markupBase(l)
            l.extensions = w("html htm xhtml shtml xht hta")
            l.aliases = w("htm xhtml")
        })
        a.append(Language.make("xml", "XML") { l in
            markupBase(l)
            l.embeddedScript = nil
            l.embeddedStyle = nil
            l.extensions = w("xml xsd xsl xslt plist svg csproj vbproj fsproj vcxproj props targets nuspec xaml axaml storyboard xib entitlements resx rss atom kml gpx wsdl xliff xlf tmlanguage tmtheme tmsnippet dae xcscheme xcworkspacedata xcsettings opml fxml glade ui rdf xul mobileconfig manifest")
            l.aliases = w("xsd xsl svg plist rss")
            l.symbolPattern = #"<(?:\w+:)?\w+[^>]*?\b(?:id|name|android:id)="([^"]+)""#
        })
        a.append(Language.make("vue", "Vue") { l in
            markupBase(l)
            l.extensions = ["vue"]
        })
        a.append(Language.make("svelte", "Svelte") { l in
            markupBase(l)
            l.extensions = ["svelte"]
        })
        a.append(Language.make("astro", "Astro") { l in
            markupBase(l)
            l.extensions = ["astro"]
        })
        a.append(Language.make("handlebars", "Handlebars") { l in
            markupBase(l)
            l.blockComment = [("{{!--", "--}}"), ("{{!", "}}"), ("<!--", "-->")]
            l.extensions = w("hbs handlebars mustache")
            l.aliases = w("hbs mustache")
        })
        a.append(Language.make("jinja", "Jinja") { l in
            markupBase(l)
            l.blockComment = [("{#", "#}"), ("<!--", "-->")]
            l.extensions = w("j2 jinja jinja2 njk nunjucks")
            l.aliases = w("jinja2 j2 django nunjucks")
        })
        a.append(Language.make("liquid", "Liquid") { l in
            markupBase(l)
            l.blockComment = [("{% comment %}", "{% endcomment %}"), ("{%- comment -%}", "{%- endcomment -%}"), ("<!--", "-->")]
            l.extensions = ["liquid"]
        })
        a.append(Language.make("twig", "Twig") { l in
            markupBase(l)
            l.blockComment = [("{#", "#}"), ("<!--", "-->")]
            l.extensions = ["twig"]
        })
        a.append(Language.make("erb", "ERB") { l in
            markupBase(l)
            l.blockComment = [("<%#", "%>"), ("<!--", "-->")]
            l.extensions = w("erb rhtml")
            l.aliases = w("eruby html+erb")
        })
        a.append(Language.make("razor", "Razor") { l in
            markupBase(l)
            l.blockComment = [("@*", "*@"), ("<!--", "-->")]
            l.extensions = w("cshtml razor")
            l.aliases = ["cshtml"]
        })
    }

    // MARK: - Documents

    private static func documents(_ a: inout [Language]) {
        a.append(Language.make("markdown", "Markdown") { l in
            l.style = .markdown
            l.extensions = w("md markdown mdown mkd mkdn mdwn mdx mdtxt mdtext ronn workbook")
            l.aliases = w("md mdx gfm")
            l.blockComment = [("<!--", "-->")]
            l.autoPairs = "()[]{}\"\"``"
            l.symbolPattern = #"^#{1,6}[ \t]+(.+)$"#
        })
        a.append(Language.make("rst", "reStructuredText") { l in
            l.lineComment = [".. "]
            l.extensions = w("rst rest")
            l.aliases = w("restructuredtext")
            l.strings = [StringRule("``", escape: false, kind: .code), StringRule("`", escape: false, kind: .link)]
            l.functionCalls = false
            l.operatorChars = ""
            l.linePrefixRules = [("====", .heading), ("----", .heading), ("~~~~", .heading), ("^^^^", .heading), ("****", .heading), ("####", .heading), ("++++", .heading)] as [(String, TokenKind)]
            l.symbolPattern = #"^([^\s].*)\n[=\-~^"'`#*+]{3,}\s*$"#
        })
        a.append(Language.make("latex", "LaTeX") { l in
            l.lineComment = ["%"]
            l.extensions = w("tex sty cls ltx dtx ins bib bbx cbx latex")
            l.aliases = w("tex bibtex context")
            l.strings = [StringRule("$$", escape: false, multiline: true), StringRule("$", escape: false)]
            l.variablePrefixes = "\\"
            l.functionCalls = false
            l.operatorChars = "&^_~"
            l.keywords = w("begin end")
            l.symbolPattern = #"\\(?:part|chapter|section|subsection|subsubsection|paragraph)\*?\{([^}]*)\}"#
        })
        a.append(Language.make("csv", "CSV") { l in
            l.style = .plain
            l.extensions = w("csv psv")
        })
        a.append(Language.make("tsv", "TSV") { l in
            l.style = .plain
            l.extensions = w("tsv tab")
        })
        a.append(Language.make("git-commit", "Git Commit Message") { l in
            l.filenames = w("COMMIT_EDITMSG MERGE_MSG TAG_EDITMSG SQUASH_MSG")
            l.aliases = w("gitcommit commit")
            l.functionCalls = false
            l.operatorChars = ""
            l.linePrefixRules = [("#", .comment)] as [(String, TokenKind)]
        })
        a.append(Language.make("git-rebase", "Git Rebase Todo") { l in
            l.lineComment = ["#"]
            l.filenames = ["git-rebase-todo"]
            l.aliases = ["gitrebase"]
            l.functionCalls = false
            l.operatorChars = ""
            l.keywords = w("pick p reword r edit e squash s fixup f exec x break b drop d label l reset t merge m update-ref u")
        })
        a.append(Language.make("diff", "Diff") { l in
            l.extensions = w("diff patch rej")
            l.aliases = w("patch udiff")
            l.functionCalls = false
            l.operatorChars = ""
            l.autoPairs = ""
            l.linePrefixRules = [("+++", .heading), ("---", .heading), ("diff ", .heading), ("index ", .comment),
                                 ("@@", .changed), ("+", .inserted), ("-", .deleted), ("!", .changed)] as [(String, TokenKind)]
            l.symbolPattern = #"^\+\+\+ (?:b/)?(\S+)"#
        })
    }

    // MARK: - Data and schema languages

    private static func data(_ a: inout [Language]) {
        a.append(Language.make("yaml", "YAML") { l in
            l.lineComment = ["#"]
            l.extensions = w("yml yaml cff sublime-syntax mir reek")
            l.filenames = w(".clang-format .clang-tidy .clangd .yamllint .gemrc Procfile .condarc pubspec.lock")
            l.aliases = ["yml"]
            l.strings = [dq, StringRule("'", escape: false)]
            l.commentsNeedSpace = true
            l.blockScalars = true
            l.propertyKeys = .colon
            l.indentAfterColon = true
            l.identifierPartChars = "-."
            l.variablePrefixes = "&*"
            l.annotationPrefix = "!"
            l.functionCalls = false
            l.operatorChars = ":-|>?"
            l.constants = w("true false null yes no on off True False TRUE FALSE Null NULL Yes No ~")
            l.symbolPattern = #"^([A-Za-z_][\w-]*):"#
        })
        a.append(Language.make("toml", "TOML") { l in
            l.lineComment = ["#"]
            l.extensions = ["toml"]
            l.filenames = w("Cargo.lock Pipfile poetry.lock uv.lock Gopkg.lock pdm.lock")
            l.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", escape: false, multiline: true), dq, sqRaw]
            l.propertyKeys = .equals
            l.sectionHeaders = true
            l.identifierPartChars = "-."
            l.functionCalls = false
            l.operatorChars = "=:+-"
            l.constants = w("true false inf nan")
            l.symbolPattern = #"^\s*\[+([^\]]+)\]"#
        })
        a.append(Language.make("protobuf", "Protocol Buffers") { l in
            cComments(l)
            l.extensions = w("proto proto3")
            l.aliases = w("proto proto3")
            l.strings = [dq, sq]
            l.capitalizedTypes = true
            l.keywords = w("syntax edition import package option returns stream reserved to max weak public")
            l.storage = w("message enum service rpc oneof extend extensions optional required repeated map group")
            l.types = w("double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes")
            l.constants = w("true false inf nan")
            l.functionDefKeywords = ["rpc"]
            l.typeDefKeywords = w("message enum service extend")
            l.symbolPattern = #"^\s*(?:message|enum|service|rpc|extend)\s+([A-Za-z_][\w.]*)"#
        })
        a.append(Language.make("thrift", "Thrift") { l in
            cComments(l)
            l.lineComment = ["//", "#"]
            l.extensions = ["thrift"]
            l.strings = [dq, sq]
            l.capitalizedTypes = true
            l.keywords = w("include cpp_include namespace throws extends oneway required optional")
            l.storage = w("struct union exception enum service typedef const senum")
            l.types = w("bool byte i8 i16 i32 i64 double string binary list set map void uuid")
            l.constants = w("true false")
            l.typeDefKeywords = w("struct union exception enum service typedef")
            l.symbolPattern = #"^\s*(?:struct|union|exception|enum|service|typedef\s+\S+)\s+([A-Za-z_]\w*)"#
        })
        a.append(Language.make("capnp", "Cap'n Proto") { l in
            l.lineComment = ["#"]
            l.extensions = ["capnp"]
            l.aliases = ["capnproto"]
            l.strings = [dq]
            l.annotationPrefix = "$"
            l.capitalizedTypes = true
            l.keywords = w("using import embed extends")
            l.storage = w("struct union enum interface group const annotation")
            l.types = w("Void Bool Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64 Float32 Float64 Text Data List AnyPointer Capability")
            l.constants = w("true false void inf nan")
            l.typeDefKeywords = w("struct union enum interface group")
            l.symbolPattern = #"^\s*(?:struct|enum|interface|union|group|const|annotation)\s+([A-Za-z_]\w*)"#
        })
        a.append(Language.make("graphql", "GraphQL") { l in
            l.lineComment = ["#"]
            l.extensions = w("graphql gql graphqls")
            l.aliases = ["gql"]
            l.strings = [StringRule("\"\"\"", multiline: true), dq]
            l.variablePrefixes = "$"
            l.annotationPrefix = "@"
            l.capitalizedTypes = true
            l.keywords = w("on implements repeatable extend")
            l.storage = w("type interface enum input union scalar schema fragment directive query mutation subscription")
            l.types = w("Int Float String Boolean ID")
            l.constants = w("true false null")
            l.functionDefKeywords = w("query mutation subscription fragment")
            l.typeDefKeywords = w("type interface enum input union scalar")
            l.symbolPattern = #"^\s*(?:extend\s+)?(?:type|interface|enum|input|union|scalar|fragment|query|mutation|subscription|directive\s+@)\s*([A-Za-z_]\w*)"#
        })
        a.append(Language.make("sql", "SQL") { l in
            l.lineComment = ["--"]
            l.blockComment = [("/*", "*/")]
            l.extensions = w("sql ddl dml pgsql psql plsql mysql tsql prql hql cql")
            l.aliases = w("postgres postgresql mysql sqlite tsql plsql mssql")
            l.strings = [StringRule("'", escape: false, multiline: true), StringRule("\"", escape: false), StringRule("`", escape: false, kind: .variable)]
            l.caseInsensitive = true
            l.variablePrefixes = "@"
            l.keywords = w("select from where and or not in is null like ilike between exists as on join inner left right full outer cross natural using group by order having limit offset fetch first next rows only union all intersect except distinct case when then else end insert into values update set delete returning with recursive if begin commit rollback transaction savepoint declare loop while for return returns language execute exec grant revoke asc desc nulls over partition window lateral merge matched do nothing conflict cascade restrict")
            l.storage = w("create alter drop table view index unique primary foreign key references constraint check default database schema function procedure trigger sequence materialized temporary temp or replace truncate rename column add type extension role user owner policy")
            l.types = w("int integer smallint bigint tinyint serial bigserial decimal numeric real float double precision money char varchar nchar nvarchar text clob blob bytea boolean bool date time timestamp timestamptz interval uuid json jsonb xml array enum bit varbinary binary")
            l.constants = w("true false null current_date current_time current_timestamp current_user localtime localtimestamp")
            l.builtins = w("count sum avg min max coalesce nullif greatest least cast convert concat length lower upper trim ltrim rtrim substring replace position round floor ceil abs now extract date_trunc to_char to_date row_number rank dense_rank lag lead first_value last_value string_agg array_agg json_agg jsonb_build_object generate_series")
            l.symbolPattern = #"(?i)create\s+(?:or\s+replace\s+)?(?:temp(?:orary)?\s+)?(?:unique\s+)?(?:materialized\s+)?(?:table|view|function|procedure|index|trigger|sequence|type|schema)\s+(?:if\s+not\s+exists\s+)?([\w."]+)"#
        })
        a.append(Language.make("prisma", "Prisma") { l in
            l.lineComment = ["//"]
            l.extensions = ["prisma"]
            l.strings = [dq]
            l.annotationPrefix = "@"
            l.capitalizedTypes = true
            l.storage = w("model enum type datasource generator view")
            l.types = w("String Boolean Int BigInt Float Decimal DateTime Json Bytes Unsupported")
            l.constants = w("true false null")
            l.builtins = w("env autoincrement now uuid cuid dbgenerated")
            l.typeDefKeywords = w("model enum type datasource generator view")
            l.symbolPattern = #"^\s*(?:model|enum|type|datasource|generator|view)\s+([A-Za-z_]\w*)"#
        })
        a.append(Language.make("xcode-project", "Xcode Project") { l in
            cComments(l)
            l.extensions = w("pbxproj")
            l.aliases = ["pbxproj"]
            l.strings = [dq]
            l.propertyKeys = .equals
            l.functionCalls = false
        })
        a.append(Language.make("apple-strings", "Strings") { l in
            cComments(l)
            l.extensions = ["strings"]
            l.aliases = ["localizable"]
            l.strings = [dq]
            l.functionCalls = false
            l.symbolPattern = #"^\s*"((?:[^"\\]|\\.)*)"\s*="#
        })
    }

    // MARK: - Configuration files

    private static func iniBase(_ l: Language) {
        l.lineComment = [";", "#"]
        l.strings = [dq]
        l.propertyKeys = .equals
        l.sectionHeaders = true
        l.identifierPartChars = "-."
        l.functionCalls = false
        l.operatorChars = "=:"
        l.constants = w("true false yes no on off null none")
        l.symbolPattern = #"^\s*\[+([^\]]+)\]"#
    }

    private static func config(_ a: inout [Language]) {
        a.append(Language.make("ini", "INI") { l in
            iniBase(l)
            l.extensions = w("ini cfg conf cnf desktop properties prefs reg inf url service socket timer mount automount path slice network netdev link")
            l.filenames = w(".npmrc .pypirc .pylintrc .flake8 .coveragerc .wgetrc .curlrc .hgrc hgrc .isort.cfg .pydistutils.cfg .gitlint .bumpversion.cfg .tern-project")
            l.aliases = w("dosini properties cfg conf systemd desktop")
        })
        a.append(Language.make("dotenv", "Dotenv") { l in
            l.lineComment = ["#"]
            l.extensions = ["env"]
            l.filenames = [".env"]
            l.filenamePrefixes = [".env."]
            l.aliases = ["env"]
            l.strings = [StringRule("\"", multiline: true, variables: true), StringRule("'", escape: false, multiline: true)]
            l.commentsNeedSpace = true
            l.keywordsAtLineStart = true
            l.propertyKeys = .equals
            l.variablePrefixes = "$"
            l.functionCalls = false
            l.operatorChars = "="
            l.keywords = ["export"]
            l.constants = w("true false")
        })
        a.append(Language.make("editorconfig", "EditorConfig") { l in
            iniBase(l)
            l.filenames = [".editorconfig"]
            l.constants = w("true false unset lf crlf cr space tab utf-8 utf-8-bom utf-16be utf-16le latin1")
        })
        a.append(Language.make("gitconfig", "Git Config") { l in
            iniBase(l)
            l.extensions = ["gitconfig"]
            l.filenames = w(".gitconfig .gitmodules .git-credentials")
            l.aliases = w("git-config gitmodules")
        })
        a.append(Language.make("gitignore", "Ignore File") { l in
            l.lineComment = ["#"]
            l.extensions = w("gitignore dockerignore npmignore")
            l.filenames = w(".gitignore .dockerignore .npmignore .eslintignore .prettierignore .stylelintignore .hgignore .gcloudignore .vscodeignore .slugignore .bzrignore .ignore .rgignore .fdignore .cfignore .helmignore .vercelignore")
            l.aliases = w("ignore git-ignore")
            l.functionCalls = false
            l.operatorChars = "!*?/"
            l.autoPairs = "[]"
        })
        a.append(Language.make("gitattributes", "Git Attributes") { l in
            l.lineComment = ["#"]
            l.extensions = ["gitattributes"]
            l.filenames = w(".gitattributes .lfsconfig-attributes")
            l.aliases = ["git-attributes"]
            l.identifierPartChars = "-"
            l.functionCalls = false
            l.operatorChars = "-!=*"
            l.builtins = w("text binary eol diff merge filter export-ignore export-subst linguist-vendored linguist-generated linguist-documentation linguist-language linguist-detectable whitespace working-tree-encoding lockable ident")
            l.constants = w("auto lf crlf lfs set unset")
        })
        a.append(Language.make("hcl", "HCL") { l in
            l.lineComment = ["#", "//"]
            l.blockComment = [("/*", "*/")]
            l.extensions = w("tf tfvars hcl nomad tftest.hcl")
            l.aliases = w("terraform tf opentofu")
            l.strings = [dq]
            l.propertyKeys = .equals
            l.identifierPartChars = "-"
            l.keywords = w("for in if else endif endfor")
            l.storage = w("resource variable output module data provider locals terraform backend required_providers moved import check dynamic lifecycle provisioner connection")
            l.types = w("string number bool list map set object tuple any")
            l.constants = w("true false null")
            l.builtins = w("var local module data each count path self abs ceil floor max min concat contains distinct element flatten keys length lookup merge range reverse slice sort values zipmap format formatlist join split lower upper replace substr trim trimspace jsonencode jsondecode yamlencode yamldecode base64encode base64decode file templatefile fileexists cidrsubnet tostring tonumber tolist tomap toset try can coalesce")
            l.symbolPattern = #"^\s*(?:resource|data|module|variable|output|provider)\s+(?:"[\w-]+"\s+)?"([^"]+)""#
        })
        a.append(Language.make("nix", "Nix") { l in
            l.lineComment = ["#"]
            l.blockComment = [("/*", "*/")]
            l.extensions = ["nix"]
            l.strings = [StringRule("''", escape: false, multiline: true), dqMulti]
            l.propertyKeys = .equals
            l.identifierPartChars = "-'"
            l.keywords = w("let in with rec inherit if then else assert or")
            l.constants = w("true false null")
            l.builtins = w("builtins import map toString derivation fetchurl fetchTarball fetchGit throw abort baseNameOf dirOf isNull removeAttrs pkgs lib stdenv mkDerivation callPackage")
            l.symbolPattern = #"^ {0,2}([A-Za-z_][\w'.-]*)\s*="#
        })
        a.append(Language.make("nginx", "Nginx") { l in
            l.lineComment = ["#"]
            l.extensions = ["nginx"]
            l.filenames = w("nginx.conf mime.types fastcgi_params uwsgi_params scgi_params")
            l.aliases = ["nginxconf"]
            l.strings = [dq, sq]
            l.variablePrefixes = "$"
            l.identifierPartChars = "-"
            l.functionCalls = false
            l.keywords = w("if return rewrite break set include try_files deny allow")
            l.storage = w("http server location upstream events stream map geo types mail limit_except")
            l.builtins = w("listen server_name root index proxy_pass proxy_set_header proxy_http_version proxy_redirect fastcgi_pass fastcgi_param ssl_certificate ssl_certificate_key ssl_protocols access_log error_log worker_processes worker_connections gzip gzip_types client_max_body_size keepalive_timeout sendfile add_header expires alias default_type charset")
            l.constants = w("on off default_server http2 ssl")
            l.symbolPattern = #"^\s*(?:server_name|location|upstream)\s+([^;{]+?)\s*[;{]"#
        })
        a.append(Language.make("apache", "Apache Config") { l in
            l.lineComment = ["#"]
            l.extensions = w("apacheconf htaccess vhost")
            l.filenames = w(".htaccess .htpasswd httpd.conf apache2.conf apache.conf")
            l.aliases = w("apacheconf htaccess")
            l.strings = [dq]
            l.variablePrefixes = "%$"
            l.caseInsensitive = true
            l.functionCalls = false
            l.operatorChars = "<>/!"
            l.keywords = w("VirtualHost Directory DirectoryMatch Files FilesMatch Location LocationMatch IfModule IfDefine IfVersion If ElseIf Else Proxy Limit LimitExcept RequireAll RequireAny")
            l.builtins = w("ServerName ServerAlias ServerAdmin DocumentRoot Listen LoadModule Include IncludeOptional Options AllowOverride Require Order Allow Deny RewriteEngine RewriteRule RewriteCond RewriteBase Redirect RedirectMatch Alias ErrorLog CustomLog LogLevel Header SetEnv SetEnvIf DirectoryIndex ErrorDocument AddType AddHandler ProxyPass ProxyPassReverse SSLEngine SSLCertificateFile SSLCertificateKeyFile ExpiresActive ExpiresByType")
            l.constants = w("on off all none granted denied")
        })
        a.append(Language.make("caddyfile", "Caddyfile") { l in
            l.lineComment = ["#"]
            l.extensions = ["caddy"]
            l.filenames = ["Caddyfile"]
            l.aliases = ["caddy"]
            l.strings = [dq, StringRule("`", escape: false, multiline: true)]
            l.annotationPrefix = "@"
            l.identifierPartChars = "-"
            l.functionCalls = false
            l.builtins = w("reverse_proxy file_server root encode gzip zstd tls header redir rewrite route handle handle_path handle_errors respond log import php_fastcgi basicauth basic_auth try_files uri templates bind abort error metrics request_body")
            l.symbolPattern = #"^([^\s#{][^{]*?)\s*\{"#
        })
    }

    // MARK: - Build tools

    private static func buildTools(_ a: inout [Language]) {
        a.append(Language.make("makefile", "Makefile") { l in
            l.lineComment = ["#"]
            l.extensions = w("mk mak make")
            l.filenames = w("Makefile GNUmakefile BSDmakefile Kbuild")
            l.filenamePrefixes = ["Makefile."]
            l.aliases = w("make mk bsdmake")
            l.shebangs = ["make"]
            l.strings = [StringRule("\"", variables: true), StringRule("'", variables: true)]
            l.variablePrefixes = "$"
            l.parenVariables = true
            l.identifierPartChars = "-"
            l.keywords = w("ifeq ifneq ifdef ifndef else endif include -include sinclude define endef export unexport override vpath private undefine")
            l.builtins = w("subst patsubst strip findstring filter filter-out sort word words wordlist firstword lastword dir notdir suffix basename addsuffix addprefix join wildcard realpath abspath if or and foreach call value eval origin flavor shell error warning info file let intcmp")
            l.symbolPattern = #"^([A-Za-z0-9_.\-/%$(){}]+)\s*:(?!=)"#
        })
        a.append(Language.make("cmake", "CMake") { l in
            l.lineComment = ["#"]
            l.blockComment = [("#[[", "]]")]
            l.extensions = w("cmake cmake.in")
            l.filenames = ["CMakeLists.txt"]
            l.strings = [dqMulti, StringRule("[[", "]]", escape: false, multiline: true)]
            l.variablePrefixes = "$"
            l.caseInsensitive = true
            l.keywords = w("if elseif else endif foreach endforeach while endwhile function endfunction macro endmacro return break continue block endblock AND OR NOT STREQUAL STRLESS STRGREATER EQUAL LESS GREATER VERSION_LESS VERSION_GREATER VERSION_EQUAL MATCHES DEFINED EXISTS IN_LIST IS_DIRECTORY TARGET COMMAND")
            l.builtins = w("cmake_minimum_required project add_executable add_library add_subdirectory add_custom_target add_custom_command add_definitions add_compile_options add_dependencies add_test target_link_libraries target_include_directories target_compile_definitions target_compile_options target_compile_features target_sources set_target_properties set_property get_property include_directories link_directories find_package find_library find_path find_program include install set unset list string file message option configure_file execute_process enable_testing include_guard FetchContent_Declare FetchContent_MakeAvailable")
            l.constants = w("ON OFF TRUE FALSE YES NO PUBLIC PRIVATE INTERFACE REQUIRED STATIC SHARED MODULE CACHE PARENT_SCOPE FORCE STATUS WARNING FATAL_ERROR SEND_ERROR")
            l.functionDefKeywords = w("function macro")
            l.symbolPattern = #"(?i)^\s*(?:function|macro)\s*\(\s*([\w-]+)"#
        })
        a.append(Language.make("meson", "Meson") { l in
            l.lineComment = ["#"]
            l.filenames = w("meson.build meson_options.txt meson.options")
            l.strings = [StringRule("'''", multiline: true), sq]
            l.stringPrefixes = "f"
            l.keywords = w("if elif else endif foreach endforeach break continue and or not in")
            l.constants = w("true false meson host_machine build_machine target_machine")
            l.builtins = w("project executable library shared_library static_library both_libraries dependency declare_dependency find_program subdir include_directories files configure_file custom_target run_target test benchmark install_headers install_data install_subdir message warning error get_option import join_paths summary")
        })
        a.append(Language.make("ninja", "Ninja") { l in
            l.lineComment = ["#"]
            l.extensions = ["ninja"]
            l.variablePrefixes = "$"
            l.propertyKeys = .equals
            l.functionCalls = false
            l.keywords = w("build rule pool default include subninja phony")
            l.builtins = w("command description depfile deps msvc_deps_prefix generator restat rspfile rspfile_content depth")
            l.symbolPattern = #"^(?:rule|pool)\s+(\S+)"#
        })
        a.append(Language.make("dockerfile", "Dockerfile") { l in
            l.lineComment = ["#"]
            l.extensions = w("dockerfile containerfile")
            l.filenames = w("Dockerfile Containerfile")
            l.filenamePrefixes = w("Dockerfile. Containerfile.")
            l.aliases = w("docker containerfile")
            l.strings = [StringRule("\"", variables: true), sq]
            l.commentsNeedSpace = true
            l.variablePrefixes = "$"
            l.caseInsensitive = true
            l.functionCalls = false
            l.keywordsAtLineStart = true
            l.keywords = w("FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL")
            l.storage = ["AS"]
            l.symbolPattern = #"(?i)^\s*FROM\s+\S+(?:\s+AS\s+(\S+))?"#
        })
        a.append(Language.make("just", "Justfile") { l in
            l.lineComment = ["#"]
            l.extensions = ["just"]
            l.filenames = w("Justfile .justfile")
            l.aliases = ["justfile"]
            l.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", escape: false, multiline: true), dq, sqRaw, StringRule("`", escape: false)]
            l.identifierPartChars = "-"
            l.keywords = w("if else alias set export import mod")
            l.constants = w("true false")
            l.builtins = w("env env_var env_var_or_default arch os os_family invocation_directory justfile_directory just_executable join absolute_path quote replace trim uppercase lowercase sha256 uuid")
            l.symbolPattern = #"^@?([A-Za-z_][\w-]*)[^:=\n]*:(?!=)"#
        })
    }

    // MARK: - Hardware and GPU languages

    private static let shaderKeywords = "if else for while do switch case default break continue return discard"
    private static let shaderTypes = "void bool int uint float double half bvec2 bvec3 bvec4 ivec2 ivec3 ivec4 uvec2 uvec3 uvec4 vec2 vec3 vec4 dvec2 dvec3 dvec4 mat2 mat3 mat4 mat2x2 mat2x3 mat2x4 mat3x2 mat3x3 mat3x4 mat4x2 mat4x3 mat4x4 sampler1D sampler2D sampler3D samplerCube sampler2DArray sampler2DShadow image2D float2 float3 float4 half2 half3 half4 int2 int3 int4 uint2 uint3 uint4 bool2 bool3 bool4 float2x2 float3x3 float4x4 half3x3 half4x4"
    private static let shaderBuiltins = "radians degrees sin cos tan asin acos atan pow exp log exp2 log2 sqrt inversesqrt rsqrt abs sign floor ceil fract frac mod fmod min max clamp saturate mix lerp step smoothstep length distance dot cross normalize reflect refract faceforward transpose inverse determinant texture texture2D textureLod texelFetch dFdx dFdy ddx ddy fwidth mul tex2D any all"

    private static func shaderBase(_ l: Language) {
        cBase(l)
        l.storage = w(cStorage + " in out inout uniform attribute varying layout centroid flat smooth noperspective patch sample buffer shared coherent readonly writeonly precision highp mediump lowp invariant subroutine groupshared cbuffer tbuffer register packoffset static nointerpolation linear")
        l.types = w(cTypes + " " + shaderTypes)
        l.keywords = w(cKeywords + " discard")
        l.builtins = w(shaderBuiltins)
        l.constants = w("true false gl_Position gl_FragCoord gl_FragColor gl_FragDepth gl_VertexID gl_InstanceID gl_GlobalInvocationID gl_LocalInvocationID gl_WorkGroupID gl_PointSize")
    }

    private static func hardware(_ a: inout [Language]) {
        a.append(Language.make("glsl", "GLSL") { l in
            shaderBase(l)
            l.extensions = w("glsl vert frag geom comp tesc tese mesh task rgen rchit rmiss rahit rint rcall fsh")
            l.aliases = w("opengl shader")
        })
        a.append(Language.make("hlsl", "HLSL") { l in
            shaderBase(l)
            l.extensions = w("hlsl hlsli fx fxh")
            l.types = w(cTypes + " " + shaderTypes + " Texture1D Texture2D Texture3D TextureCube Texture2DArray RWTexture2D SamplerState SamplerComparisonState Buffer RWBuffer StructuredBuffer RWStructuredBuffer ByteAddressBuffer RWByteAddressBuffer ConstantBuffer")
        })
        a.append(Language.make("metal", "Metal") { l in
            shaderBase(l)
            l.extensions = ["metal"]
            l.aliases = ["msl"]
            l.keywords = w(cKeywords + " " + cppKeywords + " discard_fragment")
            l.storage = w(cStorage + " " + cppStorage + " kernel vertex fragment device constant threadgroup thread threadgroup_imageblock ray_data object_data visible stitchable")
            l.types = w(cTypes + " " + shaderTypes + " texture1d texture2d texture3d texturecube texture2d_array depth2d sampler packed_float2 packed_float3 packed_float4 float2x2 float3x3 float4x4 atomic_int atomic_uint simd_float4")
            l.builtins = w(shaderBuiltins + " metal simd sample read write get_width get_height threadgroup_barrier mem_flags")
            l.constants = w("true false nullptr position thread_position_in_grid thread_position_in_threadgroup threadgroup_position_in_grid vertex_id instance_id stage_in buffer texture")
        })
        a.append(Language.make("cuda", "CUDA") { l in
            cBase(l)
            l.extensions = w("cu cuh")
            l.keywords = w(cKeywords + " " + cppKeywords)
            l.storage = w(cStorage + " " + cppStorage + " __global__ __device__ __host__ __shared__ __constant__ __managed__ __restrict__ __forceinline__ __noinline__ __launch_bounds__")
            l.types = w(cTypes + " " + cppTypes + " dim3 int2 int3 int4 uint2 uint3 uint4 float2 float3 float4 double2 double3 double4 cudaError_t cudaStream_t cudaEvent_t half __half")
            l.constants = w(cConstants + " this threadIdx blockIdx blockDim gridDim warpSize cudaSuccess")
            l.builtins = w(cBuiltins + " " + cppBuiltins + " __syncthreads __syncwarp atomicAdd atomicSub atomicExch atomicMin atomicMax atomicCAS cudaMalloc cudaFree cudaMemcpy cudaMemset cudaDeviceSynchronize cudaGetLastError cudaGetErrorString __shfl_sync")
            l.typeDefKeywords = w("class struct union enum namespace")
        })
        a.append(Language.make("wgsl", "WGSL") { l in
            cComments(l)
            l.nestedComments = true
            l.extensions = ["wgsl"]
            l.annotationPrefix = "@"
            l.capitalizedTypes = true
            l.keywords = w("if else for while loop switch case default break continue continuing return discard fallthrough enable requires diagnostic")
            l.storage = w("fn let var const override struct alias function private workgroup uniform storage read write read_write")
            l.types = w("bool i32 u32 f32 f16 vec2 vec3 vec4 vec2f vec3f vec4f vec2i vec3i vec4i vec2u vec3u vec4u vec2h vec3h vec4h mat2x2 mat3x3 mat4x4 mat2x2f mat3x3f mat4x4f array atomic ptr sampler sampler_comparison texture_1d texture_2d texture_2d_array texture_3d texture_cube texture_depth_2d texture_storage_2d texture_external")
            l.constants = w("true false")
            l.builtins = w("abs acos asin atan atan2 ceil clamp cos cross degrees distance dot exp exp2 floor fract length log log2 max min mix normalize pow radians reflect round select sign sin smoothstep sqrt step tan transpose textureSample textureLoad textureStore textureDimensions arrayLength atomicAdd atomicLoad atomicStore workgroupBarrier storageBarrier bitcast")
            l.functionDefKeywords = ["fn"]
            l.typeDefKeywords = w("struct alias")
            l.symbolPattern = #"^\s*(?:fn|struct|alias)\s+([A-Za-z_]\w*)"#
        })
        a.append(Language.make("verilog", "Verilog") { l in
            cComments(l)
            l.extensions = w("sv svh vh verilog vlg vams")
            l.aliases = w("systemverilog sv")
            l.strings = [dq]
            l.variablePrefixes = "$`"
            l.keywords = w("if else case casex casez endcase default for while repeat forever begin end fork join join_any join_none disable wait return break continue assert assume cover posedge negedge or and not iff inside with foreach unique priority")
            l.storage = w("module endmodule macromodule input output inout wire reg logic bit byte int integer real time realtime parameter localparam genvar generate endgenerate assign always always_comb always_ff always_latch initial final function endfunction task endtask signed unsigned supply0 supply1 tri wand wor interface endinterface package endpackage import export class endclass extends virtual typedef struct union enum packed modport program endprogram automatic static const rand randc constraint covergroup endgroup")
            l.types = w("wire reg logic bit byte shortint int longint integer real shortreal string chandle event")
            l.functionDefKeywords = w("function task")
            l.typeDefKeywords = w("module interface package class program")
            l.symbolPattern = #"^\s*(?:module|interface|package|class|program|function(?:\s+automatic)?(?:\s+\w+)?|task(?:\s+automatic)?)\s+([A-Za-z_]\w*)"#
        })
        a.append(Language.make("vhdl", "VHDL") { l in
            l.lineComment = ["--"]
            l.blockComment = [("/*", "*/")]
            l.extensions = w("vhd vhdl vho vht")
            l.strings = [dq, charLit]
            l.caseInsensitive = true
            l.keywords = w("if then else elsif end case when others for while loop next exit return wait until after report severity assert null and or nand nor xor xnor not mod rem abs sll srl sla sra rol ror is of in out inout buffer to downto begin generate map port use library all with select")
            l.storage = w("entity architecture component configuration package body process procedure function signal variable constant type subtype record array range attribute alias file impure pure shared generic block")
            l.types = w("bit bit_vector boolean integer natural positive real time character string std_logic std_logic_vector std_ulogic std_ulogic_vector signed unsigned line")
            l.constants = w("true false ieee work std")
            l.builtins = w("rising_edge falling_edge to_integer to_unsigned to_signed resize std_logic_vector conv_integer now")
            l.functionDefKeywords = w("function procedure")
            l.typeDefKeywords = w("entity architecture component package type subtype")
            l.symbolPattern = #"(?i)^\s*(?:entity|architecture|component|package(?:\s+body)?|function|procedure)\s+(\w+)"#
        })
        a.append(Language.make("assembly", "Assembly") { l in
            l.lineComment = [";", "//", "#"]
            l.blockComment = [("/*", "*/")]
            l.extensions = w("asm s nasm masm a51 inc86")
            l.aliases = w("asm nasm gas x86asm armasm")
            l.strings = [dq, charLit]
            l.identifierChars = "."
            l.variablePrefixes = "%"
            l.caseInsensitive = true
            l.functionCalls = false
            l.keywords = w("mov movl movq movb movw movzx movsx movabs lea push pop call ret jmp je jne jz jnz jg jge jl jle ja jae jb jbe jc jnc js jns jo cmp test add sub mul imul div idiv inc dec neg and or xor not shl shr sal sar rol ror nop int syscall sysenter hlt cli sti loop rep cmov ldr str ldp stp ldrb strb adr adrp b bl blr br bx cbz cbnz beq bne bgt blt bge ble svc orr eor lsl lsr asr madd msub")
            l.storage = w(".text .data .bss .rodata .section .globl .global .extern .align .balign .p2align .byte .word .short .long .quad .int .ascii .asciz .string .zero .space .equ .set .macro .endm .type .size .file .loc .cfi_startproc .cfi_endproc section segment global extern db dw dd dq resb resw resd resq equ times org bits")
            l.builtins = w("rax rbx rcx rdx rsi rdi rbp rsp r8 r9 r10 r11 r12 r13 r14 r15 eax ebx ecx edx esi edi ebp esp ax bx cx dx si di bp sp al ah bl bh cl ch dl dh rip eip cs ds es fs gs ss xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7 x0 x1 x2 x3 x4 x5 x6 x7 x8 x16 x29 x30 w0 w1 w2 w3 lr pc fp xzr wzr")
            l.symbolPattern = #"^([A-Za-z_.$][\w.$]*):"#
        })
    }

    // MARK: - Legacy and miscellaneous languages

    private static func misc(_ a: inout [Language]) {
        a.append(Language.make("fortran", "Fortran") { l in
            l.lineComment = ["!"]
            l.extensions = w("f f90 f95 f03 f08 for ftn f77 fpp")
            l.strings = [StringRule("\"", escape: false), sqRaw]
            l.caseInsensitive = true
            l.keywords = w("if then else elseif endif end do enddo while select case default exit cycle return stop goto call continue where elsewhere forall use only implicit none contains result intent in out inout and or not eqv neqv eq ne lt le gt ge allocate deallocate print write read open close format associate block")
            l.storage = w("program module submodule subroutine function interface type class parameter dimension allocatable pointer target public private protected save external intrinsic optional pure elemental recursive abstract extends procedure common data")
            l.types = w("integer real double precision complex logical character")
            l.constants = w(".true. .false. true false")
            l.builtins = w("abs sqrt sin cos tan exp log mod max min size shape sum product maxval minval allocated present len trim adjustl huge tiny epsilon kind real int nint floor ceiling matmul transpose dot_product")
            l.identifierChars = "."
            l.functionDefKeywords = w("function subroutine program")
            l.typeDefKeywords = w("module type")
            l.symbolPattern = #"(?i)^\s*(?:(?:pure|elemental|recursive|module)\s+)*(?:program|module|subroutine|function|(?:\w+(?:\([^)]*\))?\s+)?function)\s+(\w+)"#
        })
        a.append(Language.make("pascal", "Pascal") { l in
            l.lineComment = ["//"]
            l.blockComment = [("{", "}"), ("(*", "*)")]
            l.extensions = w("pas pp dpr lpr dpk lpk dfm lfm")
            l.aliases = w("delphi objectpascal freepascal fpc")
            l.strings = [sqRaw]
            l.caseInsensitive = true
            l.indentAfter = "(["
            l.dedentChars = ")]"
            l.keywords = w("if then else case of for to downto do while repeat until with begin end try except finally raise exit break continue goto and or not xor div mod shl shr in is as uses unit program library interface implementation initialization finalization inherited")
            l.storage = w("var const type procedure function constructor destructor property class record object packed array set file string interface public private protected published strict override virtual abstract overload reintroduce static inline forward external out label")
            l.types = w("integer cardinal shortint smallint longint int64 byte word longword boolean char widechar ansichar real single double extended currency string ansistring widestring unicodestring pointer variant tobject")
            l.constants = w("true false nil self result")
            l.builtins = w("writeln write readln read length setlength inc dec ord chr high low assigned freeandnil inttostr strtoint format copy pos delete insert trim uppercase lowercase sizeof new dispose halt")
            l.functionDefKeywords = w("procedure function constructor destructor")
            l.symbolPattern = #"(?i)^\s*(?:class\s+)?(?:procedure|function|constructor|destructor)\s+([\w.]+)"#
        })
        a.append(Language.make("ada", "Ada") { l in
            l.lineComment = ["--"]
            l.extensions = w("adb ads ada")
            l.strings = [StringRule("\"", escape: false), charLit]
            l.caseInsensitive = true
            l.keywords = w("if then else elsif end case when others for while loop exit return goto raise exception begin declare is in out and or xor not mod rem abs with use select accept delay abort terminate requeue reverse do of range")
            l.storage = w("procedure function package body type subtype record array access constant aliased private limited tagged abstract new null renames generic separate task protected entry overriding interface synchronized all")
            l.types = w("integer natural positive float long_float boolean character string wide_string duration")
            l.constants = w("true false null")
            l.builtins = w("put put_line get get_line new_line ada text_io")
            l.functionDefKeywords = w("procedure function")
            l.typeDefKeywords = w("package type subtype task")
            l.symbolPattern = #"(?i)^\s*(?:procedure|function|package(?:\s+body)?|task(?:\s+body)?|protected(?:\s+body)?)\s+([\w.]+)"#
        })
        a.append(Language.make("cobol", "COBOL") { l in
            l.lineComment = ["*>"]
            l.extensions = w("cob cbl cpy cobol")
            l.strings = [StringRule("\"", escape: false), sqRaw]
            l.caseInsensitive = true
            l.identifierPartChars = "-"
            l.functionCalls = false
            l.keywords = w("if else end-if evaluate when end-evaluate perform end-perform until varying from by thru through goback stop run exit call using returning move to add subtract multiply divide compute giving display accept read write rewrite open close input output i-o extend initialize string unstring inspect search set go not and or is equal greater less than")
            l.storage = w("identification division program-id environment configuration input-output file-control data working-storage local-storage linkage section procedure fd select assign pic picture value occurs redefines copy replacing")
            l.constants = w("zero zeros zeroes space spaces high-value high-values low-value low-values quote quotes null true false")
            l.symbolPattern = #"(?i)^\s{0,11}([A-Z0-9][\w-]*)\s+(?:section|division)?\.\s*$"#
        })
        a.append(Language.make("prolog", "Prolog") { l in
            l.lineComment = ["%"]
            l.blockComment = [("/*", "*/")]
            l.extensions = ["prolog"]
            l.shebangs = w("swipl gprolog")
            l.strings = [dq, StringRule("'", kind: .constant), StringRule("`")]
            l.autoPairs = "()[]{}\"\""
            l.keywords = w("is mod rem div xor rdiv not")
            l.storage = w("module use_module dynamic discontiguous initialization multifile ensure_loaded")
            l.constants = w("true false fail")
            l.builtins = w("write writeln print nl format assert asserta assertz retract findall bagof setof length append member atom number var nonvar call functor arg copy_term atom_codes atom_chars number_codes sort msort between succ plus halt")
            l.symbolPattern = #"^([a-z]\w*)\s*(?:\(|:-)"#
        })
    }
}
