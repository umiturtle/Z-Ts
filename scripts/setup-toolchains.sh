#!/usr/bin/env bash
set -euo pipefail

# Z-Ts Toolchain & Linux Sysroot Setup Script
# Designed for Debian 12 (bookworm) x86_64 environments including Arena sandboxes
# where outbound access is restricted to github.com / registry.npmjs.org / pypi.org.

ZIG_VERSION="${ZIG_VERSION:-0.17.0}"
RUST_VERSION="${RUST_VERSION:-1.99.0}"
RUST_ROOT="${RUST_ROOT:-/home/user/.local/toolchains/rust}"

FORCE=0
VERIFY=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --verify) VERIFY=1 ;;
    *)
      echo "Usage: $0 [--force] [--verify]" >&2
      exit 1
      ;;
  esac
done

WORK_DIR="$(mktemp -d /tmp/zts-setup.XXXXXX)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "[1/4] Checking Zig ${ZIG_VERSION}..."
CURRENT_ZIG="$(zig version 2>/dev/null || true)"
if [[ "$FORCE" == "1" || "$CURRENT_ZIG" != "$ZIG_VERSION" ]]; then
  echo "  Installing ziglang==${ZIG_VERSION} via PyPI..."
  python3 - "$ZIG_VERSION" "$WORK_DIR" << 'EOF'
import json, sys, urllib.request

ver, work_dir = sys.argv[1], sys.argv[2]
data = json.loads(urllib.request.urlopen("https://pypi.org/pypi/ziglang/json").read())
wheels = [
    f for f in data["releases"][ver]
    if "manylinux" in f["filename"] and "x86_64" in f["filename"]
]
if not wheels:
    raise RuntimeError(f"No Linux x86_64 wheel found for ziglang {ver}")
w = wheels[0]
dst = f"{work_dir}/{w['filename']}"
urllib.request.urlretrieve(w["url"], dst)
print(f"  Downloaded {w['filename']}")
EOF
  sudo pip3 install --no-index --find-links "$WORK_DIR" --break-system-packages --force-reinstall ziglang
  sudo ln -sf /usr/local/lib/python3.11/dist-packages/ziglang/zig /usr/local/bin/zig
else
  echo "  Zig ${CURRENT_ZIG} already installed."
fi

echo "[2/4] Checking Rust ${RUST_VERSION}..."
CURRENT_RUSTC="$(rustc --version 2>/dev/null | awk '{print $2}' || true)"
if [[ "$FORCE" == "1" || "$CURRENT_RUSTC" != "$RUST_VERSION" ]]; then
  echo "  Installing Rust ${RUST_VERSION} components into ${RUST_ROOT}..."
  mkdir -p "$RUST_ROOT"
  python3 - "$RUST_VERSION" "$RUST_ROOT" "$WORK_DIR" << 'EOF'
import json, os, shutil, sys, tarfile, urllib.request

rust_ver, rust_root, work_dir = sys.argv[1], sys.argv[2], sys.argv[3]
components = [
    f"@toolchain-bin/rustc-{rust_ver}-x86_64-unknown-linux-gnu",
    f"@toolchain-bin/cargo-{rust_ver}-x86_64-unknown-linux-gnu",
    f"@toolchain-bin/rust-std-{rust_ver}-x86_64-unknown-linux-gnu",
    f"@toolchain-bin/rustfmt-{rust_ver}-x86_64-unknown-linux-gnu",
    f"@toolchain-bin/clippy-{rust_ver}-x86_64-unknown-linux-gnu",
    f"@toolchain-bin/rust-std-{rust_ver}-wasm32-unknown-unknown",
]

for pkg in components:
    url = "https://registry.npmjs.org/" + pkg.replace("/", "%2f")
    meta = json.loads(urllib.request.urlopen(url).read())
    latest = meta["dist-tags"]["latest"]
    tar_url = meta["versions"][latest]["dist"]["tarball"]
    tgz = os.path.join(work_dir, pkg.split("/")[1] + ".tgz")
    print(f"  Downloading {pkg} @ {latest}...")
    urllib.request.urlretrieve(tar_url, tgz)
    ext = os.path.join(work_dir, "ext_" + pkg.split("/")[1])
    shutil.rmtree(ext, ignore_errors=True)
    with tarfile.open(tgz, "r:gz") as tf:
        tf.extractall(ext)
    pkg_dir = os.path.join(ext, "package")
    if "components" in os.listdir(pkg_dir):
        with open(os.path.join(pkg_dir, "components")) as cf:
            subcomps = [l.strip() for l in cf if l.strip()]
        for sc in subcomps:
            sc_dir = os.path.join(pkg_dir, sc)
            if os.path.isdir(sc_dir):
                shutil.copytree(sc_dir, rust_root, symlinks=True, dirs_exist_ok=True)
    shutil.rmtree(ext, ignore_errors=True)
    os.remove(tgz)
EOF
  chmod +x "${RUST_ROOT}/bin/"* "${RUST_ROOT}/libexec/"* 2>/dev/null || true
  find "${RUST_ROOT}/lib" -path '*/bin/*' -type f -exec chmod +x {} +
  for bin in "${RUST_ROOT}/bin/"*; do
    sudo ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"
  done
else
  echo "  Rust ${CURRENT_RUSTC} already installed."
fi

echo "[3/4] Checking Linux GTK3 / WebKit2GTK Sysroot..."
if [[ "$FORCE" == "1" ]] || ! pkg-config --exists gtk+-3.0 webkit2gtk-4.1 2>/dev/null; then
  echo "  Installing @toolchain-bin/sysroot-linux-x64..."
  python3 - "$WORK_DIR" << 'EOF'
import json, os, sys, tarfile, urllib.request

work_dir = sys.argv[1]
url = "https://registry.npmjs.org/@toolchain-bin%2fsysroot-linux-x64"
meta = json.loads(urllib.request.urlopen(url).read())
latest = meta["dist-tags"]["latest"]
tgz = os.path.join(work_dir, "sysroot.tgz")
print(f"  Downloading sysroot @ {latest}...")
urllib.request.urlretrieve(meta["versions"][latest]["dist"]["tarball"], tgz)
with tarfile.open(tgz, "r:gz") as tf:
    tf.extractall(os.path.join(work_dir, "sysroot"))
EOF
  chmod +x "${WORK_DIR}/sysroot/package/usr/bin/"*
  sudo tar -C "${WORK_DIR}/sysroot/package" -cf - . \
    | sudo tar -C / --keep-directory-symlink --skip-old-files -xf -

  # Convert flattened GNU ld INPUT(...) linker stub files back into real POSIX symlinks
  # so both dynamic loader (ldconfig) and Zig's native ELF parser work seamlessly.
  sudo python3 - << 'EOF'
import os, re

pat = re.compile(r"^INPUT\(([^)\s]+)\)$")
fixed = 0
for root_dir in ["/usr/lib", "/usr/include", "/usr/share"]:
    for dirpath, _, filenames in os.walk(root_dir):
        for fn in filenames:
            fpath = os.path.join(dirpath, fn)
            if os.path.islink(fpath) or not os.path.isfile(fpath):
                continue
            try:
                sz = os.path.getsize(fpath)
                if 6 <= sz <= 300:
                    raw = open(fpath, "rb").read()
                    if b"\x00" not in raw:
                        m = pat.match(raw.decode("utf-8", errors="ignore").strip())
                        if m:
                            os.remove(fpath)
                            os.symlink(m.group(1), fpath)
                            fixed += 1
            except Exception:
                pass
print(f"  Converted {fixed} INPUT(...) stubs to POSIX symlinks.")
EOF
  sudo ldconfig 2>/dev/null || true
else
  echo "  GTK3 ($(pkg-config --modversion gtk+-3.0)) & WebKit2GTK ($(pkg-config --modversion webkit2gtk-4.1)) already configured."
fi

echo "[4/4] Environment summary:"
echo "  zig:          $(zig version)"
echo "  rustc:        $(rustc --version)"
echo "  cargo:        $(cargo --version)"
echo "  rustfmt:      $(rustfmt --version)"
echo "  clippy:       $(cargo clippy --version)"
echo "  pkg-config:   $(pkg-config --version)"
echo "  gtk+-3.0:     $(pkg-config --modversion gtk+-3.0)"
echo "  webkit2gtk:   $(pkg-config --modversion webkit2gtk-4.1)"

if [[ "$VERIFY" == "1" ]]; then
  echo "Running end-to-end Zig + Rust FFI + GTK3/WebKit2GTK build & link verification..."
  VDIR="${WORK_DIR}/verify"
  mkdir -p "${VDIR}/src"
  cat << 'EOF' > "${VDIR}/c_headers.h"
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
EOF
  cat << 'EOF' > "${VDIR}/build.zig"
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("c_headers.h"),
        .target = target,
        .optimize = optimize,
    });
    const cflags_raw = b.run(&.{ "pkg-config", "--cflags-only-I", "gtk+-3.0", "webkit2gtk-4.1" });
    var it = std.mem.tokenizeAny(u8, cflags_raw, " \t\r\n");
    while (it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I")) tc.addSystemIncludePath(.{ .cwd_relative = flag[2..] });
    }
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("c", tc.createModule());
    mod.linkSystemLibrary("gtk+-3.0", .{});
    mod.linkSystemLibrary("webkit2gtk-4.1", .{});
    mod.linkSystemLibrary("gcc_s", .{});
    mod.addObjectFile(b.path("rust_ffi/target/release/librust_ffi.a"));
    const exe = b.addExecutable(.{ .name = "verify", .root_module = mod });
    const run_cmd = b.addRunArtifact(exe);
    b.step("run", "Run").dependOn(&run_cmd.step);
}
EOF
  cat << 'EOF' > "${VDIR}/src/main.zig"
const std = @import("std");
const c = @import("c");
extern fn rust_add(a: i32, b: i32) callconv(.c) i32;
pub fn main() !void {
    std.debug.print("  Verified OK: GTK={d}.{d}, WebKit2GTK={d}.{d}, RustFFI={d}\n", .{
        c.gtk_get_major_version(),
        c.gtk_get_minor_version(),
        c.webkit_get_major_version(),
        c.webkit_get_minor_version(),
        rust_add(20, 22),
    });
}
EOF
  cargo init --lib --quiet "${VDIR}/rust_ffi"
  cat << 'EOF' > "${VDIR}/rust_ffi/Cargo.toml"
[package]
name = "rust_ffi"
version = "0.1.0"
edition = "2024"
[lib]
crate-type = ["staticlib"]
EOF
  cat << 'EOF' > "${VDIR}/rust_ffi/src/lib.rs"
#[unsafe(no_mangle)]
pub extern "C" fn rust_add(a: i32, b: i32) -> i32 { a + b }
EOF
  cargo build --release --quiet --manifest-path "${VDIR}/rust_ffi/Cargo.toml"
  zig build run --build-file "${VDIR}/build.zig"
fi
