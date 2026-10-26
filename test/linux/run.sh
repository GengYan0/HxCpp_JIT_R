#!/usr/bin/env bash
set -u

cd "$(dirname "$0")"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

say "=== cxxlive linux check ==="

command -v haxe >/dev/null 2>&1 || die "haxe not on PATH"
command -v haxelib >/dev/null 2>&1 || die "haxelib not on PATH"

CXX=""
for c in g++ clang++; do
  if command -v "$c" >/dev/null 2>&1; then CXX="$c"; break; fi
done
[ -n "$CXX" ] || die "no g++ or clang++ on PATH"
say "compiler: $CXX ($($CXX --version | head -1))"

say "haxe: $(haxe --version)"

if ! haxelib list 2>/dev/null | grep -q "hxcpp_jit_r"; then
  say "registering local library"
  haxelib dev hxcpp_jit_r "$(cd ../.. && pwd)" || die "haxelib dev failed"
fi

say ""
say "--- build ---"
haxe build-linux.hxml || die "build failed"

say ""
say "--- run ---"
"./bin/Main" || die "tests failed"

say ""
say "--- artifacts ---"
ls -la bin/test-report.txt 2>/dev/null || true
ls -la bin/jitcache 2>/dev/null | head -5 || true

say ""
say "done"
