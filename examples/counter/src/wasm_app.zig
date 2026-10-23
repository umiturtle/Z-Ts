//! `wasm32-freestanding` エントリポイント（静的 SSG Web 成果物 / `RuntimeMode.wasm`）。
//!
//! このファイルは `src/app.zig` の **同一コマンド実装** を `zts_wasm.exportApp` で C ABI
//! (`zts_wasm_*`) へ束縛するだけです。ブラウザ側は `dist/_zts/app.wasm` を
//! `WebAssembly.instantiate` し、無改造 `@tauri-apps/api` v2 から線形メモリ経由で呼び出します。

const std = @import("std");
const wasm = @import("zts_wasm");

const app = @import("app.zig");

pub const Impl = app.App(.wasm);

pub const wasm_exports = wasm.exportApp(Impl.Spec);

/// `std.debug` は `wasm32-freestanding` で出力できないため、ブラウザ console へパニックを流す。
pub const panic = std.debug.FullPanic(wasm.host.reportPanic);

comptime {
    // 宣言へのポインタ取得が無いと `@export` ブロックが意味解析されない（Zig 0.17 の罠）。
    _ = &wasm_exports.init;
    _ = &wasm_exports.invoke;
}

/// `wasm-ld` が要求するエントリ（`-rdynamic` により `zts_wasm_*` も同時にエクスポートされる）。
pub fn main() void {}
