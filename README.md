# hxcpp_jit_r

Beta 0.0.10

Compile and execute native C++ inside a running hxcpp application. Source is compiled into a dynamic library at runtime and loaded; exported functions are called through a flat C ABI.

No engine source changes, no relinking the executable, no `.cpp` entries in the project file.

---

## Features

- Runtime compilation of C++ source into a `.dll` / `.so`, then load and call it
- Flat C ABI: compiled code includes no hxcpp headers, only a small C header
- Automatic signature scanning: plain C++ functions are callable without writing macros
- `const char*` and `std::string` parameters over a dedicated UTF-8 slot table
- Zero-compile reads and writes for globals, struct fields and array elements
- Bulk array transfer for large buffers (`readDoubles`, `writeDoubles`, `readRaw`, `writeRaw`)
- `JitSession` keeps numeric, struct and array state across recompiles
- Hot reload with a three-frame deferred unload, plus `Jit.watch` file polling
- SEH guard around every call; `callFast` skips it for trusted code
- Content-addressed build cache with `exportPack` / `importPack` for machines without a compiler
- Manual image mapping as an alternative to `LoadLibrary`
- Asynchronous compilation with a concurrency gate
- Diagnostics mapped back to the original source line

---

## Requirements

| Item | Version |
|---|---|
| Haxe | 4.2+ |
| hxcpp | 4.3+ |
| Windows | MSVC 2019/2022 or clang-cl, x64 / x86 |
| Linux | g++ or clang++, `-shared -fPIC` |

On Windows `cl.exe` and the Windows SDK must be reachable. The first call scans installed MSVC and SDK directories, or reuses the current `INCLUDE` / `LIB`.

---

## Install

```bash
haxelib dev hxcpp_jit_r /path/to/hxcpp_jit_r
```

```xml
<haxelib name="hxcpp_jit_r"/>
```

Optional, to include the package and run a self check at boot:

```xml
<haxeflag name="--macro hxcpp_jit_r.JitMacro.probe()" />
```

`lime` only reads `<haxeflag name="...">`. The plural `<haxeflags>` is silently ignored.

---

## Quick start

```haxe
import hxcpp_jit_r.Jit;

Jit.setup();

var m = Jit.compile("math", '
double add(double a, double b) { return a + b; }
double fib(double n) {
  double a = 0, b = 1;
  for (int i = 0; i < (int)n; i++) { double t = a + b; a = b; b = t; }
  return a;
}
');

if (!m.ok) {
  Sys.println(m.report());
  return;
}

m.callAuto("add", [2, 3]);   // 5
m.callAuto("fib", [30]);     // 832040
```

---

## How it works

```
source -> cl.exe /LD -> mod.dll -> load -> function pointer -> call
```

Two load modes:

1. `loadlib` (default): `LoadLibrary` + `GetProcAddress`
2. `manual`: parse the image, allocate, map sections, apply relocations, resolve imports, build TLS, register unwind data, call `DllMain` — without the system loader

The artifact is a standalone library. Only POD values and read-only byte strings cross the boundary, so there is no object model, garbage collector or exception model coupling.

---

## C++ side

Macros for hand-written exports:

| Macro | Meaning |
|---|---|
| `RJIT(name) { ... }` | Define export `rjit_name` |
| `RJIT_A0` .. `RJIT_A5` | First six numeric arguments |
| `RJIT_ARG(i)` | Guarded argument access |
| `RJIT_N` | Actual numeric argument count |
| `RJIT_S0` .. `RJIT_S3` | String arguments (`const char*`, UTF-8) |
| `RJIT_SARG(i)` / `RJIT_SLEN(i)` | Guarded string value / byte length |
| `RJIT_LOG(s)` | Write to the host log |
| `RJIT_RETSTR(s)` | Return a string, read back with `callStr` |
| `RJIT_CALL0..3(name, a, b, c)` | Call a bound host function or another export |
| `RJIT_GET(key)` | Read a host variable |
| `RJIT_INIT { return 0; }` | Called after load, non-zero means failure |
| `RJIT_DEINIT { }` | Called before unload |

Macros are optional. Top-level functions are scanned automatically:

```cpp
int counter = 0;
double half(double x) { return x / 2; }
void bump() { counter += 1; }
```

```haxe
m.callAuto("half", [10]);   // 5
m.callAuto("bump", []);
m.getVar("counter");        // 1
```

The standard library, inline assembly, SIMD intrinsics and templates all work. The default is `/MT`, so the library carries its own C runtime.

---

## Haxe API

### Jit

| Method | Meaning |
|---|---|
| `Jit.setup(?options):Bool` | Detect the toolchain and prepare the cache |
| `Jit.compile(name, src, ?options):JitModule` | Compile synchronously, skip if cached |
| `Jit.compileAsync(name, src, cb, ?options)` | Queue a background build |
| `Jit.compileFile(path, ?name, ?options)` | Compile from a file |
| `Jit.reload(name, ?newSrc)` | Force a rebuild |
| `Jit.watch(path, ?name, ?onReload):Bool` | Poll the file and reload on change |
| `Jit.unwatch(path):Bool` / `Jit.watchedFiles()` | Manage watched files |
| `Jit.eval(code):Float` | One-off expression |
| `Jit.prefetch()` | Build every registered module into the cache |
| `Jit.exportPack(dir):Int` / `Jit.importPack(dir):Int` | Package and restore the cache |
| `Jit.packInfo(dir):String` | Validate a package |
| `Jit.get(name)` / `Jit.all()` / `Jit.dispose(name)` | Module management |
| `Jit.tick()` | Per-frame driver: async results, deferred unload, file polling |
| `Jit.hook()` | Attach `tick` to the host frame event |
| `Jit.bind(name, fn)` / `Jit.unbind(name)` | Register host callbacks |
| `Jit.stats()` / `Jit.purge()` / `Jit.sweep(keep)` | Status and cleanup |
| `Jit.selfTest():String` | Built-in self check |

### JitModule

| Member | Meaning |
|---|---|
| `ok` / `dll` / `image` / `symbols` / `ms` / `cached` / `diag` / `log` | State |
| `call(name, a0..a5):Float` | Six `double` arguments, guarded |
| `callFast(name, a0..a5):Float` | Same, without the SEH guard |
| `callA(name, args)` | Variable argument count |
| `callAuto(name, args, ?strs)` | Convert by scanned signature |
| `callSig(name, sig, args, ?strs)` | Explicit signature, for overloads |
| `callStr(name, args):String` | Read the `RJIT_RETSTR` value |
| `get(path)` / `set(path, v)` | `"n"`, `"p.x"`, `"arr[2]"` |
| `getVar` / `setVar` | Top-level numeric variables |
| `getField` / `setField` / `getIndex` / `setIndex` | Explicit access |
| `readDoubles` / `writeDoubles` / `readInts` / `writeInts` | Bulk array transfer |
| `readRaw` / `writeRaw` / `arrayAddress` / `elemSize` | Raw buffer access |
| `kindOf(name)` / `fieldsOf(name)` / `arraySize(name)` | Variable info |
| `signature(name)` / `signatures(name)` / `hasSig(sig)` | Signature info |
| `address(name)` / `ptr(name)` | Function address / `JitPtr` |
| `has(name)` / `report()` / `dispose()` | Misc |

### JitSession

| Method | Meaning |
|---|---|
| `eval(code):Bool` | Append source and rebuild; keeps the previous module on failure |
| `evalFile(path)` / `redeclare(code)` | Append from file / replace everything |
| `call(fn, args, ?strs)` | Call a function |
| `get(path)` / `set(path, v)` | Read or write any supported path |
| `snapshot()` / `restore(vals)` | Manual state save and restore |
| `vars()` / `funcs()` / `dispose()` | Introspection and cleanup |

---

## Examples

### Numeric functions

```haxe
var m = Jit.compile("calc", '
double clamp(double v, double lo, double hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}
double dot(double ax, double ay, double bx, double by) {
  return ax * bx + ay * by;
}
');

m.callAuto("clamp", [1.5, 0, 1]);        // 1
m.callAuto("dot", [1, 2, 3, 4]);         // 11
```

### Strings

```haxe
var m = Jit.compile("text", '
int length(const char* s) { return (int)strlen(s); }
int joined(std::string a, std::string b) { return (int)(a.size() + b.size()); }
char head(std::string s) { return s.empty() ? 0 : s[0]; }
');

m.callAuto("length", [], ["hello"]);      // 5
m.callAuto("length", [], ["caf\u00e9"]);   // 5, UTF-8 bytes
m.callAuto("joined", [], ["abc", "de"]);  // 5
m.callAuto("head", [], ["A"]);            // 65
```

If the source uses `std::string` without `#include <string>`, one line is prepended and the reported line numbers are shifted back.

### Structs and arrays

```haxe
var m = Jit.compile("world", '
struct Vec2 { double x; double y; };
struct Actor { int hp; int mp; double speed; };
Vec2 camera;
Actor player;
double samples[8];
');

m.set("camera.x", 120);
m.get("camera.x");        // 120

m.set("player.hp", 80);
m.get("player.hp");       // 80

m.set("samples[3]", 0.25);
m.get("samples[3]");      // 0.25
m.get("samples[99]");     // 0, out of range
m.get("missing.x");       // NaN
```

`kindOf("camera")` returns `"struct"`, `fieldsOf("camera")` returns `["x","y"]`, `kindOf("samples")` returns `"array"`, `arraySize("samples")` returns `8`.

### Bulk transfer

```haxe
var m = Jit.compile("bulk", '
double samples[256];
double sum_all() { double s = 0; for (int i = 0; i < 256; i++) s += samples[i]; return s; }
');

m.writeDoubles("samples", [for (i in 0...256) i * 0.5]);
m.readDoubles("samples")[10];    // 5
m.callAuto("sum_all", []);       // 16320

m.writeRaw("samples", myBytes);  // any layout, clamped to the array size
m.arrayAddress("samples");       // base address, for custom marshalling
```

One `memcpy` per call instead of one cross-boundary call per element.

### Hand-written exports

```haxe
var m = Jit.compile("native", '
RJIT(greet) {
  char buf[64];
  snprintf(buf, sizeof(buf), "n=%d a0=%.1f", RJIT_N, RJIT_A0);
  RJIT_RETSTR(buf);
  return 0.0;
}
RJIT(sum_to) {
  double s = 0;
  for (int i = 1; i <= (int)RJIT_A0; i++) s += i;
  return s;
}
');

m.callStr("greet", [7]);    // "n=2 a0=7.0"
m.call("sum_to", 100);      // 5050
```

### Host callbacks

```haxe
Jit.bind("host_log", function(a:Float, b:Float, c:Float, d:Float):Float {
  Sys.println("[host] " + a);
  return 0;
});

var m = Jit.compile("cb", '
RJIT(emit) {
  double r = RJIT_CALL1("host_log", 42.0);
  return r + 1.0;
}
');
```

### Session

```haxe
var s = new JitSession("script");
s.eval("int hp = 100;\ndouble mana = 30.0;");

s.eval("int damage(int n) { hp -= n; return hp; }");
s.call("damage", [15]);       // 85

s.eval("int heal(int n) { hp += n; return hp; }");
s.get("hp");                  // 85, state survives the rebuild
s.call("heal", [5]);          // 90
```

Each `eval` is a full rebuild. State is read before compiling and written back after loading.

### File watch

```haxe
Jit.watch("mods/fast/core.cpp");
Jit.watchEvery = 30;          // poll every 30 ticks

// in the frame loop
Jit.tick();                   // reloads when the file content changes
```

Polling compares the file content, not the timestamp, so it does not depend on filesystem update latency.

### Crash isolation

```haxe
JitHost.onError = function(method, name, msg) {
  Sys.println(method + " / " + name + " : " + msg);
};

var m = Jit.compile("risky", 'double boom(double x) { volatile int* p = 0; *p = 1; return x; }');
m.callAuto("boom", [1]);   // 0, callback fired, process alive
```

### Manual mapping

```haxe
var m = Jit.compile("mod", src, {loader: "manual"});

m.image.manual;        // true
m.image.base;          // load address
m.image.relocCount;    // applied relocations
m.image.imports;       // resolved dependencies
```

A manually mapped module is not in the system module list; `GetModuleHandle` cannot find it and `FreeLibrary` does not free it. Unload through `Jit.dispose`. For threads that touch TLS variables inside the library, call `JitLoader.bindThread()` on that thread.

### Distributing a build cache

```haxe
// build machine
Jit.setup({cache: "jitcache"});
Jit.compile("mod_a", srcA);
Jit.compile("mod_b", srcB);
Jit.exportPack("dist/jitcache");
```

```
dist/jitcache/
  rjit_abi.h
  manifest.json
  <key>/mod.dll
  <key>/mod.cpp
```

```haxe
// target machine, no compiler
Jit.setup({cache: "jitcache"});
Jit.importPack("dist/jitcache");
Jit.compile("mod_a", srcA);   // cache hit, 2ms
```

When no toolchain is found `Jit.ready` is `false`, but `compile` still looks for a cached artifact. `importPack` returns `-1` when the ABI, codegen version or platform does not match.

### Compile errors

```haxe
var m = Jit.compile("bad", 'double f(int x) { return x + ; }');
if (!m.ok) {
  for (d in m.diag) Sys.println("line " + d.line + ": " + d.msg);
}
```

`d.line` is the line in the user source; prepended lines are compensated.

---

## Type codes

| C++ | Code | C++ | Code |
|---|---|---|---|
| `void` | `v` | `int` | `i` |
| `double` | `d` | `unsigned int` | `u` |
| `float` | `f` | `long long` | `l` |
| `bool` | `b` | `void*` / `T*` | `p` |
| `char` | `c` | `const char*` | `s` |
| `short` | `h` | `std::string` | `S` |

Signatures use `returnCode(argumentCodes)`: `d(dd)`, `i(is)`, `i(SS)`, `v()`.

```haxe
m.signature("clamp");            // "d(ddd)"
m.callSig("area", "i(i)", [3]);  // pick one overload
```

Up to six numeric arguments and four string arguments.

---

## Configuration

```haxe
Jit.setup({
  cache: "jitcache",   // cache directory
  opt: "O2",           // Od / O1 / O2 / Ox
  std: "c++17",        // language standard
  flags: [],           // extra compiler flags
  backend: "auto",     // auto / msvc / clang / gcc
  loader: "loadlib"    // loadlib / manual / auto
});
```

| Global | Default | Meaning |
|---|---|---|
| `Jit.maxParallel` | `2` | Concurrent compiler processes |
| `Jit.watchEvery` | `30` | Ticks between file polls |
| `Jit.autoSweepEvery` | `0` | Sweep the cache every N builds, 0 disables |
| `Jit.autoSweepKeep` | `24` | Directories kept by a sweep |
| `Jit.verbose` | `true` | Build logging |
| `Jit.debug` | `false` | Detailed tracing |
| `JitCompiler.timeoutMs` | `90000` | Single build timeout |

---

## Performance

| Item | Value |
|---|---|
| First build (includes precompiled header) | 500-900ms |
| Rebuild | ~300ms, weakly dependent on function count |
| Cache hit load | 2-3ms |
| Single boundary call | 0.026-0.14us |
| Manual mapping, 110KB image | under 5ms |

Time goes into compiler process startup and linking, not into the amount of code.

---

## Limits

- Up to six numeric and four string arguments per call
- Return values are numeric, pointer or `void`; strings go through `RJIT_RETSTR` / `callStr`
- Structs are passed by address, not by value
- C++ default arguments are not filled in
- Overloads resolve to the first match; use `callSig` for the others
- Every guarded call costs an indirect jump; `callFast` removes the SEH guard but also removes crash containment
- Compilation needs a local compiler; target machines fall back to the cache
- SEH catches hardware exceptions only; C++ exceptions across the boundary are undefined
- Build timeout terminates the compiler process
- Struct accessors cover first-level numeric fields; nested structs and pointer members need a helper function
- Manual mapping implements the Windows PE format only; ELF uses the system loader
- Changing the ABI header layout requires clearing the host precompiled header and rebuilding

---

## Testing

`test/` is a standalone console project with 181 assertions.

```
cd test
haxe build.hxml
bin/Main.exe
```

Covers: core calls, diagnostic line numbers, expression offset, automatic signatures, string arguments, struct and array access, bulk transfer, session state, crash isolation and error callback, pointer handle, overload dispatch, concurrency gate, hot reload, file watch, large source, cache hit, cache packaging and import, compiler-less mode, manual mapping and unload, call throughput.

Linux:

```
bash test/linux/run.sh
```

CI runs the same suite on `windows-latest` for every push and pull request.

---

## Layout

```
src/hxcpp_jit_r/
  Jit.hx            Entry point: setup / compile / reload / watch / pack
  JitModule.hx      Module handle: calls, signatures, variable access
  JitSession.hx     Session: cumulative source and state restore
  JitScan.hx        Source scanning: signatures, globals, structs, arrays
  JitCodegen.hx     Generates entry points, dispatchers, accessors
  JitLoader.hx      Image parsing and manual mapping
  JitPack.hx        Cache packaging and validation
  JitPtr.hx         Pointer handle
  JitCompiler.hx    Compiler invocation, precompiled header, diagnostics
  JitToolchain.hx   Toolchain detection and environment injection
  JitCache.hx       Hashing, directories, cleanup
  JitAbi.hx         ABI header contents
  JitNative.hx      System primitives and host callback table
  JitHost.hx        Callback registry, variable table, string slots
  JitBoot.hx        Optional self check entry
  JitMacro.hx       Build-time macro
```

---

## License

MIT
