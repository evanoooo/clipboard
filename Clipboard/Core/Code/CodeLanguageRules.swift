//
//  CodeLanguageRules.swift
//  Clipboard
//
//  各语言的词法规则：注释、字符串定界与关键字表
//

import Foundation

/// 词法扫描规则。
///
/// 关键字表不必完备：扫描到未知标识符时回落为普通文本，
/// 因此收录高频关键字即可获得接近编辑器的观感。
nonisolated struct CodeLanguageRules: Sendable {
    /// 行注释前缀；为空表示语言没有行注释
    let lineComments: [String]
    /// 块注释（开、闭）
    let blockComments: [(open: String, close: String)]
    /// 字符串定界符；`escapes` 表示支持反斜杠转义
    let strings: [(open: String, close: String, escapes: Bool)]
    /// 按注释呈现的多行字符串（如 Python 文档字符串）
    let multiLineStrings: [(open: String, close: String)]
    let keywords: Set<String>
    /// 字面量（true/false/null…）
    let literals: Set<String>
    /// 关键字与字面量忽略大小写（SQL）
    let caseInsensitiveWords: Bool
    /// 标签名按关键字呈现（HTML/XML）
    let tagNamesAsKeywords: Bool
    /// `@` 前缀按关键字呈现（CSS at-rule、Java 注解）
    let atSignAsKeyword: Bool
    /// `#` 后接十六进制数字按数字呈现（CSS 颜色）
    let hexColorAsNumber: Bool
    /// 单字符字面量（Rust `'a'`），其余单引号视为标点以支持生命周期 `'a`
    let charLiterals: Bool
    /// 首字母大写的标识符按类型呈现
    let uppercaseMeansType: Bool

    func isKeyword(_ word: String) -> Bool {
        caseInsensitiveWords ? keywords.contains(word.lowercased()) : keywords.contains(word)
    }

    func isLiteral(_ word: String) -> Bool {
        caseInsensitiveWords ? literals.contains(word.lowercased()) : literals.contains(word)
    }

    // MARK: - 各语言规则

    static func rules(for language: CodeLanguage) -> CodeLanguageRules {
        switch language {
        case .java:
            cFamily(
                keywords: words("""
                abstract assert break case catch class continue default do else enum extends final
                finally for if implements import instanceof interface native new package permits
                private protected public record return sealed static strictfp super switch
                synchronized throw throws throws transient try var void volatile while yield
                """),
                literals: words("true false null")
            )
        case .javascript:
            cFamily(
                keywords: words("""
                as async await break case catch class const continue debugger default delete do
                else export extends finally for from function get if import in instanceof let new
                of return set static super switch this throw try typeof var void while with yield
                """),
                literals: words("true false null undefined NaN Infinity"),
                strings: [("\"", "\"", true), ("'", "'", true), ("`", "`", true)]
            )
        case .typescript:
            cFamily(
                keywords: words("""
                abstract as any asserts async await break case catch class const continue declare
                default delete do else enum export extends finally for from function get if
                implements import in infer instanceof interface is keyof let module namespace
                never new of private protected public readonly return satisfies set static super
                switch this throw try type typeof unique unknown var void while yield
                """),
                literals: words("true false null undefined NaN Infinity"),
                strings: [("\"", "\"", true), ("'", "'", true), ("`", "`", true)]
            )
        case .c:
            cFamily(
                keywords: words("""
                auto break case char const continue default do double else enum extern float for
                goto if inline int long register restrict return short signed sizeof static
                struct switch typedef union unsigned void volatile while
                """),
                literals: words("NULL")
            )
        case .cpp:
            cFamily(
                keywords: words("""
                alignas alignof and asm auto bool break case catch char class const consteval
                constexpr const_cast continue decltype default delete do double dynamic_cast
                else enum explicit export extern false final float for friend goto if inline int
                long mutable namespace new noexcept not nullptr operator or private protected
                public register reinterpret_cast requires return short signed sizeof static
                static_assert static_cast struct switch template this thread_local throw true
                try typedef typeid typename union unsigned using virtual void volatile while
                """),
                literals: words("true false nullptr NULL")
            )
        case .csharp:
            cFamily(
                keywords: words("""
                abstract as async await base bool break byte case catch char checked class const
                continue decimal default delegate do double else enum event explicit extern
                false finally fixed float for foreach get global goto if implicit in int
                interface internal is lock long namespace new null object operator out override
                params partial private protected public readonly ref return sbyte sealed set short
                sizeof stackalloc static string struct switch this throw true try typeof uint
                ulong unchecked unsafe ushort using var virtual void volatile where while with
                yield
                """),
                literals: words("true false null")
            )
        case .kotlin:
            cFamily(
                keywords: words("""
                abstract actual annotation as break by catch class companion const constructor
                continue crossinline data delegate do dynamic else enum expect external false
                final finally for fun get if import in infix init inline inner interface
                internal is lateinit noinline null object open operator out override package
                private protected public reified return sealed set super suspend tailrec this
                throw true try typealias val var vararg when where while
                """),
                literals: words("true false null")
            )
        case .swift:
            cFamily(
                keywords: words("""
                any as associatedtype async await break case catch class continue default defer
                deinit do else enum extension fallthrough false fileprivate final for func guard
                if import in indirect init inout internal is let nil open operator postfix
                precedencegroup prefix private protocol public repeat required rethrows return
                self some static struct subscript super switch throw throws true try typealias
                var weak where while
                """),
                literals: words("true false nil"),
                strings: [("\"", "\"", true)]
            )
        case .go:
            cFamily(
                keywords: words("""
                break case chan const continue default defer else fallthrough for func go goto if
                import interface map package range return select struct switch type var
                """),
                literals: words("true false nil iota"),
                strings: [("\"", "\"", true), ("`", "`", false), ("'", "'", true)]
            )
        case .rust:
            cFamily(
                keywords: words("""
                as async await break const continue crate dyn else enum extern false fn for if
                impl in let loop match mod move mut pub ref return self Self static struct super
                trait true type unsafe use where while
                """),
                literals: words("true false Some None Ok Err"),
                charLiterals: true
            )
        case .php:
            cFamily(
                keywords: words("""
                abstract and array as break callable case catch class clone const continue
                declare default do echo else elseif empty enddeclare endfor endforeach endif
                endswitch endwhile enum extends final finally fn for foreach function global goto
                if implements include include_once instanceof insteadof interface isset list
                match namespace new or print private protected public readonly require
                require_once return static switch throw trait try unset use var while xor yield
                """),
                literals: words("true false null")
            )
        case .python:
            CodeLanguageRules(
                lineComments: ["#"],
                blockComments: [],
                strings: [("\"", "\"", true), ("'", "'", true)],
                multiLineStrings: [("\"\"\"", "\"\"\""), ("'''", "'''")],
                keywords: words("""
                and as assert async await break class continue def del elif else except finally
                for from global if import in is lambda match nonlocal not or pass raise return
                try while with yield
                """),
                literals: words("True False None"),
                caseInsensitiveWords: false,
                tagNamesAsKeywords: false,
                atSignAsKeyword: false,
                hexColorAsNumber: false,
                charLiterals: false,
                uppercaseMeansType: true
            )
        case .ruby:
            CodeLanguageRules(
                lineComments: ["#"],
                blockComments: [("=begin", "=end")],
                strings: [("\"", "\"", true), ("'", "'", false)],
                multiLineStrings: [],
                keywords: words("""
                alias and begin break case class def defined do else elsif end ensure false for
                if in module next nil not or redo rescue retry return self super then true
                undef unless until when while yield
                """),
                literals: words("true false nil"),
                caseInsensitiveWords: false,
                tagNamesAsKeywords: false,
                atSignAsKeyword: true,
                hexColorAsNumber: false,
                charLiterals: false,
                uppercaseMeansType: true
            )
        case .bash:
            CodeLanguageRules(
                lineComments: ["#"],
                blockComments: [],
                strings: [("\"", "\"", true), ("'", "'", false)],
                multiLineStrings: [],
                keywords: words("""
                break case continue declare do done elif else esac eval exec exit export fi for
                function getopts if in local printf read readonly return select set shift source
                then time trap unset until while
                """),
                literals: words("true false"),
                caseInsensitiveWords: false,
                tagNamesAsKeywords: false,
                atSignAsKeyword: false,
                hexColorAsNumber: false,
                charLiterals: false,
                uppercaseMeansType: false
            )
        case .sql:
            CodeLanguageRules(
                lineComments: ["--"],
                blockComments: [("/*", "*/")],
                strings: [("'", "'", true), ("\"", "\"", false)],
                multiLineStrings: [],
                keywords: words("""
                add all alter and as asc auto_increment begin between by cascade case cast
                check collate column commit constraint create cross database default delete desc
                distinct drop else end escape except exists foreign from full group having if in
                index inner insert int integerinto is join key left like limit merge natural not
                null offset on or order outer primary references rename replace return right
                rollback row rows select set table temporary then to transaction trigger union
                unique update use values view when where with
                """),
                literals: words("true false null"),
                caseInsensitiveWords: true,
                tagNamesAsKeywords: false,
                atSignAsKeyword: false,
                hexColorAsNumber: false,
                charLiterals: false,
                uppercaseMeansType: false
            )
        case .json:
            CodeLanguageRules(
                lineComments: [],
                blockComments: [],
                strings: [("\"", "\"", true)],
                multiLineStrings: [],
                keywords: [],
                literals: words("true false null"),
                caseInsensitiveWords: false,
                tagNamesAsKeywords: false,
                atSignAsKeyword: false,
                hexColorAsNumber: false,
                charLiterals: false,
                uppercaseMeansType: false
            )
        case .yaml:
            CodeLanguageRules(
                lineComments: ["#"],
                blockComments: [],
                strings: [("\"", "\"", true), ("'", "'", false)],
                multiLineStrings: [],
                keywords: words("true false yes no on off null"),
                literals: [],
                caseInsensitiveWords: false,
                tagNamesAsKeywords: false,
                atSignAsKeyword: false,
                hexColorAsNumber: false,
                charLiterals: false,
                uppercaseMeansType: false
            )
        case .css:
            CodeLanguageRules(
                lineComments: [],
                blockComments: [("/*", "*/")],
                strings: [("\"", "\"", true), ("'", "'", true)],
                multiLineStrings: [],
                keywords: words("""
                important from to and not only or media keyframes supports font-face charset
                import namespace root layer container scope starting-style property
                """),
                literals: words("inherit initial unset revert none auto currentColor transparent"),
                caseInsensitiveWords: false,
                tagNamesAsKeywords: false,
                atSignAsKeyword: true,
                hexColorAsNumber: true,
                charLiterals: false,
                uppercaseMeansType: false
            )
        case .nginx:
            CodeLanguageRules(
                lineComments: ["#"],
                blockComments: [],
                strings: [("\"", "\"", true), ("'", "'", true)],
                multiLineStrings: [],
                keywords: words("""
                events http server location upstream types
                listen server_name root index proxy_pass proxy_set_header
                proxy_redirect proxy_buffering proxy_connect_timeout proxy_read_timeout
                fastcgi_pass fastcgi_param fastcgi_index fastcgi_buffers
                uwsgi_pass scgi_pass rewrite try_files return include
                access_log error_log sendfile tcp_nopush tcp_nodelay
                keepalive_timeout client_max_body_size client_body_buffer_size
                default_type gzip gzip_types gzip_min_length
                ssl_certificate ssl_certificate_key ssl_protocols ssl_ciphers
                ssl_prefer_server_ciphers ssl_session_cache ssl_session_timeout
                worker_processes worker_connections multi_accept
                add_header expires autoindex internal alias
                deny allow set if break
                """),
                literals: words("on off true false all"),
                caseInsensitiveWords: false,
                tagNamesAsKeywords: false,
                atSignAsKeyword: false,
                hexColorAsNumber: false,
                charLiterals: false,
                uppercaseMeansType: false
            )
        case .html:
            CodeLanguageRules(
                lineComments: [],
                blockComments: [("<!--", "-->")],
                strings: [("\"", "\"", false), ("'", "'", false)],
                multiLineStrings: [],
                keywords: [],
                literals: [],
                caseInsensitiveWords: false,
                tagNamesAsKeywords: true,
                atSignAsKeyword: false,
                hexColorAsNumber: false,
                charLiterals: false,
                uppercaseMeansType: false
            )
        }
    }

    // MARK: - 预设

    /// C 系语言括号注释与字符串形态基本一致，只替换关键字表
    private static func cFamily(
        keywords: Set<String>,
        literals: Set<String>,
        strings: [(open: String, close: String, escapes: Bool)]? = nil,
        charLiterals: Bool = false
    ) -> CodeLanguageRules {
        CodeLanguageRules(
            lineComments: ["//"],
            blockComments: [("/*", "*/")],
            strings: strings ?? [("\"", "\"", true), ("'", "'", true)],
            multiLineStrings: [],
            keywords: keywords,
            literals: literals,
            caseInsensitiveWords: false,
            tagNamesAsKeywords: false,
            atSignAsKeyword: true,
            hexColorAsNumber: false,
            charLiterals: charLiterals,
            uppercaseMeansType: true
        )
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(separator: " ").map(String.init))
    }
}
