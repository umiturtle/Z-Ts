#!/usr/bin/env bash
set -euo pipefail

# Z-Ts Modular Toolchain & Sysroot Bootstrap Script
#
# Arena chat sandboxes start with a fresh container filesystem on every new chat/branch.
# Install ONLY the profile needed for your current task:
#
#   bash scripts/setup-toolchains.sh                # Minimal (default): Zig 0.17.0 only (~3.5s)
#   bash scripts/setup-toolchains.sh --submodules   # Also init shallow vendor/{tauri,wry,tao} (~3s)
#   bash scripts/setup-toolchains.sh --sysroot      # Also install Debian 12 GTK3/WebKit2GTK sysroot (~8s)
#   bash scripts/setup-toolchains.sh --rust         # Also install Rust 1.99.0 + rustfmt + clippy (~8s)
#   bash scripts/setup-toolchains.sh --all          # Install everything above
#   bash scripts/setup-toolchains.sh --verify       # Fast cold-cache C-ABI GTK3 + WebKit2GTK + Rust FFI link test (~5s)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG_VERSION="${ZIG_VERSION:-0.17.0}"
RUST_VERSION="${RUST_VERSION:-1.99.0}"
RUST_ROOT="${RUST_ROOT:-/home/user/.local/toolchains/rust}"

WANT_SUBMODULES=0
WANT_SYSROOT=0
WANT_RUST=0
WANT_VERIFY=0
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --minimal) ;;
    --submodules) WANT_SUBMODULES=1 ;;
    --sysroot) WANT_SYSROOT=1 ;;
    --rust) WANT_RUST=1 ;;
    --all) WANT_SUBMODULES=1; WANT_SYSROOT=1; WANT_RUST=1 ;;
    --verify) WANT_SYSROOT=1; WANT_RUST=1; WANT_VERIFY=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '3,13p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (use --help)" >&2
      exit 1
      ;;
  esac
done

WORK_DIR="$(mktemp -d /tmp/zts-setup.XXXXXX)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "[setup] Ensuring Zig ${ZIG_VERSION}..."
if [[ "$FORCE" == "1" ]]; then
  rm -rf "/tmp/zts-toolchains/zig-${ZIG_VERSION}"
  sudo rm -f /usr/local/bin/zig 2>/dev/null || true
fi
"${REPO_ROOT}/zigw" version >/dev/null
echo "  zig: $("${REPO_ROOT}/zigw" version) (bundled LLVM/Clang: $("${REPO_ROOT}/zigw" cc --version | head -n 1))"

if [[ "$WANT_SUBMODULES" == "1" ]]; then
  echo "[setup] Checking upstream submodules (vendor/tauri, vendor/wry, vendor/tao)..."
  if [[ ! -f "${REPO_ROOT}/vendor/tauri/Cargo.toml" || ! -f "${REPO_ROOT}/vendor/wry/Cargo.toml" || ! -f "${REPO_ROOT}/vendor/tao/Cargo.toml" ]]; then
    git -C "$REPO_ROOT" submodule update --init --depth 1
  fi
  echo "  submodules ready."
fi

if [[ "$WANT_RUST" == "1" ]]; then
  echo "[setup] Checking Rust ${RUST_VERSION}..."
  CURRENT_RUSTC="$(rustc --version 2>/dev/null | awk '{print $2}' || true)"
  if [[ "$FORCE" == "1" || "$CURRENT_RUSTC" != "$RUST_VERSION" ]]; then
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
    meta = json.loads(urllib.request.urlopen(url, timeout=20).read())
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
  fi
  echo "  rustc: $(rustc --version) / $(cargo --version)"
fi

if [[ "$WANT_SYSROOT" == "1" ]]; then
  echo "[setup] Checking Debian 12 GTK3 / WebKit2GTK Sysroot..."
  if [[ "$FORCE" == "1" ]] || ! pkg-config --exists gtk+-3.0 webkit2gtk-4.1 2>/dev/null; then
    python3 - "$WORK_DIR" << 'EOF'
import json, os, sys, tarfile, urllib.request

work_dir = sys.argv[1]
url = "https://registry.npmjs.org/@toolchain-bin%2fsysroot-linux-x64"
meta = json.loads(urllib.request.urlopen(url, timeout=20).read())
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

    # Convert GNU ld INPUT(...) linker stubs into real POSIX symlinks for ldconfig & Zig linker
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
  fi
  echo "  gtk+-3.0: $(pkg-config --modversion gtk+-3.0) | webkit2gtk-4.1: $(pkg-config --modversion webkit2gtk-4.1)"
fi

if [[ "$WANT_VERIFY" == "1" ]]; then
  echo "[verify] Building & running fast direct 'zig build-exe' GTK3 + WebKit2GTK + Rust FFI smoke test..."
  VDIR="${WORK_DIR}/verify"
  mkdir -p "$VDIR"
  cat << 'EOF' > "${VDIR}/main.zig"
const std = @import("std");
extern fn gtk_get_major_version() callconv(.c) c_uint;
extern fn gtk_get_minor_version() callconv(.c) c_uint;
extern fn webkit_get_major_version() callconv(.c) c_uint;
extern fn webkit_get_minor_version() callconv(.c) c_uint;
extern fn rust_add(a: i32, b: i32) callconv(.c) i32;
pub fn main() void {
    std.debug.print("  Verified OK: GTK={d}.{d}, WebKit2GTK={d}.{d}, RustFFI={d}\n", .{
        gtk_get_major_version(),
        gtk_get_minor_version(),
        webkit_get_major_version(),
        webkit_get_minor_version(),
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
  "${REPO_ROOT}/zigw" build-exe "${VDIR}/main.zig" \
    "${VDIR}/rust_ffi/target/release/librust_ffi.a" \
    -lc -L/usr/lib/x86_64-linux-gnu -lgtk-3 -lwebkit2gtk-4.1 -lgcc_s \
    -femit-bin="${VDIR}/verify_bin"
  "${VDIR}/verify_bin"
fi
