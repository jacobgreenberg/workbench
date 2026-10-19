import AppKit

@MainActor enum FileIcons {
    static let names: [String: String] = [
        ".editorconfig": "editorconfig",
        ".env": "tune",
        ".gitattributes": "git",
        ".gitignore": "git",
        ".nvmrc": "nodejs",
        "babel.config.js": "babel",
        "bun.lockb": "bun",
        "changelog.md": "changelog",
        "claude.md": "claude",
        "cmakelists.txt": "cmake",
        "docker-compose.yml": "docker",
        "dockerfile": "docker",
        "eas.json": "expo",
        "eslint.config.js": "eslint",
        "gemfile": "gemfile",
        "go.mod": "go-mod",
        "jest.setup.js": "jest",
        "license": "license",
        "makefile": "makefile",
        "metro.config.js": "metro",
        "package-lock.json": "nodejs",
        "package.json": "nodejs",
        "package.swift": "swift",
        "pnpm-lock.yaml": "pnpm",
        "readme.md": "readme",
        "tsconfig.json": "tsconfig",
        "yarn.lock": "yarn",
    ]
    static let prefixes: [(String, String)] = [(".eslintrc", "eslint"), (".prettierrc", "prettier"), ("jest.config.", "jest"), ("vite.config.", "vite"), ("webpack.config.", "webpack")]
    static let extensions: [String: String] = [
        "apk": "android",
        "bash": "console",
        "c": "c",
        "cc": "cpp",
        "cjs": "javascript",
        "conf": "settings",
        "cpp": "cpp",
        "cs": "csharp",
        "css": "css",
        "csv": "table",
        "dart": "dart",
        "env": "tune",
        "erl": "erlang",
        "ex": "elixir",
        "exs": "elixir",
        "fish": "console",
        "gif": "image",
        "go": "go",
        "gql": "graphql",
        "graphql": "graphql",
        "gz": "zip",
        "h": "h",
        "hpp": "hpp",
        "hs": "haskell",
        "htm": "html",
        "html": "html",
        "ico": "image",
        "ini": "settings",
        "ipa": "applescript",
        "java": "java",
        "jl": "julia",
        "jpeg": "image",
        "jpg": "image",
        "js": "javascript",
        "json": "json",
        "jsx": "react",
        "kt": "kotlin",
        "kts": "kotlin",
        "less": "less",
        "lock": "lock",
        "log": "log",
        "lua": "lua",
        "m": "objective-c",
        "markdown": "markdown",
        "md": "markdown",
        "mjs": "javascript",
        "ml": "ocaml",
        "mm": "objective-cpp",
        "nim": "nim",
        "pdf": "pdf",
        "php": "php",
        "png": "image",
        "py": "python",
        "r": "r",
        "rb": "ruby",
        "rs": "rust",
        "sass": "sass",
        "scala": "scala",
        "scss": "sass",
        "sh": "console",
        "sql": "database",
        "svelte": "svelte",
        "svg": "svg",
        "swift": "swift",
        "tar": "zip",
        "toml": "toml",
        "ts": "typescript",
        "tsx": "react_ts",
        "txt": "document",
        "vue": "vue",
        "webp": "image",
        "xml": "xml",
        "yaml": "yaml",
        "yml": "yaml",
        "zig": "zig",
        "zip": "zip",
        "zsh": "console",
    ]
    static let folders: [String: String] = [
        ".claude": "folder-claude",
        ".git": "folder-git",
        ".github": "folder-github",
        ".vscode": "folder-vscode",
        "__mocks__": "folder-mock",
        "__tests__": "folder-test",
        "android": "folder-android",
        "api": "folder-api",
        "app": "folder-app",
        "assets": "folder-resource",
        "build": "folder-dist",
        "client": "folder-client",
        "components": "folder-components",
        "config": "folder-config",
        "constants": "folder-constant",
        "controllers": "folder-controller",
        "dist": "folder-dist",
        "docs": "folder-docs",
        "fonts": "folder-font",
        "helpers": "folder-helper",
        "hooks": "folder-hook",
        "i18n": "folder-i18n",
        "images": "folder-images",
        "ios": "folder-ios",
        "layouts": "folder-layout",
        "lib": "folder-lib",
        "locales": "folder-i18n",
        "models": "folder-class",
        "node_modules": "folder-node",
        "packages": "folder-packages",
        "pages": "folder-views",
        "plugins": "folder-plugin",
        "providers": "folder-controller",
        "public": "folder-public",
        "routes": "folder-routes",
        "scripts": "folder-scripts",
        "server": "folder-server",
        "services": "folder-controller",
        "src": "folder-src",
        "store": "folder-store",
        "styles": "folder-css",
        "test": "folder-test",
        "tests": "folder-test",
        "types": "folder-typescript",
        "utils": "folder-utils",
        "views": "folder-views",
    ]
    static var cache: [String: NSImage] = [:]

    static func name(for fileName: String, isDirectory: Bool, expanded: Bool) -> String? {
        let f = fileName.lowercased()
        if isDirectory {
            return folders[f] ?? "folder-base"
        }
        if let n = names[f] { return n }
        if let p = prefixes.first(where: { f.hasPrefix($0.0) }) { return p.1 }
        if f.hasSuffix(".d.ts") { return "typescript-def" }
        let ext = (f as NSString).pathExtension
        if f.contains(".test.") || f.contains(".spec.") {
            switch ext {
            case "ts": return "test-ts"
            case "js", "mjs", "cjs": return "test-js"
            case "tsx", "jsx": return "test-jsx"
            default: break
            }
        }
        var parts = f.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 1 {
            parts.removeFirst()
            if let n = extensions[parts.joined(separator: ".")] { return n }
        }
        return "document"
    }

    static func icon(for url: URL, isDirectory: Bool, expanded: Bool) -> NSImage {
        let fallback = { () -> NSImage in
            let i = NSWorkspace.shared.icon(forFile: url.path)
            i.size = NSSize(width: 16, height: 16)
            return i
        }
        guard let n = name(for: url.lastPathComponent, isDirectory: isDirectory, expanded: expanded),
              let dir = Bundle.main.resourceURL?.appendingPathComponent("fileicons") else { return fallback() }
        if let c = cache[n] { return c }
        let file = dir.appendingPathComponent(n + ".svg")
        guard let img = NSImage(contentsOf: file) else { return fallback() }
        img.size = NSSize(width: 16, height: 16)
        cache[n] = img
        return img
    }

    static func selfCheck() {
        assert(name(for: "foo.tsx", isDirectory: false, expanded: false) == "react_ts")
        assert(name(for: "x.d.ts", isDirectory: false, expanded: false) == "typescript-def")
        assert(name(for: "package.json", isDirectory: false, expanded: false) == "nodejs")
        assert(name(for: "src", isDirectory: true, expanded: false) == "folder-src")
    }
}
