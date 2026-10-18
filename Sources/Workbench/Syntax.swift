import Foundation
import Synchronization
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterCSS
import TreeSitterDockerfile
import TreeSitterElixir
import TreeSitterGo
import TreeSitterHeex
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterKotlin
import TreeSitterLua
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// Tree-sitter syntax highlighting for the file pane. Grammars are compiled in; a language's highlight query is read
/// from its SwiftPM resource bundle and compiled on first use, then cached.
enum Syntax {
    private struct Grammar: @unchecked Sendable {   // the TSLanguage pointers are static, immutable C data
        let language: OpaquePointer
        let queries: [String]   // "<bundle>/<file>", concatenated in order (TypeScript extends JavaScript's)
    }

    private static let byExtension: [String: Grammar] = {
        let js = ["TreeSitterJavaScript_TreeSitterJavaScript/highlights.scm"]
        let ts = js + ["TreeSitterTypeScript_TreeSitterTypeScript/highlights.scm"]
        let table: [([String], OpaquePointer, [String])] = [
            (["ex", "exs"], tree_sitter_elixir(), ["TreeSitterElixir_TreeSitterElixir/highlights.scm"]),
            (["heex"], tree_sitter_heex(), ["TreeSitterHeex_TreeSitterHeex/highlights.scm"]),
            (["py", "pyi"], tree_sitter_python(), ["TreeSitterPython_TreeSitterPython/highlights.scm"]),
            (["js", "mjs", "cjs", "jsx"], tree_sitter_javascript(),
             js + ["TreeSitterJavaScript_TreeSitterJavaScript/highlights-jsx.scm"]),
            (["ts", "mts", "cts"], tree_sitter_typescript(), ts),
            (["tsx"], tree_sitter_tsx(), ts + ["TreeSitterJavaScript_TreeSitterJavaScript/highlights-jsx.scm"]),
            (["go"], tree_sitter_go(), ["TreeSitterGo_TreeSitterGo/highlights.scm"]),
            (["rs"], tree_sitter_rust(), ["TreeSitterRust_TreeSitterRust/highlights.scm"]),
            (["rb", "rake", "gemspec"], tree_sitter_ruby(), ["TreeSitterRuby_TreeSitterRuby/highlights.scm"]),
            (["java"], tree_sitter_java(), ["TreeSitterJava_TreeSitterJava/highlights.scm"]),
            (["c", "h"], tree_sitter_c(), ["TreeSitterC_TreeSitterC/highlights.scm"]),
            (["cc", "cpp", "cxx", "hpp", "hh", "hxx", "mm"], tree_sitter_cpp(),
             ["TreeSitterC_TreeSitterC/highlights.scm", "TreeSitterCPP_TreeSitterCPP/highlights.scm"]),
            (["cs"], tree_sitter_c_sharp(), ["TreeSitterCSharp_TreeSitterCSharp/highlights.scm"]),
            (["json", "jsonc"], tree_sitter_json(), ["TreeSitterJSON_TreeSitterJSON/highlights.scm"]),
            (["sh", "bash", "zsh"], tree_sitter_bash(), ["TreeSitterBash_TreeSitterBash/highlights.scm"]),
            (["html", "htm"], tree_sitter_html(), ["TreeSitterHTML_TreeSitterHTML/highlights.scm"]),
            (["css"], tree_sitter_css(), ["TreeSitterCSS_TreeSitterCSS/highlights.scm"]),
            (["swift"], tree_sitter_swift(), ["TreeSitterSwift_TreeSitterSwift/highlights.scm"]),
            (["yml", "yaml"], tree_sitter_yaml(), ["TreeSitterYAML_TreeSitterYAML/highlights.scm"]),
            (["toml"], tree_sitter_toml(), ["TreeSitterTOML_TreeSitterTOML/highlights.scm"]),
            (["lua"], tree_sitter_lua(), ["TreeSitterLua_TreeSitterLua/highlights.scm"]),
            (["kt", "kts"], tree_sitter_kotlin(), ["TreeSitterKotlin_TreeSitterKotlin/highlights.scm"]),
            (["dockerfile"], tree_sitter_dockerfile(), ["TreeSitterDockerfile_TreeSitterDockerfile/highlights.scm"]),
        ]
        var m: [String: Grammar] = [:]
        for (exts, lang, queries) in table { for e in exts { m[e] = Grammar(language: lang, queries: queries) } }
        return m
    }()

    private static let fenceAliases = ["elixir": "ex", "python": "py", "javascript": "js", "typescript": "ts",
                                       "ruby": "rb", "rust": "rs", "golang": "go", "csharp": "cs", "c#": "cs", "c++": "cpp",
                                       "shell": "sh", "console": "sh", "kotlin": "kt", "docker": "dockerfile"]

    /// The grammar key for a markdown code fence's info string ("elixir", "ts", ...).
    static func key(fence: String) -> String? {
        let k = fence.split(separator: " ").first.map { $0.lowercased() } ?? ""
        let r = fenceAliases[k] ?? k
        return byExtension[r] != nil ? r : nil
    }

    /// The grammar key for a path: its lowercased extension, or the file name for extensionless files like Dockerfile.
    static func key(for path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let k = ext.isEmpty ? url.lastPathComponent.lowercased() : ext
        return byExtension[k] != nil ? k : nil
    }

    private final class Compiled: @unchecked Sendable {   // Language and Query are immutable after creation
        let language: Language
        let query: Query
        init(language: Language, query: Query) { self.language = language; self.query = query }
    }
    private static let cache = Mutex<[String: Compiled?]>([:])

    private static func compiled(_ key: String) -> Compiled? {
        if let hit = cache.withLock({ $0[key] }) { return hit }
        var result: Compiled?
        if let g = byExtension[key], let root = Bundle.main.resourceURL {
            let source = g.queries.compactMap { rel -> Data? in
                let parts = rel.split(separator: "/")
                let url = root.appendingPathComponent("\(parts[0]).bundle/Contents/Resources/queries/\(parts[1])")
                return readFile(url, cap: 1 << 20)
            }.reduce(Data(), +)
            let language = Language(g.language)
            if let query = try? Query(language: language, data: source) { result = Compiled(language: language, query: query) }
        }
        cache.withLock { $0[key] = .some(result) }
        return result
    }

    /// Capture name (e.g. "function.method") and UTF-16 range for each highlighted span, less specific spans first.
    /// Nil when the language is unknown or its query failed to load.
    static func highlights(_ text: String, key: String) -> [(range: NSRange, name: String)]? {
        guard let c = compiled(key) else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(c.language)) != nil, let tree = parser.parse(text) else { return nil }
        return c.query.execute(in: tree).resolve(with: .init(string: text)).highlights().map { ($0.range, $0.name) }
    }
}
