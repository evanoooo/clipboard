//
//  CodeLanguageDetector.swift
//  Clipboard
//
//  基于加权信号的代码语言识别
//

import Foundation

/// 从纯文本判定代码语言。
///
/// 设计原则与 `MarkdownDetector.detect` 一致：命中强特征直接定语言，
/// 普通特征按权重累计，低于阈值视为噪声，避免把普通文字、URL、
/// 中英混排的便签误判成代码。
nonisolated enum CodeLanguageDetector {
    /// 一条判别信号；`caseSensitive` 用于必须区分大小写的场景（如 SQL 大写语句）
    private struct Signal: Sendable {
        let pattern: String
        let weight: Int
        var caseSensitive = false
    }

    /// 判定阈值
    private static let threshold = 3
    /// 只分析开头若干字符：导入、包名、shebang 等判别信号集中在片段头部
    private static let analysisLimit = 2_000
    /// 解码窗口：按 UTF-8 单标量最多 4 字节估算，避免为识别解码整段超长文本
    private static let sampleByteLimit = analysisLimit * 4

    /// 从 UTF-8 原文判定语言。
    /// 只解码开头部分，调用方可以放心传入整段内容。
    static func detect(_ data: Data) -> CodeLanguage? {
        detect(String(decoding: data.prefix(sampleByteLimit), as: UTF8.self))
    }

    /// 返回识别出的语言；无法确信时返回 nil（不高亮，保持纯文本）
    static func detect(_ text: String) -> CodeLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        let sample = String(trimmed.prefix(analysisLimit))

        var ranked: [(language: CodeLanguage, score: Int, hits: Int)] = []
        ranked.reserveCapacity(signals.count)
        for (language, languageSignals) in signals {
            var score = 0
            var hits = 0
            for signal in languageSignals where matches(signal, in: sample) {
                score += signal.weight
                hits += 1
            }
            if score > 0 {
                ranked.append((language, score, hits))
            }
        }

        guard let best = ranked.max(by: { lhs, rhs in
            lhs.score == rhs.score ? lhs.hits < rhs.hits : lhs.score < rhs.score
        }) else { return nil }

        guard best.score >= threshold else { return nil }
        // 与第二名完全同分则视为不确定，宁可展示纯文本
        let others = ranked.filter { $0.language != best.language }.map(\.score)
        guard let runnerUp = others.max() else { return best.language }
        return runnerUp >= best.score ? nil : best.language
    }

    // MARK: - Private

    private static func matches(_ signal: Signal, in text: String) -> Bool {
        let options: NSString.CompareOptions = signal.caseSensitive ? [.regularExpression] : [.regularExpression, .caseInsensitive]
        return text.range(of: signal.pattern, options: options) != nil
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static let signals: [CodeLanguage: [Signal]] = [
        .java: [
            .init(pattern: #"(?m)^\s*package\s+[\w.]+\s*;"#, weight: 5),
            .init(pattern: #"(?m)^\s*import\s+(?:java|javax|android)\."#, weight: 5),
            .init(pattern: #"(?m)^\s*(?:@\w+\s+)*(?:public|private|protected)\s+(?:static\s+|final\s+|abstract\s+)*class\s+\w+"#, weight: 4),
            .init(pattern: #"\b(?:public|private|protected)\s+static\s+(?:final\s+)?void\s+main\s*\("#, weight: 6),
            .init(pattern: #"\bSystem\.(?:out|err)\.(?:print|println|printf)\b"#, weight: 6),
            .init(pattern: #"(?m)^\s*@(?:Override|Deprecated|SuppressWarnings|FunctionalInterface)\b"#, weight: 3),
            .init(pattern: #"\bnew\s+[A-Z]\w*\s*\(|\bnew\s+[A-Z]\w*\s*\["#, weight: 2),
            .init(pattern: #"\b(?:String|Integer|Boolean|Double|Long)\s+\w+\s*=\s*[^=]"#, weight: 2)
        ],
        .javascript: [
            .init(pattern: #"(?m)^#![^\n]*\bnode(?:js)?\b"#, weight: 8),
            .init(pattern: #"\b(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*(?::[^=\n]+)?=\s*.+"#, weight: 2),
            .init(pattern: #"=>\s*[{(A-Za-z_$`]"#, weight: 3),
            .init(pattern: #"\bfunction\s*\w*\s*\([^)]*\)\s*\{"#, weight: 3),
            .init(pattern: #"\bconsole\.(?:log|error|warn|info|debug)\s*\("#, weight: 5),
            .init(pattern: #"\b(?:require\s*\(|module\.exports|exports\.\w+\s*=)"#, weight: 3),
            .init(pattern: ##"\bimport\s+[^;]+\bfrom\s+['\"]"##, weight: 3),
            .init(pattern: #"\bdocument\.(?:getElementById|querySelector|querySelectorAll|createElement)\s*\("#, weight: 4),
            .init(pattern: #"\bexport\s+(?:default|const|let|var|function|class)\b"#, weight: 3),
            .init(pattern: #"\b(?:new\s+Promise|\.then\s*\(|\.catch\s*\()"#, weight: 3),
            .init(pattern: #"\b(?:setTimeout|setInterval|addEventListener)\s*\("#, weight: 2),
            .init(pattern: #"\basync\s+function\b|\basync\s*\([^)]*\)\s*=>"#, weight: 2),
            .init(pattern: #"\bawait\s+\w+"#, weight: 2)
        ],
        .typescript: [
            .init(pattern: #"(?m)^\s*(?:export\s+)?interface\s+\w+"#, weight: 4),
            .init(pattern: #"\btype\s+\w+\s*=\s*[^{=]"#, weight: 4),
            .init(pattern: #"\b(?:readonly|public|private|protected)\s+\w+\s*[?!]?:"#, weight: 3),
            .init(pattern: #":\s*(?:string|number|boolean|void|any|unknown|never|object|symbol|bigint)\b"#, weight: 3),
            .init(pattern: #"\benum\s+\w+\s*\{"#, weight: 3),
            .init(pattern: #"\b(?:implements|namespace)\s+\w+"#, weight: 2),
            .init(pattern: #"\bas\s+(?:const|string|number|boolean|any)\b"#, weight: 2),
            .init(pattern: #"<[A-Z]\w*(?:\[\])?>\s*\("#, weight: 1)
        ],
        .python: [
            .init(pattern: #"(?m)^#![^\n]*\bpython[0-9.]*\b"#, weight: 8),
            .init(pattern: #"(?m)^\s*import\s+[A-Za-z_][A-Za-z0-9_.]*(?:\s+as\s+[A-Za-z_][A-Za-z0-9_]*)?(?:\s*,\s*[A-Za-z_][A-Za-z0-9_.]*)*\s*$"#, weight: 5),
            .init(pattern: #"(?m)^\s*(?:async\s+)?def\s+\w+\s*\([^)]*\)\s*(?:->[^:]+)?:"#, weight: 5),
            .init(pattern: #"(?m)^\s*from\s+[\w.]+\s+import\s+"#, weight: 5),
            .init(pattern: #"(?m)^\s*class\s+\w+\s*(?:\([\w.,\s]*\))?\s*:"#, weight: 4),
            .init(pattern: ##"(?m)^\s*if\s+__name__\s*==\s*['\"]"##, weight: 6),
            .init(pattern: #"(?m)^\s*@\w+(?:\.\w+)*\s*$"#, weight: 2),
            .init(pattern: #"\bself\.\w+"#, weight: 3),
            .init(pattern: #"\braise\s+\w+|raise\s+$"#, weight: 3),
            .init(pattern: #"\b(?:elif|except\s+\w*|finally)\s*:?"#, weight: 1)
        ],
        .swift: [
            .init(pattern: #"\bfunc\s+\w+\s*\("#, weight: 4),
            .init(pattern: #"\bimport\s+(?:Foundation|SwiftUI|UIKit|AppKit|Combine|Swift)\b"#, weight: 6),
            .init(pattern: #"(?m)^\s*guard\s+(?:let|var)\b|\bif\s+let\s+\w+"#, weight: 5),
            .init(pattern: #"\b(?:@main|@State|@Published|@ObservedObject|@EnvironmentObject|@Sendable|@MainActor)\b"#, weight: 5),
            .init(pattern: #"\blet\s+\w+\s*(?::[^=]+)?=\s*.+"#, weight: 3),
            .init(pattern: #"\b(?:struct|enum|protocol|extension|actor)\s+\w+"#, weight: 2),
            .init(pattern: #"(?m)^\s*@(?:escaping|objc|autoclosure|available)\b"#, weight: 3)
        ],
        .go: [
            .init(pattern: #"(?m)^\s*package\s+\w+\s*$"#, weight: 4),
            .init(pattern: #"(?m)^func\s+(?:\([^)]*\)\s*)?\w+\s*\([^)]*\)"#, weight: 5),
            .init(pattern: #"\bfmt\.(?:Print|Printf|Println|Sprint|Sprintf|Errorf|Fprint)\b"#, weight: 6),
            .init(pattern: #"\berr\s*(?:!=\s*nil|==\s*nil)"#, weight: 5),
            .init(pattern: #"(?m)^\s*type\s+\w+\s+struct\b"#, weight: 5),
            .init(pattern: #"\bgo\s+func\s*\(|\bchan\s+\w+|\bdefer\s+\w+\s*\("#, weight: 4),
            .init(pattern: #":=\s*[^=\s]"#, weight: 2),
            .init(pattern: #"(?m)^\s*import\s+\($|\bimport\s+\("#, weight: 3)
        ],
        .rust: [
            .init(pattern: #"(?m)^\s*(?:pub\s+)?(?:async\s+)?fn\s+\w+"#, weight: 5),
            .init(pattern: #"(?m)^\s*use\s+[\w:{}, ]+;"#, weight: 5),
            .init(pattern: #"\blet\s+mut\s+\w+"#, weight: 5),
            .init(pattern: #"\bprintln!|\bprint!|\bformat!|\bvec!|\bpanic!"#, weight: 5),
            .init(pattern: #"(?:Option|Result|Vec|String|HashMap|BTreeMap)::\w+"#, weight: 4),
            .init(pattern: #"\bimpl\s+(?:\w+\s+for\s+)?\w+"#, weight: 5),
            .init(pattern: #"#\[derive\([^)]*\)\]|#\[(?:allow|cfg|test)"#, weight: 5),
            .init(pattern: #"\.unwrap\(\)|\.expect\(|\.clone\(\);"#, weight: 2),
            .init(pattern: #"\bmatch\s+\w+\s*\{"#, weight: 1)
        ],
        .c: [
            .init(pattern: ##"#include\s*[<\"](?:assert|ctype|errno|float|inttypes|limits|math|setjmp|signal|stdarg|stdbool|stddef|stdint|stdio|stdlib|string|time)\.h[>\"]"##, weight: 6),
            .init(pattern: #"(?m)^\s*(?:int|void|char|float|double|long|short|unsigned|size_t)\s+main\s*\("#, weight: 6),
            .init(pattern: #"\b(?:printf|fprintf|sprintf|scanf|fscanf|sscanf)\s*\("#, weight: 4),
            .init(pattern: #"\b(?:malloc|calloc|realloc|free)\s*\("#, weight: 4),
            .init(pattern: #"\bsizeof\s*\(\s*\w+"#, weight: 3),
            .init(pattern: #"\b(?:NULL|EOF|stdout|stderr)\b"#, weight: 2),
            .init(pattern: ##"\b(?:int|char|float|double|long|short|unsigned|size_t|uint8_t|uint16_t|uint32_t)\s+\w+\s*(?:=|;|\[)"##, weight: 2),
            .init(pattern: ##"\btypedef\s+(?:struct|enum)\b"##, weight: 3)
        ],
        .cpp: [
            .init(pattern: ##"#include\s*<(?:iostream|vector|string|map|set|algorithm|memory|queue|stack|cmath|array)>"##, weight: 6),
            .init(pattern: #"\bstd::\w+"#, weight: 5),
            .init(pattern: #"(?m)^\s*using\s+namespace\s+std\s*;"#, weight: 6),
            .init(pattern: #"\b(?:cout|cin|cerr|clog|endl)\b"#, weight: 5),
            .init(pattern: #"(?m)^\s*template\s*<"#, weight: 4),
            .init(pattern: #"\bnullptr\b|\bconstexpr\b|\bauto\s+\w+\s*="#, weight: 3),
            .init(pattern: #"(?m)^\s*(?:public|private|protected)\s*:"#, weight: 3),
            .init(pattern: ##"\b(?:int|char|float|double|long|short|unsigned|size_t)\s+\w+\s*(?:=|;|\[)"##, weight: 2)
        ],
        .csharp: [
            .init(pattern: #"(?m)^\s*using\s+System"#, weight: 6),
            .init(pattern: #"\bConsole\.(?:Write|WriteLine|ReadLine|Read)\s*\("#, weight: 6),
            .init(pattern: #"(?m)^\s*namespace\s+[\w.]+\s*$"#, weight: 4),
            .init(pattern: #"\bpublic\s+(?:partial\s+|sealed\s+|static\s+|abstract\s+)*class\s+\w+"#, weight: 4),
            .init(pattern: #"\basync\s+Task\b|\bawait\s+\w+\s*\("#, weight: 3),
            .init(pattern: #"\b(?:get|set)\s*;\s*(?:get|set)\s*;|\b\{\s*get;\s*set;\s*\}"#, weight: 4),
            .init(pattern: #"\b(?:IEnumerable|IList|List<|Dictionary<|string|int|bool|double)\s+\w+\s*(?:=|;|\{)"#, weight: 2)
        ],
        .kotlin: [
            .init(pattern: #"(?m)^\s*(?:public\s+|private\s+|internal\s+|suspend\s+|inline\s+|operator\s+)*fun\s+(?:<[^>]+>\s*)?\w+\s*\("#, weight: 5),
            .init(pattern: #"\bsuspend\s+fun\b|\bcompanion\s+object\b"#, weight: 5),
            .init(pattern: #"(?m)^\s*(?:data\s+|sealed\s+|abstract\s+|open\s+|enum\s+|annotation\s+)*class\s+\w+(?:\s*\(|\s*:|<)"#, weight: 3),
            .init(pattern: #"\bprintln\s*\(|\blog\s*[(!]"#, weight: 3),
            .init(pattern: #"\bval\s+\w+|\bvar\s+\w+\s*[:=]"#, weight: 2),
            .init(pattern: #"(?m)^\s*import\s+kotlin"#, weight: 4),
            .init(pattern: #"\bwhen\s*[({]"#, weight: 2)
        ],
        .ruby: [
            .init(pattern: #"(?m)^#![^\n]*\bruby[0-9.]*\b"#, weight: 8),
            .init(pattern: #"(?m)^\s*def\s+\w+[!?]?\s*(\(|$|\s)"#, weight: 5),
            .init(pattern: #"\bputs\s+|\bp\s+\S|\bpp\s+\S"#, weight: 4),
            .init(pattern: ##"(?m)^\s*(?:require|require_relative|load)\s+['\"]"##, weight: 5),
            .init(pattern: #"\battr_(?:accessor|reader|writer)\b|\bmattr_"#, weight: 5),
            .init(pattern: #"(?m)^\s*module\s+\w+"#, weight: 3),
            .init(pattern: #"\bdo\s*\|[\w,\s|]*\|"#, weight: 4),
            .init(pattern: #"=>\s*\S"#, weight: 1),
            .init(pattern: #"(?m)^\s*end\s*$"#, weight: 1)
        ],
        .php: [
            .init(pattern: #"(?m)^#![^\n]*\bphp[0-9.]*\b"#, weight: 8),
            .init(pattern: #"<\?php|<\?="#, weight: 8),
            .init(pattern: #"\$\w+\s*="#, weight: 3),
            .init(pattern: #"\becho\s+|\bprint\s+\S"#, weight: 4),
            .init(pattern: #"\b(?:public|private|protected)\s+(?:static\s+)?function\s+\w+"#, weight: 4),
            .init(pattern: #"\b(?:isset|unset|empty|count|array_map|array_filter)\s*\("#, weight: 3),
            .init(pattern: #"->\w+\s*(?:\(|;|=)"#, weight: 2),
            .init(pattern: #"(?m)^\s*namespace\s+[\w\\]+\s*;"#, weight: 3),
            .init(pattern: #"\barray\s*\("#, weight: 2)
        ],
        .bash: [
            .init(pattern: #"(?m)^#!\s*\/(?:usr\/)?bin\/(?:env\s+)?(?:ba|z|fi|a)?sh\b"#, weight: 8),
            // 解释器内联调用（python3 -c "..."、node -e "..."）：外层是命令，内层源码不一定有语言特征
            .init(pattern: #"(?m)^\s*(?:sudo\s+)?(?:python3?|node|ruby|perl|deno|bun)\s+(?:-[A-Za-z]|\S+\.(?:py|js|mjs|cjs|ts|rb|pl|sh)\b)"#, weight: 7),
            .init(pattern: #"(?m)^\s*\$\s+[a-z][\w-]*\b"#, weight: 5),
            .init(pattern: #"(?m)^\s*(?:sudo\s+)?(?:brew|docker|kubectl|git|chmod|chown|npm|yarn|pnpm|cargo|pip3?|apt|apt-get|curl|wget)\s+\S"#, weight: 4),
            // 多行命令行尾反斜杠续行（典型 curl / docker 等复杂脚本命令）
            .init(pattern: #"(?m)\\\s*$"#, weight: 4),
            // 多行 CLI 标志参数（如换行后的 -H, --data-raw 等）
            .init(pattern: #"(?m)^\s*--?[a-zA-Z0-9_-]+"#, weight: 3),
            .init(pattern: #"(?m)^\s*if\s+(?:\[\[?|test\b)"#, weight: 5),
            .init(pattern: #"(?m)^\s*(?:fi|done|esac)\s*$"#, weight: 4),
            .init(pattern: #";\s*(?:then|do)\b"#, weight: 4),
            .init(pattern: #"(?m)^\s*(?:case\s+\S+\s+in|for\s+\w+\s+in\b|while\s+)"#, weight: 3),
            .init(pattern: #"(?m)^\s*(?:echo|printf|cd|mkdir|cp|mv|rm|touch|cat|grep|sed|awk|tar|find|source|alias)\s+(?:-[a-zA-Z]|["'$/~])"#, weight: 3),
            .init(pattern: #"(?m)^\s*(?:export|unset|readonly)\s+[A-Za-z_]"#, weight: 4),
            .init(pattern: #"(?m)^\s*[A-Za-z_][A-Za-z0-9_]*=(?:["'`]|\$\(|[^\s]+)"#, weight: 3),
            .init(pattern: #"(?m)<<[-]?\s*['"]?[A-Z_]{2,}['"]?"#, weight: 5),
            .init(pattern: #"2>&1|>/dev/null|>>\s*[\w/~.]"#, weight: 4),
            .init(pattern: #"\|\s*(?:grep|awk|sed|xargs|sort|uniq|head|tail|wc|tee|bash|sh|zsh)\b"#, weight: 3),
            .init(pattern: #"(?m)(?:\$\([a-zA-Z_]|`[a-zA-Z_])"#, weight: 3),
            .init(pattern: #"\$\{?[A-Z_]{2,}\}?|\$(?:\?|@|#|\*|\!|\$|\d)"#, weight: 2),
            .init(pattern: #"\|\||&&"#, weight: 1)
        ],
        .sql: [
            .init(pattern: #"(?m)^\s*SELECT\b[\s\S]{0,400}?\bFROM\b"#, weight: 6, caseSensitive: true),
            .init(pattern: #"(?m)^\s*INSERT\s+INTO\b|\bINSERT\s+INTO\b"#, weight: 6, caseSensitive: true),
            .init(pattern: #"(?m)^\s*CREATE\s+(?:TABLE|VIEW|INDEX|DATABASE|SCHEMA)\b"#, weight: 6, caseSensitive: true),
            .init(pattern: #"(?m)^\s*UPDATE\s+\w+\s+SET\b"#, weight: 6, caseSensitive: true),
            .init(pattern: #"(?m)^\s*DELETE\s+FROM\b"#, weight: 5, caseSensitive: true),
            .init(pattern: #"\b(?:INNER|LEFT|RIGHT|FULL|CROSS)\s+JOIN\s+\w+\s+ON\b"#, weight: 5),
            .init(pattern: #"\b(?:GROUP|ORDER)\s+BY\b|\bHAVING\b"#, weight: 4),
            .init(pattern: #"(?i)\b(?:VARCHAR|INTEGER|BIGINT|DECIMAL|TIMESTAMP|PRIMARY\s+KEY|FOREIGN\s+KEY|NOT\s+NULL|UNIQUE)\b"#, weight: 3),
            .init(pattern: #"(?m)^\s*WITH\s+\w+\s+AS\s*\("#, weight: 4, caseSensitive: true)
        ],
        .json: [
            .init(pattern: #"^\s*[\{\[]"#, weight: 2),
            .init(pattern: ##""[^"\n]{1,64}"\s*:\s*(?:"[^"\n]*"|-?\d|true|false|null|[\[{])"##, weight: 4)
        ],
        .yaml: [
            .init(pattern: #"(?m)^\s*---\s*$"#, weight: 4),
            .init(pattern: #"(?m)^\s*-\s+[\w.-]+\s*:\s*\S"#, weight: 4),
            .init(pattern: #"(?m)^\s{2,}[\w.-]+\s*:\s*\S"#, weight: 2),
            .init(pattern: #"(?m)^[A-Za-z_][\w.-]*\s*:(?:\s|$)"#, weight: 2),
            .init(pattern: ##"\b(?:version|image|name|services|environment|ports)\s*:\s*\S"##, weight: 2)
        ],
        .css: [
            .init(pattern: #"(?m)^[.#]?[\w-]+\s*\{[^{}]*:[^{}]*\}"#, weight: 5),
            .init(pattern: #"@(?:media|keyframes|supports|font-face|charset|import|namespace|layer|container|property)\b"#, weight: 5),
            .init(pattern: #"(?m)^\s*(?:--[\w-]+|:root)\s"#, weight: 3),
            .init(pattern: #"(?m)^\s*(?:html|body|\*|h[1-6]|ul|ol|li|a|p|div|span)\s*\{"#, weight: 2),
            .init(pattern: ##"#[0-9a-fA-F]{3,8}\b"##, weight: 1)
        ],
        .nginx: [
            .init(pattern: #"(?m)^\s*(?:events|http|server)\s*\{"#, weight: 6),
            .init(pattern: #"(?m)^\s*location\s+[^{]+\{"#, weight: 6),
            .init(pattern: #"(?m)^\s*upstream\s+\w+\s*\{"#, weight: 5),
            .init(pattern: #"(?m)^\s*(?:proxy_pass|fastcgi_pass|uwsgi_pass)\s+[^;]+;"#, weight: 6),
            .init(pattern: #"(?m)^\s*(?:server_name|try_files|ssl_certificate|worker_processes|client_max_body_size)\s+[^;]+;"#, weight: 5),
            .init(pattern: #"(?m)^\s*(?:listen|proxy_set_header|fastcgi_param)\s+[^;]+;"#, weight: 4),
            .init(pattern: #"\$[a-z_][a-z0-9_]*"#, weight: 2)
        ],
        .html: [
            .init(pattern: #"(?i)<!DOCTYPE\s+html"#, weight: 8),
            .init(pattern: #"(?i)<\?xml\s"#, weight: 8),
            .init(pattern: #"(?i)<html\b"#, weight: 6),
            .init(pattern: #"(?m)^\s*<(?:div|span|section|article|header|footer|nav|main|aside|form|table|button|label|select|textarea|template|svg)\b"#, weight: 4),
            .init(pattern: #"(?i)</(?:div|span|p|a|li|ul|body|html|head)>"#, weight: 3),
            .init(pattern: #"(?i)<!--"#, weight: 3),
            .init(pattern: ##"\s(?:class|id|href|src|style|type|value|name|placeholder|data-[\w-]+|aria-[\w-]+)="##, weight: 2),
            .init(pattern: #"&(?:amp|lt|gt|quot|nbsp|#\d+);"#, weight: 3)
        ]
    ]
}
