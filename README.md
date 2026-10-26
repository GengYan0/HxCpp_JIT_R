# HxCpp_JIT_R

Beta 0.0.14

Compile and call native C++ while your application is running. Hand it a source string, get a module back, call its functions like any Haxe method.

Behind the call the source goes into a cache directory, is compiled into a shared library, loaded, and invoked through a small flat C ABI generated for you.

---

## Features

- Runtime compilation of C++ source into a `.dll` / `.so`, then load and call it
- Flat C ABI: compiled code includes no hxcpp headers, only a small C header
- Automatic signature scanning: plain C++ functions are callable without writing macros
- `const char*` and `std::string` parameters over a dedicated UTF-8 slot table
- `std::string` results read back with `callStr`
- Pointer variables: read, write, repoint, and `&name` for the address
- Pointer and `const char*` members of structs, walked with `JitPtr` and decoded with `str()`
- `const char*` results read straight back by `callStr`
- Zero-compile reads and writes for globals, struct fields and array elements
- Handles resolved once at load, so the call path never reaches the symbol table
- Struct arrays and nested fields: `pts[2].x`, `box.pos.x`, any depth up to three
- Expression evaluation against live module state: `m.expr("p.x + p.y")`
- Bound handles: `m.bind(name)` resolves the symbol and signature once, then calls at 0.015 us
- Multiple translation units per module with local `#include` search paths, including their globals
- Bulk array transfer for large buffers (`readDoubles`, `writeDoubles`, `readRaw`, `writeRaw`)
- `JitSession` keeps numeric, struct and array state across recompiles
- Hot reload with a three-frame deferred unload, plus `Jit.watch` file polling
- SEH guard around every call; `callFast` skips it for trusted code
- Content-addressed build cache with `exportPack` / `importPack` for machines without a compiler
- Manual image mapping as an alternative to `LoadLibrary`, with the same control on Linux over ELF
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
haxelib dev hxcpp_jit_r /path/to/HxCpp_JIT_R
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
| `Jit.compileFiles(name, mainPath, otherPaths, ?options)` | Compile several translation units into one module |
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
| `callAuto(name, args, ?strs)` | Convert by scanned signature, picking the overload by argument count |
| `callSig(name, sig, args, ?strs)` | Explicit signature, for overloads |
| `callStr(name, args, ?strs):String` | Read an `RJIT_RETSTR` or `std::string` result |
| `bind(name, ?sig):JitFn` | Resolve the symbol once, then call through the handle |
| `expr(code):Float` | Evaluate an expression against live module state |
| `get(path)` / `set(path, v)` | `"n"`, `"&n"`, `"p.x"`, `"arr[2]"`, `"pts[2].x"`, `"box.pos.x"` |
| `str(path)` | Read a `const char*` member at the address the path holds |
| `addrOf(name)` | Address of a variable |
| `getVar` / `setVar` | Top-level numeric and pointer variables |
| `getField` / `setField` / `getIndex` / `setIndex` | Explicit access |
| `getFieldPath` / `setFieldPath` / `getElemField` / `setElemField` | Nested paths and struct array elements |
| `readDoubles` / `writeDoubles` / `readInts` / `writeInts` | Bulk array transfer |
| `readRaw` / `writeRaw` / `arrayAddress` / `elemSize` | Raw buffer access |
| `kindOf(name)` / `fieldsOf(name)` / `leafFieldsOf(name)` / `arraySize(name)` | Variable info |
| `signature(name)` / `signatures(name)` / `hasSig(sig)` | Signature info |
| `address(name)` / `ptr(name)` | Function address / `JitPtr` |
| `pick(name, nums, strs)` / `warm()` | Overload choice and cache prefill |
| `has(name)` / `report()` / `dispose()` | Misc |

### JitPtr

| Member | Meaning |
|---|---|
| `address` / `isNull()` | Raw address and null check |
| `valid()` | Address is non-null and readable |
| `offset(delta)` | New handle at `address + delta` |
| `readStr(max)` | Read a null-terminated string at the address |
| `readF64(at)` / `readF32(at)` | Read a `double` / `float` |
| `readI32(at)` / `readU16(at)` / `readU8(at)` | Read integers |
| `writeF64(v, at)` / `writeF32(v, at)` / `writeI32(v, at)` | Write |
| `readBytes(len, at)` / `writeBytes(bytes, at)` | Raw buffer transfer |

### JitFn

| Member | Meaning |
|---|---|
| `name` / `sig` / `returnsString` | What was bound |
| `valid()` | Both the address and the dispatcher resolved |
| `call(a0..a5):Float` | Fixed argument call |
| `callA(args, ?strs):Float` | Variable argument call |
| `callStr(args, ?strs):String` | String result |
| `address():Float` | Raw function address |

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

A function that returns `std::string` is called the same way and read with `callStr`:

```haxe
var m = Jit.compile("text", 'std::string greet(std::string name) { return "Hello, " + name; }');

m.callStr("greet", [], ["Haxe"]);   // "Hello, Haxe"
m.callAuto("greet", [], ["Haxe"]);  // 0, the result is a string, use callStr
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

### Struct arrays and nested fields

```haxe
var m = Jit.compile("entities", '
struct Vec2 { double x; double y; };
struct Body { Vec2 pos; Vec2 vel; int hp; };
Vec2 trail[64];
Body actors[8];
');

m.get("trail[3].y");        // any index, bounds checked in native code
m.set("trail[3].y", 12.5);
m.get("actors[2].pos.x");   // nested struct inside an array
m.set("actors[2].hp", 100);
m.get("actors[99].hp");     // 0, out of range

m.leafFieldsOf("actors");   // ["pos.x","pos.y","vel.x","vel.y","hp"]
m.elemSize("trail");        // 16, sizeof(Vec2)
```

Field paths resolve through any struct nesting up to three levels. Every accessor is generated for the leaf fields only, so the index and the bounds check stay in native code and nothing is interpreted per call.

Pointer and `const char*` members come back as addresses, so a linked structure can be walked from Haxe:

```haxe
var m = Jit.compile("list", '
struct Node { double v; Node* next; const char* label; };
Node head; Node tail;
void build() { head.v = 1; tail.v = 2; head.next = &tail; tail.next = 0; head.label = "head"; tail.label = "tail"; }
');

m.callAuto("build", []);
m.get("head.next");                                 // address of tail
new JitPtr(m.get("head.next")).readF64();           // 2, first member
m.str("head.label");                                // "head"
m.str("tail.label");                                // "tail"
m.get("tail.next");                                 // 0
m.set("tail.next", m.get("&head"));                 // repoint
```

A function that returns `const char*` is callable like any other and read through the same path:

```haxe
m.callStr("label_of", [2]);
```

### Expressions

```haxe
var m = Jit.compile("physics", '
double ax = 3; double ay = 4;
double speed = 12;
');

m.expr("ax + ay");                 // 7
m.expr("sqrt(ax*ax + ay*ay)");     // 5
m.expr("(ax + ay) * 2");           // 14
m.expr("max(ax, ay) + min(ax, ay)"); // 7
m.expr("speed > 10 ? 1 : 0");      // 1
m.get("ax + ay");                  // 7, paths and expressions share one entry point
```

Operators: `+ - * / % ^`, comparisons, `&& || !`, ternary. Functions: `abs sqrt floor ceil round trunc sign min max pow sin cos tan asin acos atan atan2 exp log log2 log10 hypot mod clamp lerp deg rad`. Constants: `pi`, `e`. Unknown names evaluate to `NaN` instead of throwing.

Evaluation reads the live module state through the generated accessors, so no compilation happens per expression.

### Bound handles

```haxe
var m = Jit.compile("maths", '
double add(double a, double b) { return a + b; }
double scale(double v, double k) { return v * k; }
');

var add = m.bind("add");
add.valid();          // true
add.call(2, 3);       // 5
add.sig;              // "d(dd)"

var k = m.bind("scale", "d(dd)");   // explicit signature for overloads
k.callA([4, 2.5]);                  // 10

m.bind("nope").valid();             // false
```

Binding resolves the address stub and the dispatcher once; later calls skip both map lookups. Measured on the console suite: `0.015 us` per call against `0.03 us` for `callAuto`.

### Multiple translation units

```haxe
// shared.h
inline double sq(double v) { return v * v; }

// main.cpp
#include "shared.h"
double quad(double v) { return sq(v) * 2; }

// extra.cpp
#include "shared.h"
double twice(double v) { return v * 2; }

// Haxe
var m = Jit.compileFiles("mixed", "cpp/main.cpp", ["cpp/extra.cpp"], {includes: ["cpp"]});
m.callAuto("quad", [3]);     // 18
m.callAuto("twice", [4]);    // 8, declared automatically
```

The main file keeps its globals and state; the other files are compiled and linked into the same image. Their functions are declared in the generated wrapper, so they stay callable without writing anything by hand. A file listed but missing makes the module fail with `E_NOFILE` instead of silently dropping it.

Globals defined in a secondary file are visible too, as long as they have external linkage:

```haxe
// extra.cpp
struct P { double x; double y; };
double counter = 5;
int hits[3] = {1, 2, 3};
P anchor = {7, 8};

// Haxe
m.get("counter");      // 5
m.set("counter", 9);
m.get("hits[1]");      // 2
m.get("anchor.y");     // 8
```

`const` and `static` globals stay private to their unit, and a struct-typed one needs the struct declared in the main unit so the generated declaration compiles.

Functions in secondary files must have external linkage; `static` and `inline` definitions stay local to their unit.

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

### Pointers

```haxe
var m = Jit.compile("ptr", '
int value = 5;
int other = 9;
int* ptr = &value;
int read(int* p) { return *p; }
int write(int* p, int v) { *p = v; return *p; }
');

var a = m.get("ptr");              // address of value
m.get("&value") == a;              // same address, &name works on any variable
m.callAuto("read", [a]);           // 5
m.callAuto("write", [a, 42]);      // 42
m.get("value");                    // 42

m.set("ptr", m.get("&other"));     // repoint
m.callAuto("read", [m.get("ptr")]); // 9
m.set("ptr", 0);                   // null
```

A pointer is an address held in a `Float`. Nothing keeps the target alive, so using an address after the variable is gone is undefined, as in C++. `kindOf("ptr")` returns `"ptr"`.

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

The same option on Linux maps the ELF image instead of calling `dlopen`: program headers are copied, relocations are applied from the dynamic section, and `DT_INIT`, `DT_INIT_ARRAY`, `DT_FINI` and `DT_FINI_ARRAY` run in order. ELF thread-local storage is left to the system loader, so keep `loader: "loadlib"` for libraries that declare TLS.

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

Signatures use `returnCode(argumentCodes)`: `d(dd)`, `i(is)`, `i(SS)`, `S(S)`, `v()`.

```haxe
m.signature("clamp");            // "d(ddd)"
m.callSig("area", "i(i)", [3]);  // pick one overload
```

Up to six numeric arguments and four string arguments. Numeric and string arguments may appear in any order;
numeric arguments pack into `a[0..]` in source order and string arguments into `s[0..]` in source order.

```haxe
m.callAuto("sn", [2, 3], ["abcd", "xy"]);  // int sn(std::string a, int m, std::string b, int n)
```

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
| `Jit.autoSweepEvery` | `0` | Sweep the cache every N `tick()` calls, 0 disables |
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
| Bound handle call | 0.015us |
| Manual mapping, 110KB image | under 5ms |

Time goes into compiler process startup and linking, not into the amount of code.

---

## Limits

- Up to six numeric and four string arguments per call
- Return values are numeric or `void`; pointers come back as addresses and `std::string` results go through `callStr`
- Structs are passed by address, not by value
- C++ default arguments are not filled in
- Overloads resolve to the first match; use `callSig` for the others
- Every guarded call costs an indirect jump; `callFast` removes the SEH guard but also removes crash containment
- Compilation needs a local compiler; target machines fall back to the cache
- SEH catches hardware exceptions only; C++ exceptions across the boundary are undefined
- Build timeout terminates the compiler process
- Struct accessors cover leaf fields up to three levels of nesting, including pointer and `const char*` members; `std::string` members need a helper function
- Manual mapping handles PE on Windows and ELF64 on Linux; other formats use the system loader
- Globals in secondary units are exposed, but a struct-typed one needs the struct declared in the main unit
- ELF manual mapping does not process thread-local storage; the system loader does
- Changing the ABI header layout requires clearing the host precompiled header and rebuilding

---

## Testing

`test/` is a standalone console project with 297 assertions.

```
cd test
haxe build.hxml
bin/Main.exe
```

Covers: core calls, diagnostic line numbers, expression offset, automatic signatures, string arguments, string and `RJIT_RETSTR` results, struct and array access, struct arrays and nested fields, pointer and string members, expressions, bound handles, overlapping signatures, multiple translation units and their globals, pointer variables and address-of, bulk transfer, session state including struct arrays, crash isolation and error callback, pointer handle, overload dispatch, concurrency gate, hot reload, file watch, large source, cache hit, cache packaging and import, compiler-less mode, manual mapping and unload, ELF header parsing, call throughput.

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
  JitElf.hx         ELF parsing and manual mapping
  JitPack.hx        Cache packaging and validation
  JitPtr.hx         Pointer handle
  JitFn.hx          Bound function handle
  JitExpr.hx        Expression evaluator over live module state
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
