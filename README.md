# hxcpp_jit_r

**Beta (0.0.9)** — 接口在 1.0 之前可能调整。

在运行中的 hxcpp 应用里编译并执行原生 C++。源码以字符串或文件形式在运行时编译成动态库，装载后按 C 调用约定直接调用导出函数。

不需要改引擎源码，不需要重新链接可执行文件，不需要预先在工程里声明 `.cpp`。

---

## 特性

- 运行时编译：`Jit.compile(name, source)` 把 C++ 源码编成 `.dll` / `.so` 并装载
- 纯 C ABI 边界：被编译的代码不包含任何 hxcpp 头文件，只依赖纯 C 的 `rjit_abi.h`
- 自动签名：扫描源码得到函数签名，普通 C++ 函数（`double f(int, double)`）可直接调用，不需要写宏
- 字符串参数：`const char*` 和 `std::string` 都能作为参数，走独立 UTF-8 槽位
- 状态读写：顶层数值变量、结构体字段、数组元素都能零编译读写
- 会话式脚本：`JitSession` 累积源码，重新编译后变量值自动保留
- 热重载：同一模块强制重编译，旧库延迟 3 帧卸载
- 崩溃隔离：每次跨边界调用都有 SEH 保护，原生代码段错误只返回错误值，宿主进程存活
- 编译缓存：key 由源码与编译选项计算，二次加载 2ms
- 缓存分发：把已编译产物打包，在没有编译器的机器上直接装载
- 手动镜像加载：可绕过 `LoadLibrary`，自行映射段、修正重定位、解析导入表、调用 `DllMain`
- 编译诊断：错误带原始行号，输出按系统代码页解码
- 异步编译：`compileAsync` 加并发闸门，不阻塞主线程

---

## 要求

| 项 | 版本 |
|---|---|
| Haxe | 4.2+ |
| hxcpp | 4.3+ |
| Windows | MSVC 2019/2022 或 clang-cl（x64 / x86） |
| Linux | g++ 或 clang++，`-shared -fPIC` |

Windows 下不需要完整 Visual Studio 交互式环境，但需要 `cl.exe` 与 Windows SDK 可用。首次调用会扫描已安装的 MSVC 和 SDK，或直接使用当前进程已有的 `INCLUDE` / `LIB`。

---

## 安装

```bash
haxelib dev hxcpp_jit_r /path/to/hxcpp_jit_r
```

`Project.xml`：

```xml
<haxelib name="hxcpp_jit_r"/>
```

需要构建期自检时再加一行（可选）：

```xml
<haxeflag name="--macro hxcpp_jit_r.JitMacro.probe()" />
```

`lime` 只识别 `<haxeflag name="...">`，写成 `<haxeflags>` 会被忽略。

---

## 快速开始

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

## 工作原理

```
源码 → cl.exe /LD → mod.dll → 装载 → 函数指针 → 调用
```

装载有两种模式：

1. `loadlib`（默认）：`LoadLibrary` + `GetProcAddress`
2. `manual`：自行解析 PE，`VirtualAlloc` 映射、修重定位、填导入表、建 TLS、注册 `.pdata`、调用 `DllMain`，全程不经过系统加载器

产物是独立动态库，与宿主之间只传递 POD 和只读字节串，不存在对象模型、垃圾回收或异常处理的耦合。

---

## C++ 侧

手写导出函数时使用宏：

| 宏 | 说明 |
|---|---|
| `RJIT(name) { ... }` | 定义导出函数 `rjit_name` |
| `RJIT_A0` .. `RJIT_A5` | 前 6 个数值参数 |
| `RJIT_ARG(i)` | 带越界保护的取参 |
| `RJIT_N` | 实际数值参数个数 |
| `RJIT_S0` .. `RJIT_S3` | 字符串参数（`const char*`，UTF-8） |
| `RJIT_SARG(i)` / `RJIT_SLEN(i)` | 带保护的字符串取值 / 字节长度 |
| `RJIT_LOG(s)` | 输出到宿主日志 |
| `RJIT_RETSTR(s)` | 返回字符串（配合 `callStr` 读取） |
| `RJIT_CALL0..3(name, a, b, c)` | 回调宿主已绑定的函数，或同模块其他导出 |
| `RJIT_GET(key)` | 读取宿主变量 |
| `RJIT_INIT { return 0; }` | 装载后调用，返回非 0 视为失败 |
| `RJIT_DEINIT { }` | 卸载前调用 |

不写宏也可以。顶层函数会被自动扫描并生成调用入口：

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

标准库、内联汇编、SIMD intrinsics、模板都能用。默认 `/MT`，动态库自带 C 运行时。

---

## Haxe 侧 API

### Jit

| 方法 | 说明 |
|---|---|
| `Jit.setup(?options):Bool` | 探测工具链，准备缓存目录 |
| `Jit.compile(name, src, ?options):JitModule` | 同步编译，命中缓存则跳过编译 |
| `Jit.compileAsync(name, src, cb, ?options)` | 入队后台编译，受 `maxParallel` 限制 |
| `Jit.compileFile(path, ?name, ?options)` | 从文件编译 |
| `Jit.reload(name, ?newSrc)` | 强制重编译 |
| `Jit.eval(code):Float` | 单次表达式 |
| `Jit.prefetch()` | 编译所有已注册模块到缓存 |
| `Jit.exportPack(dir):Int` | 导出缓存包 |
| `Jit.importPack(dir):Int` | 导入缓存包，返回文件数，`-1` 表示版本不匹配 |
| `Jit.packInfo(dir):String` | 校验缓存包 |
| `Jit.get(name)` / `Jit.all()` / `Jit.dispose(name)` | 模块管理 |
| `Jit.tick()` | 每帧驱动异步结果与延迟卸载 |
| `Jit.hook()` | 绑定到宿主每帧事件 |
| `Jit.bind(name, fn)` / `Jit.unbind(name)` | 注册宿主回调 |
| `Jit.stats()` / `Jit.purge()` / `Jit.sweep(keep)` | 状态与清理 |
| `Jit.selfTest():String` | 内置自检 |

### JitModule

| 方法 / 字段 | 说明 |
|---|---|
| `ok` / `dll` / `image` / `symbols` / `ms` / `cached` / `diag` / `log` | 状态 |
| `call(name, a0..a5):Float` | 6 个 `double` 参数 |
| `callA(name, args)` | 参数个数可选 |
| `callAuto(name, args, ?strs)` | 按扫描到的签名转换，字符串走第三参数 |
| `callSig(name, sig, args, ?strs)` | 指定签名，用于重载 |
| `callStr(name, args):String` | 取 `RJIT_RETSTR` 的值 |
| `get(path)` / `set(path, v)` | 表达式路径：`"n"`、`"p.x"`、`"arr[2]"` |
| `getVar` / `setVar` | 顶层数值变量 |
| `getField` / `setField` / `getIndex` / `setIndex` | 显式访问 |
| `kindOf(name)` / `fieldsOf(name)` / `arraySize(name)` | 变量信息 |
| `signature(name)` / `signatures(name)` / `hasSig(sig)` | 签名信息 |
| `address(name)` / `ptr(name)` | 函数地址 / `JitPtr` |
| `has(name)` / `report()` / `dispose()` | 其他 |

### JitSession

| 方法 | 说明 |
|---|---|
| `eval(code):Bool` | 追加源码并重新编译，失败时保留上一次可用的模块 |
| `evalFile(path)` | 从文件追加 |
| `redeclare(code)` | 替换全部源码 |
| `call(fn, args, ?strs)` | 调用 |
| `get(path)` / `set(path, v)` | 读写，支持结构体字段与数组元素 |
| `snapshot()` / `restore(vals)` | 手动保存与恢复状态 |
| `vars()` / `funcs()` | 列出变量与函数 |
| `dispose()` | 释放 |

---

## 示例

### 1. 数值计算

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

### 2. 字符串参数

```haxe
var m = Jit.compile("text", '
int length(const char* s) { return (int)strlen(s); }
int joined(std::string a, std::string b) { return (int)(a.size() + b.size()); }
char head(std::string s) { return s.empty() ? 0 : s[0]; }
');

m.callAuto("length", [], ["hello"]);      // 5
m.callAuto("length", [], ["中文"]);        // 6，UTF-8 字节数
m.callAuto("joined", [], ["abc", "de"]);  // 5
m.callAuto("head", [], ["A"]);            // 65
```

源码里用到 `std::string` 但没有 `#include <string>` 时，会在文件最前面补一行，同时把诊断行号自动减 1。

### 3. 结构体与数组

```haxe
var m = Jit.compile("world", '
struct Vec2 { double x; double y; };
struct Actor { int hp; int mp; double speed; };
Vec2 camera;
Actor player;
double samples[8];
int ids[4];
');

m.set("camera.x", 120);
m.set("camera.y", -40);
m.get("camera.x");        // 120

m.set("player.hp", 80);
m.get("player.hp");       // 80

m.set("samples[3]", 0.25);
m.get("samples[3]");      // 0.25
m.get("samples[99]");     // 0，越界返回 0
m.get("missing.x");       // NaN
```

`kindOf("camera")` 返回 `"struct"`，`fieldsOf("camera")` 返回 `["x","y"]`，`kindOf("samples")` 返回 `"array"`，`arraySize("samples")` 返回 `8`。

### 4. 手写导出函数并回传字符串

```haxe
var m = Jit.compile("native", '
RJIT(greet) {
  RJIT_LOG("entered greet");
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

### 5. C++ 调用宿主

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

`RJIT_CALL0..3` 传 4 个 `double`，回调返回值会回到 C++ 侧。

### 6. 会话式脚本

```haxe
var s = new JitSession("script");
s.eval("int hp = 100;\ndouble mana = 30.0;");

s.eval("int damage(int n) { hp -= n; return hp; }");
s.call("damage", [15]);       // 85

s.eval("int heal(int n) { hp += n; return hp; }");
s.get("hp");                  // 85，重新编译后状态保留
s.call("heal", [5]);          // 90
```

每次 `eval` 都是完整重编译。编译前读出所有全局状态，装载新库后写回，所以数值变量、结构体字段、数组元素都不会丢。

### 7. 热重载

```haxe
var m = Jit.compileFile("mods/fast/core.cpp");

// 修改文件后
m = Jit.reload("fast");

// 每帧驱动延迟卸载
Jit.hook();
```

旧库不会被立即释放，而是进入退休队列，3 帧后卸载。`Jit.tick()` 负责推进。

### 8. 异步编译

```haxe
Jit.maxParallel = 2;

Jit.compileAsync("mod_a", srcA, function(m) {
  if (m.ok) trace("ready in " + Std.int(m.ms) + "ms");
});

// 主循环
Jit.tick();
```

`Jit.pending()` 返回排队数，`Jit.active()` 返回正在编译的数量。

### 9. 崩溃隔离

```haxe
JitHost.onError = function(method, name, msg) {
  Sys.println(method + " / " + name + " : " + msg);
};

var m = Jit.compile("risky", 'double boom(double x) { volatile int* p = 0; *p = 1; return x; }');
m.callAuto("boom", [1]);   // 0，回调触发，进程存活
```

### 10. 手动映射

```haxe
var m = Jit.compile("mod", src, {loader: "manual"});

m.image.manual;        // true
m.image.base;          // 加载基址
m.image.relocCount;    // 应用的重定位条数
m.image.imports;       // 依赖模块
```

手动映射的模块不在系统模块链表里，`GetModuleHandle` 找不到它，卸载必须走 `Jit.dispose`。多线程访问动态库内的 TLS 变量时，在新线程调用 `JitLoader.bindThread()`。

### 11. 分发预编译缓存

```haxe
// 构建机
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
// 目标机，无需编译器
Jit.setup({cache: "jitcache"});
Jit.importPack("dist/jitcache");
Jit.compile("mod_a", srcA);   // 命中缓存，2ms
```

工具链不可用时 `Jit.ready` 为 `false`，`compile` 仍会尝试命中缓存。`importPack` 返回 `-1` 表示 ABI、代码生成版本或平台不匹配。

### 12. 编译错误处理

```haxe
var m = Jit.compile("bad", 'double f(int x) { return x + ; }');
if (!m.ok) {
  for (d in m.diag) Sys.println("line " + d.line + ": " + d.msg);
  Sys.println(m.report());
}
```

`d.line` 是用户源码里的行号，隐式补行会自动抵消。

---

## 类型映射

自动签名识别的类型：

| C++ | 码 | C++ | 码 |
|---|---|---|---|
| `void` | `v` | `int` | `i` |
| `double` | `d` | `unsigned int` | `u` |
| `float` | `f` | `long long` | `l` |
| `bool` | `b` | `void*` / `T*` | `p` |
| `char` | `c` | `const char*` | `s` |
| `short` | `h` | `std::string` | `S` |

签名格式是 `返回码(参数码...)`，例如 `d(dd)`、`i(is)`、`i(SS)`、`v()`。

```haxe
m.signature("clamp");            // "d(ddd)"
m.callSig("area", "i(i)", [3]);  // 精确调用某个重载
```

数值参数上限 6 个，字符串参数上限 4 个。

---

## 配置

```haxe
Jit.setup({
  cache: "jitcache",   // 缓存目录
  opt: "O2",           // Od / O1 / O2 / Ox
  std: "c++17",        // C++ 标准
  flags: [],           // 追加编译参数
  backend: "auto",     // auto / msvc / clang / gcc
  loader: "loadlib"    // loadlib / manual / auto
});
```

| 全局项 | 默认 | 说明 |
|---|---|---|
| `Jit.maxParallel` | `2` | 同时运行的编译器数量 |
| `Jit.autoSweepEvery` | `0` | 每 N 次编译清理一次缓存，0 关闭 |
| `Jit.autoSweepKeep` | `24` | 清理时保留的缓存目录数 |
| `Jit.verbose` | `true` | 输出编译日志 |
| `Jit.debug` | `false` | 输出调试细节 |
| `JitCompiler.timeoutMs` | `90000` | 单次编译超时 |

---

## 性能

| 项目 | 数值 |
|---|---|
| 首次编译（含预编译头生成） | 500–900ms |
| 再次编译 | 300ms 左右，与函数数量弱相关 |
| 缓存命中加载 | 2–3ms |
| 单次跨边界调用 | 0.026–0.14µs |
| 手动映射 110KB 动态库 | 5ms 以内 |

时间主要花在编译器进程启动与链接上，不随代码量线性增长。

---

## 限制

- 数值参数最多 6 个，字符串参数最多 4 个
- 返回值只能是数值、指针或 `void`，返回字符串用 `RJIT_RETSTR` / `callStr`
- 结构体按值传参不支持，需要传地址
- C++ 默认参数不会补齐，必须传满
- 同名重载默认取第一个，其余用 `callSig` 指定
- 每次调用经过一次间接跳转与异常保护，不适合纳秒级热路径
- 编译依赖本机编译器，目标机没有编译器时只能走缓存
- SEH 只捕获硬件异常，C++ 异常跨越库边界属于未定义行为
- 编译超时通过终止编译器进程实现
- 结构体访问器只覆盖第一层数值字段，嵌套结构和指针成员要自行封装函数
- 手动镜像加载目前只实现了 Windows PE 格式，ELF 走系统加载器
- 修改 ABI 头结构后需要清理宿主侧预编译头再重新构建

---

## 测试

`test/` 是独立 console 工程，158 项断言。

```
cd test
haxe build.hxml
bin/Main.exe
```

覆盖内容：核心调用、诊断行号、表达式偏移、自动签名、字符串参数、结构体与数组读写、会话状态保持、崩溃隔离与错误回调、指针句柄、重载分发、并发闸门、热重载、大源码、缓存命中、缓存打包与导入、无编译器环境、手动映射与卸载、调用吞吐。

Linux：

```
bash test/linux/run.sh
```

---

## 目录

```
src/hxcpp_jit_r/
  Jit.hx            入口：setup / compile / reload / prefetch / pack
  JitModule.hx      模块句柄：调用、签名、变量读写
  JitSession.hx     会话：累积源码与状态恢复
  JitScan.hx        源码扫描：函数签名、全局变量、结构体、数组
  JitCodegen.hx     生成调用入口、调度器、变量访问器
  JitLoader.hx      镜像解析与手动映射
  JitPack.hx        缓存打包与校验
  JitPtr.hx         指针句柄
  JitCompiler.hx    编译器调用、预编译头、诊断解析
  JitToolchain.hx   工具链探测与环境注入
  JitCache.hx       哈希、目录、清理
  JitAbi.hx         ABI 头内容
  JitNative.hx      系统原语与回调表
  JitHost.hx        回调注册、变量表、字符串槽
  JitBoot.hx        可选自检入口
  JitMacro.hx       构建期宏
```

---

## 许可

MIT
