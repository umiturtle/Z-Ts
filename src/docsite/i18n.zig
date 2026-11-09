//! Localisation for the documentation site: two languages, one corpus shape.
//!
//! The reader-facing corpus lives at `docs/learn/<lang>/…` with **identical file names in every
//! language**. That rule is what makes the language switcher a pure string substitution
//! ([`alternateHref`]) instead of a hand-maintained table, and it is enforced mechanically by
//! `scripts/check-docs.py` (rule 8): a page with no counterpart fails CI.
//!
//! Everything the *shell* says (navigation labels, buttons, footers, the 404 page) comes from
//! [`Strings`], never from a literal in `site.zig` or `main.zig`. Adding a third language is one
//! enum case plus one `Strings` initialiser; the compiler then points at every place that has to
//! be filled in.

const std = @import("std");

pub const Lang = enum {
    ja,
    en,

    /// BCP-47 tag used for `<html lang>` and `hreflang`.
    pub fn code(self: Lang) []const u8 {
        return switch (self) {
            .ja => "ja",
            .en => "en",
        };
    }

    /// The language as its speakers write it (language switcher labels).
    pub fn nativeName(self: Lang) []const u8 {
        return switch (self) {
            .ja => "日本語",
            .en => "English",
        };
    }

    pub fn other(self: Lang) Lang {
        return switch (self) {
            .ja => .en,
            .en => .ja,
        };
    }

    /// `docs/learn/en/concepts/rpc.md` → `.en`. `null` for pages outside the translated tree
    /// (the legacy Japanese guides, the API reference, the internals) — those render without a
    /// language switcher because there is nothing to switch to.
    pub fn fromPath(path: []const u8) ?Lang {
        if (!std.mem.startsWith(u8, path, learn_root)) return null;
        const rest = path[learn_root.len..];
        if (std.mem.startsWith(u8, rest, "ja/")) return .ja;
        if (std.mem.startsWith(u8, rest, "en/")) return .en;
        return null;
    }
};

/// Prefix of the translated tree, relative to the repository root.
pub const learn_root = "docs/learn/";

/// The counterpart of `path` in `to`, or the root of `to` when the page has no translation.
/// Returning a real page (not a 404) is deliberate: the switcher must never dead-end.
pub fn alternateHref(allocator: std.mem.Allocator, path: []const u8, to: Lang) ![]const u8 {
    if (Lang.fromPath(path)) |from| {
        const rest = path[learn_root.len..];
        const tail = rest[from.code().len + 1 ..]; // strip `ja/` / `en/`
        return std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ learn_root, to.code(), tail });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}/index.md", .{ learn_root, to.code() });
}

/// Every string the page shell needs. Grouped by where it appears, so a translator can work
/// top-to-bottom without reading the renderer.
pub const Strings = struct {
    // ---------------------------------------------------------------- chrome
    skip_to_content: []const u8,
    menu: []const u8,
    theme: []const u8,
    theme_to_dark: []const u8,
    theme_to_light: []const u8,
    language: []const u8,
    search_placeholder: []const u8,
    search_empty: []const u8,
    github: []const u8,
    copy: []const u8,
    copied: []const u8,

    // ------------------------------------------------------------- navigation
    nav_label: []const u8,
    crumbs_label: []const u8,
    toc: []const u8,
    previous: []const u8,
    next: []const u8,
    edit: []const u8,
    words_fmt: []const u8,
    footer_note: []const u8,
    /// Name of the beginner path, used as the step rail's accessible label and as the sidebar
    /// heading of the first group.
    path_label: []const u8,
    /// Label of the "continue to the next step" call to action under the rail.
    path_continue: []const u8,

    // ------------------------------------------------------------------ 404
    not_found_title: []const u8,
    not_found_body: []const u8,

    // ------------------------------------------------------------- landing
    landing_eyebrow: []const u8,
    landing_title_a: []const u8,
    landing_title_b: []const u8,
    landing_lede: []const u8,
    landing_cta_start: []const u8,
    landing_cta_api: []const u8,
    /// Hero button that goes straight to the downloadable `zts` binaries.
    landing_cta_download: []const u8,
    landing_cta_samples: []const u8,
    landing_cta_source: []const u8,
    /// Hero's secondary button: jump into the build-an-app step.
    landing_cta_tutorial: []const u8,
    /// Heading of the step-path block on the landing page.
    landing_path_title: []const u8,
    /// One sentence introducing that block; the total is rendered separately from `learn_path`.
    landing_path_lede: []const u8,
    /// `{d}` is replaced with the total minutes of the path.
    landing_path_total: []const u8,
    landing_paths_title: []const u8,
    landing_all_pages: []const u8,
    landing_meta: []const u8,
    landing_feature_title: []const u8,
    landing_feature_1_t: []const u8,
    landing_feature_1_b: []const u8,
    landing_feature_2_t: []const u8,
    landing_feature_2_b: []const u8,
    landing_feature_3_t: []const u8,
    landing_feature_3_b: []const u8,
    landing_feature_4_t: []const u8,
    landing_feature_4_b: []const u8,
    landing_stats_fmt: []const u8,
};

pub fn strings(lang: Lang) Strings {
    return switch (lang) {
        .ja => .{
            .skip_to_content = "本文へスキップ",
            .menu = "メニュー",
            .theme = "テーマ切替",
            .theme_to_dark = "ダークモードにする",
            .theme_to_light = "ライトモードにする",
            .language = "言語",
            .search_placeholder = "検索…  ( / )",
            .search_empty = "ヒットなし",
            .github = "GitHub",
            .copy = "コピー",
            .copied = "コピー済み",

            .nav_label = "ドキュメント",
            .crumbs_label = "パンくず",
            .toc = "このページの目次",
            .previous = "前のページ",
            .next = "次のページ",
            .edit = "このページを GitHub で編集",
            .words_fmt = "{d} 語",
            .footer_note = "Tauri v2 の思想を Zig 0.17 で再実装",
            .path_label = "学習パス",
            .path_continue = "次のステップへ",

            .not_found_title = "ページが見つかりません",
            .not_found_body = "URL が変わったか、まだ存在しません。検索（<kbd>/</kbd>）か、下の入口から辿ってください。",

            .landing_eyebrow = "Zig 0.17 · Tauri v2 互換 · コアは C 依存ゼロ",
            .landing_title_a = "デスクトップも、WebAssembly も、",
            .landing_title_b = "静的サイトも。1 言語で。",
            .landing_lede = "Z-Ts は Tauri v2 のプロトコルとプラグインを Zig で再実装したツールキットです。同じアプリコードからネイティブ WebView・ブラウザ Live Preview・静的 SSG の 3 つの成果物を生成し、3 OS で同じピクセルを描きます。",
            .landing_cta_start = "10 分ではじめる",
            .landing_cta_api = "API リファレンス",
            .landing_cta_download = "ダウンロード",
            .landing_cta_samples = "動くサンプル",
            .landing_cta_source = "ソース",
            .landing_cta_tutorial = "チュートリアル",
            .landing_path_title = "学習パス",
            .landing_path_lede = "未経験から最初のバイナリまで、道順は 1 本だけ。各ページの上に常に出ています（所要時間は下の合計）。",
            .landing_path_total = "全体 {d} 分",
            .landing_paths_title = "目的から選ぶ",
            .landing_all_pages = "すべてのページ",
            .landing_meta = "対応: Zig 0.17.0 / Tauri v2 / Linux・macOS・Windows",
            .landing_feature_title = "なぜ Z-Ts か",
            .landing_feature_1_t = "6 つの直交パッケージ",
            .landing_feature_1_b = "使うものだけリンクできます。コアは libc すら要求しません。",
            .landing_feature_2_t = "3 つの成果物、1 つのコード",
            .landing_feature_2_b = "同じソースからネイティブ・ブラウザ・静的サイトを生成します。環境判定は 0 行。",
            .landing_feature_3_t = "OS 間で同じピクセル",
            .landing_feature_3_b = "同梱フォントとレイアウト指紋で、3 OS のスクリーンショットを CI が相互比較します。",
            .landing_feature_4_t = "Tauri のエコシステムをそのまま",
            .landing_feature_4_b = "無改変の @tauri-apps/api v2 と、そのまま読める tauri.conf.json / capabilities。",
            .landing_stats_fmt = "{d} 件の公開宣言 · {d} ページの API リファレンス · {d} 個のエラー索引",
        },
        .en => .{
            .skip_to_content = "Skip to content",
            .menu = "Menu",
            .theme = "Toggle theme",
            .theme_to_dark = "Switch to dark mode",
            .theme_to_light = "Switch to light mode",
            .language = "Language",
            .search_placeholder = "Search…  ( / )",
            .search_empty = "No matches",
            .github = "GitHub",
            .copy = "Copy",
            .copied = "Copied",

            .nav_label = "Documentation",
            .crumbs_label = "Breadcrumb",
            .toc = "On this page",
            .previous = "Previous",
            .next = "Next",
            .edit = "Edit this page on GitHub",
            .words_fmt = "{d} words",
            .footer_note = "Tauri v2, reimplemented in Zig 0.17",
            .path_label = "Learning path",
            .path_continue = "Next step",

            .not_found_title = "Page not found",
            .not_found_body = "The URL moved, or the page never existed. Try the search (<kbd>/</kbd>), or start from one of the entry points below.",

            .landing_eyebrow = "Zig 0.17 · Tauri v2 compatible · zero C dependencies in the core",
            .landing_title_a = "Desktop, WebAssembly,",
            .landing_title_b = "static sites. One language.",
            .landing_lede = "Z-Ts reimplements the Tauri v2 protocol and its plugins in Zig. One application source produces three artifacts — a native WebView binary, a browser Live Preview, and a static site — and draws the same pixels on all three operating systems.",
            .landing_cta_start = "Start in 10 minutes",
            .landing_cta_api = "API reference",
            .landing_cta_download = "Download",
            .landing_cta_samples = "Examples",
            .landing_cta_source = "Source",
            .landing_cta_tutorial = "Tutorials",
            .landing_path_title = "The learning path",
            .landing_path_lede = "From never having run it to your first binary, one order — always shown at the top of the page you are on (total below).",
            .landing_path_total = "{d} minutes in total",
            .landing_paths_title = "Choose by job",
            .landing_all_pages = "All pages",
            .landing_meta = "Requires: Zig 0.17.0 / Tauri v2 / Linux, macOS or Windows",
            .landing_feature_title = "Why Z-Ts",
            .landing_feature_1_t = "Six orthogonal packages",
            .landing_feature_1_b = "Link only what you use. The core does not even require libc.",
            .landing_feature_2_t = "Three artifacts, one source",
            .landing_feature_2_b = "Native, browser and static output from the same code. Zero runtime branching on the target.",
            .landing_feature_3_t = "Identical pixels across OSes",
            .landing_feature_3_b = "Bundled fonts and a layout fingerprint let CI compare screenshots from all three platforms.",
            .landing_feature_4_t = "The Tauri ecosystem, unchanged",
            .landing_feature_4_b = "Unmodified @tauri-apps/api v2, and tauri.conf.json / capabilities read as-is.",
            .landing_stats_fmt = "{d} public declarations · {d} API pages · {d} indexed errors",
        },
    };
}

/// Human-readable label for a page kind (`guide`, `tutorial`, `concept`, …).
pub fn kindLabel(lang: Lang, kind: []const u8) []const u8 {
    const Table = struct { kind: []const u8, ja: []const u8, en: []const u8 };
    const table = [_]Table{
        .{ .kind = "guide", .ja = "ガイド", .en = "Guide" },
        .{ .kind = "tutorial", .ja = "チュートリアル", .en = "Tutorial" },
        .{ .kind = "concept", .ja = "概念", .en = "Concept" },
        .{ .kind = "reference", .ja = "リファレンス", .en = "Reference" },
        .{ .kind = "recipe", .ja = "レシピ", .en = "Recipe" },
        .{ .kind = "migration", .ja = "移行", .en = "Migration" },
        .{ .kind = "errors", .ja = "エラー", .en = "Errors" },
        .{ .kind = "api", .ja = "API", .en = "API" },
        .{ .kind = "internals", .ja = "内部資料", .en = "Internals" },
        .{ .kind = "home", .ja = "ホーム", .en = "Home" },
        .{ .kind = "deep", .ja = "詳細", .en = "Deep dive" },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, kind, row.kind)) return switch (lang) {
            .ja => row.ja,
            .en => row.en,
        };
    }
    return kind;
}

test "paths map to a language and back" {
    try std.testing.expectEqual(@as(?Lang, .ja), Lang.fromPath("docs/learn/ja/concepts/rpc.md"));
    try std.testing.expectEqual(@as(?Lang, .en), Lang.fromPath("docs/learn/en/index.md"));
    // Outside the translated tree there is no counterpart, by design.
    try std.testing.expectEqual(@as(?Lang, null), Lang.fromPath("docs/guides/using-rpc.md"));
    try std.testing.expectEqual(@as(?Lang, null), Lang.fromPath("docs/learn/README.md"));
}

test "the alternate of a translated page keeps its path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const en = try alternateHref(arena, "docs/learn/ja/concepts/rpc.md", .en);
    try std.testing.expectEqualStrings("docs/learn/en/concepts/rpc.md", en);
    const ja = try alternateHref(arena, "docs/learn/en/tutorials/counter.md", .ja);
    try std.testing.expectEqualStrings("docs/learn/ja/tutorials/counter.md", ja);

    // A page with no translation falls back to the other language's hub, never to a 404.
    const fallback = try alternateHref(arena, "docs/guides/using-rpc.md", .en);
    try std.testing.expectEqualStrings("docs/learn/en/index.md", fallback);
}

test "every kind has a label in both languages" {
    try std.testing.expectEqualStrings("ガイド", kindLabel(.ja, "guide"));
    try std.testing.expectEqualStrings("Guide", kindLabel(.en, "guide"));
    try std.testing.expectEqualStrings("Tutorial", kindLabel(.en, "tutorial"));
    // An unknown kind is passed through rather than swallowed.
    try std.testing.expectEqualStrings("mystery", kindLabel(.en, "mystery"));
}
