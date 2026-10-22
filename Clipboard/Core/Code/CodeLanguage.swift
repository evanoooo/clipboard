//
//  CodeLanguage.swift
//  Clipboard
//
//  代码片段可识别的语言集合
//

import Foundation

/// 可识别并高亮的开发语言。
///
/// 只收录常见语言：识别必须保守，普通散文、URL、Markdown 不得命中，
/// 因此语言数量以「能否给出可信判别信号」为准，不做全覆盖。
nonisolated enum CodeLanguage: String, Sendable, CaseIterable {
    case bash
    case c
    case cpp
    case csharp
    case css
    case go
    case html
    case java
    case javascript
    case json
    case kotlin
    case nginx
    case php
    case python
    case ruby
    case rust
    case sql
    case swift
    case typescript
    case yaml

    var displayName: String {
        switch self {
        case .bash: "Shell"
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .css: "CSS"
        case .go: "Go"
        case .html: "HTML"
        case .java: "Java"
        case .javascript: "JavaScript"
        case .json: "JSON"
        case .kotlin: "Kotlin"
        case .nginx: "Nginx"
        case .php: "PHP"
        case .python: "Python"
        case .ruby: "Ruby"
        case .rust: "Rust"
        case .sql: "SQL"
        case .swift: "Swift"
        case .typescript: "TypeScript"
        case .yaml: "YAML"
        }
    }
}
