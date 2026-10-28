import hxcpp_jit_r.Jit;
import hxcpp_jit_r.JitHost;
import hxcpp_jit_r.JitNative;
import hxcpp_jit_r.JitSession;
import hxcpp_jit_r.JitCompiler;
import hxcpp_jit_r.JitElf;
import hxcpp_jit_r.JitPtr;
import hxcpp_jit_r.JitLoader;
import hxcpp_jit_r.JitPlatform;
#if cpp
import sys.thread.Thread;
#end

class Main {
  static function absPath(p:String):Bool {
    if (p == null) return false;
    if (p.substr(0, 1) == "/") return true;
    return p.length > 2 && p.charAt(1) == ":";
  }

  static function countSuffix(p:String, suf:String):Int {
    if (!sys.FileSystem.exists(p)) return 0;
    if (!sys.FileSystem.isDirectory(p)) return StringTools.endsWith(p, suf) ? 1 : 0;
    var n = 0;
    for (f in sys.FileSystem.readDirectory(p)) n += countSuffix(p + "/" + f, suf);
    return n;
  }

  static function rmTree(p:String):Void {
    if (!sys.FileSystem.exists(p)) return;
    try {
      if (sys.FileSystem.isDirectory(p)) {
        for (f in sys.FileSystem.readDirectory(p)) rmTree(p + "/" + f);
        sys.FileSystem.deleteDirectory(p);
      } else {
        sys.FileSystem.deleteFile(p);
      }
    } catch (e:Dynamic) {}
  }

  static function tmpRoot():String {
    var t = Sys.getEnv("TEMP");
    if (t == null) t = Sys.getEnv("TMPDIR");
    return t == null ? "/tmp" : t;
  }

  static var pass = 0;
  static var fail = 0;
  static var out = new StringBuf();

  static function ok(label:String, cond:Bool, detail:String = "") {
    var line = (cond ? "  PASS " : "  FAIL ") + label + (detail == "" ? "" : "  " + detail);
    if (cond) pass++ else fail++;
    out.add(line + "\n");
    Sys.println(line);
    Sys.stdout().flush();
  }

  static function eq(label:String, got:String, want:String) {
    ok(label, got == want, got == want ? "" : 'got=$got want=$want');
  }

  static function head(s:String) {
    var line = "\n== " + s + " ==";
    out.add(line + "\n");
    Sys.println(line);
    Sys.stdout().flush();
  }

  static function main() {
    var t0 = Sys.time();
    out.add("[jit] backend probe\n");
    Jit.cacheDir = tmpRoot() + "/rjitcache";
    if (!Jit.setup({opt: "O2"})) {
      Sys.println("setup failed: " + Jit.lastError);
      return;
    }
    out.add("  " + Jit.tool.summary() + "\n");
    ok("cache root resolved", Jit.cache.root.indexOf("rjitcache") >= 0 && absPath(Jit.cache.root), Jit.cache.root);
    ok("setup ready", Jit.ready, Std.int((Sys.time() - t0) * 1000) + "ms");

    head("backend fallback");
    var tc = hxcpp_jit_r.JitToolchain.detect("clang");
    ok("request clang", tc.ready, "resolved backend=" + tc.backend);
    var tm = hxcpp_jit_r.JitToolchain.detect("msvc");
    ok("request msvc", tm.ready, "resolved backend=" + tm.backend);

    head("core");
    var m = Jit.compile("core", 'RJIT(add) { return RJIT_A0 + RJIT_A1; }
RJIT(mul) { return RJIT_A0 * RJIT_A1; }
RJIT(mix) { return RJIT_CALL2("mul", RJIT_A0, RJIT_A1) + 1.0; }
RJIT(greet) { RJIT_LOG("hello"); RJIT_RETSTR("str-ok"); return RJIT_N; }
RJIT(fib) { double a = 0, b = 1; int n = (int)RJIT_A0; for (int i = 0; i < n; i++) { double t = a + b; a = b; b = t; } return a; }
RJIT(cpponly) { return (double)(RJIT_A0 * 2 + 1); }
');
    JitHost.capture = true;
    JitHost.logs = [];
    ok("compile", m.ok, m.cached ? "cached" : Std.int(m.ms) + "ms");
    eq("add", Std.string(m.call("add", 2, 3)), "5");
    eq("mul", Std.string(m.call("mul", 6, 7)), "42");
    eq("host callback", Std.string(m.call("mix", 6, 7)), "43");
    eq("retstr", m.callStr("greet", [1, 2]), "str-ok");
    eq("host log", Std.string(JitHost.logs.indexOf("hello") >= 0), "true");
    eq("fib(30)", Std.string(m.call("fib", 30)), "832040");
    eq("undefined fn", Std.string(m.call("nope")), "0");
    ok("address", m.address("add") > 0, "0x" + StringTools.hex(Std.int(m.address("add")) & 0xFFFFF));
    eq("symbols", m.symbols.length + "", "6");

    head("diagnostics line accuracy");
    var bad = Jit.compile("badline", 'RJIT(a) { return 1; }
RJIT(b) { return 2; }
RJIT(c) { return nope; }
RJIT(d) { return 4; }
');
    ok("bad compile fails", !bad.ok);
    var userDiag = bad.diag.filter(function(d) return d.file == "user");
    ok("diag count", userDiag.length > 0, userDiag.length + " entries");
    if (userDiag.length > 0) eq("diag line == 3", Std.string(userDiag[0].line), "3");

    head("eval offset");
    eq("eval value", Std.string(Jit.eval("return 1 + 2 * 3;")), "7");
    var eb = Jit.compile("evalbad", "RJIT(__e) {\nreturn 1;\nreturn zzz;\n}\n", {lineShift: 1});
    var ue = eb.diag.filter(function(d) return d.file == "user");
    if (ue.length > 0) eq("eval diag line == 2", Std.string(ue[0].line), "2") else ok("eval diag present", false);

    head("session");
    var s = new JitSession("sess");
    ok("session eval 1", s.eval("RJIT(a) { return 10; }"));
    eq("session a", Std.string(s.call("a")), "10");
    ok("session eval 2", s.eval("RJIT(b) { return RJIT_CALL0(\"a\") + 5; }"));
    eq("session b sees a", Std.string(s.call("b")), "15");
    s.set("hp", 77);
    ok("session eval 3", s.eval("RJIT(c) { return RJIT_GET(\"hp\"); }"));
    eq("session var bridge", Std.string(s.call("c")), "77");
    ok("session redeclare", s.redeclare("RJIT(a) { return 99; }"));
    eq("session a redeclared", Std.string(s.call("a")), "99");
    s.dispose();

    head("parallel compile gate");
    var prevMax = Jit.maxParallel;
    Jit.maxParallel = 3;
    var peak = 0;
    var finished = 0;
    var spin = 0;
    var salt = Std.string(Math.random());
    for (i in 0...9) {
      var src = "int salt" + i + " = " + (Std.int(Math.random() * 100000.0)) + ";\nRJIT(v) { return " + (i + 1) + ".0 * 2; }\n";
      Jit.compileAsync("par" + i, src, function(mm) finished++);
    }
    while (finished < 9 && spin < 8000) {
      Jit.tick();
      if (Jit.active() > peak) peak = Jit.active();
      Sys.sleep(0.002);
      spin++;
    }
    ok("all jobs finished", finished == 9, finished + "/9");
    ok("peak <= maxParallel", peak <= 3, "peak=" + peak);
    ok("peak >= 2", peak >= 2, "peak=" + peak);
    var p8 = Jit.get("par8");
    ok("module registered", p8 != null, "mods=" + Jit.all().length + " names=" + Jit.all().map(function(m) return m.name).join(","));
    eq("par result", Std.string(p8 == null ? -1 : p8.call("v")), "18");
    Jit.maxParallel = prevMax;

    head("hot reload stress");
    var hm = Jit.compile("hotstress", "RJIT(v) { return 0; }\n");
    var reloads = 8;
    var lastVal = 0.0;
    for (i in 0...reloads) {
      hm = Jit.reload("hotstress", "RJIT(v) { return " + (i + 1) + "; }\n");
      lastVal = hm.call("v");
    }
    eq("reload final value", Std.string(lastVal), Std.string(reloads));
    for (i in 0...6) Jit.tick();
    var alive = 0;
    for (x in Jit.all()) if (x.ok) alive++;
    ok("modules alive", alive > 0, alive + " modules");

    head("large source");
    var big = new StringBuf();
    for (i in 0...200) big.add("RJIT(f" + i + ") { return (double)" + i + " * RJIT_A0; }\n");
    var bm = Jit.compile("big", big.toString());
    ok("200 functions compile", bm.ok, Std.int(bm.ms) + "ms, " + bm.symbols.length + " symbols");
    eq("f199(2)", Std.string(bm.call("f199", 2)), "398");

    head("cache");
    var src = "RJIT(v) { return 1234; }\n";
    Jit.compile("cachedemo", src);
    var c2 = Jit.compile("cachedemo", src);
    ok("second is cached", c2.cached);
    eq("cached value", Std.string(c2.call("v")), "1234");

    head("auto signature");
    var sc = hxcpp_jit_r.JitScan.functions("double half(double x) { return x / 2; }\nint c2 = 5;\n");
    ok("scanner in cpp", sc.length == 1, "found=" + sc.length + (sc.length > 0 ? " sig=" + sc[0].sig : ""));
    var sv = hxcpp_jit_r.JitScan.globals("int c2 = 5;\n");
    ok("scanner vars in cpp", sv.length == 1, "found=" + sv.length);
    var am = Jit.compile("auto", 'int counter = 0;
const double PI = 3.14159;
double half(double x) { return x / 2; }
int addi(int a, int b) { return a + b; }
double mixd(int a, double b) { return (double)a + b; }
void bump() { counter += 3; }
int twice(int v) { return v * 2; }
float halfF(float x) { return x / 2; }
bool isPos(int v) { return v > 0; }
char bumpc(char c) { return (char)(c + 1); }
unsigned int twiceU(unsigned int v) { return v * 2u; }
');
    ok("auto compile", am.ok, Std.int(am.ms) + "ms  sigs=" + [am.signature("half"), am.signature("addi"), am.signature("bump"), am.signature("mixd")].join(" ") + "  " + am.diag.map(d -> JitCompiler.describe(d)).join("; "));
    eq("half(10)", Std.string(am.callAuto("half", [10])), "5");
    eq("addi(3,4)", Std.string(am.callAuto("addi", [3, 4])), "7");
    eq("mixd(2,0.5)", Std.string(am.callAuto("mixd", [2, 0.5])), "2.5");
    eq("twice(21)", Std.string(am.callAuto("twice", [21])), "42");
    eq("halfF(5) float ret/arg", Std.string(am.callAuto("halfF", [5])), "2.5");
    eq("isPos(1) bool ret", Std.string(am.callAuto("isPos", [1])), "1");
    eq("isPos(-1) bool ret", Std.string(am.callAuto("isPos", [-1])), "0");
    eq("bumpc(65) char ret", Std.string(am.callAuto("bumpc", [65])), "66");
    eq("twiceU(7) unsigned", Std.string(am.callAuto("twiceU", [7])), "14");
    eq("sig halfF", am.signature("halfF"), "f(f)");
    eq("sig isPos", am.signature("isPos"), "b(i)");
    ok("explicit sig call", am.callSig("halfF", "f(f)", [9]) == 4.5, Std.string(am.callSig("halfF", "f(f)", [9])));
    ok("missing sig rejected", am.callSig("halfF", "d(dd)", [9]) == 0);
    ok("hasSig", am.hasSig("f(f)") && !am.hasSig("z(z)"));
    eq("var counter init", Std.string(am.getVar("counter")), "0");
    am.callAuto("bump", []);
    eq("var after bump", Std.string(am.getVar("counter")), "3");
    ok("setVar", am.setVar("counter", 100));
    am.callAuto("bump", []);
    eq("var after set+bump", Std.string(am.getVar("counter")), "103");
    ok("const var exposed", Math.abs(am.getVar("PI") - 3.14159) < 0.0001, Std.string(am.getVar("PI")));
    ok("unknown var rejected", !am.setVar("nope", 1));

    head("session state across evals");
    var ss = new JitSession("state");
    ok("state eval 1", ss.eval("int hp = 10;\nint heal(int n) { hp += n; return hp; }\n"));
    eq("heal(5)", Std.string(ss.call("heal", [5])), "15");
    ok("state eval 2", ss.eval("int dmg(int n) { hp -= n; return hp; }\n"));
    eq("hp survived recompile", Std.string(ss.get("hp")), "15");
    eq("dmg(3)", Std.string(ss.call("dmg", [3])), "12");
    eq("hp after dmg", Std.string(ss.get("hp")), "12");
    ok("state eval 3", ss.eval("double bonus(double k) { return hp * k; }\n"));
    eq("bonus(2) sees hp", Std.string(ss.call("bonus", [2])), "24");
    ss.dispose();

    head("crash guard");
    if (!JitPlatform.win) {
      ok("crash guard needs a windows host", true, "skipped");
    } else {
      var crashMsg:String = null;
      hxcpp_jit_r.JitHost.onError = function(method:String, n:String, msg:String) {
        crashMsg = method + "/" + n;
      };
      var cm = Jit.compile("crash", "double boom(double x) { volatile int* p = 0; *p = 1; return x; }\n");
      ok("crash module compiled", cm.ok);
      eq("crash returns 0", Std.string(cm.callAuto("boom", [1])), "0");
      eq("onError fired", Std.string(crashMsg), "callAuto/boom");
      hxcpp_jit_r.JitHost.onError = null;
    }

    head("pointer handle");
    var fp = am.ptr("half");
    ok("fn ptr not null", !fp.isNull(), fp.toString());
    ok("ptr format", StringTools.startsWith(fp.toString(), "JitPtr(0x"));
    ok("null ptr", new hxcpp_jit_r.JitPtr(0).isNull());

    head("overload");
    var om = Jit.compile("over", "int area(int s) { return s * s; }\ndouble area(double w, double h) { return w * h; }\n");
    ok("overload compiled", om.ok);
    eq("overload sig count", Std.string(om.signatures("area").length), "2");
    eq("overload int", Std.string(om.callSig("area", "i(i)", [3])), "9");
    eq("overload double", Std.string(om.callSig("area", "d(dd)", [2, 3])), "6");

    head("scanner struct/array");
    var ss = hxcpp_jit_r.JitScan.structs("struct A { int x; double y; };\n");
    ok("struct parsed", ss.length == 1 && ss[0].name == "A" && ss[0].fields.length == 2, ss.length == 0 ? "none" : ss[0].name + "/" + ss[0].fields.length);
    var vv = hxcpp_jit_r.JitScan.globals("double a5x[5];\nint n1x;\nstruct P { double x; };\nP p1x;\n");
    var ka = "";
    var ks = "";
    for (v in vv) {
      if (v.name == "a5x") ka = v.kind + ":" + v.elem + ":" + v.size;
      if (v.name == "p1x") ks = v.kind + ":" + v.structName;
    }
    ok("array parsed", ka == "array:d:5", ka);
    ok("struct var parsed", ks == "struct:P", ks);

    head("posix backend args");
    var pa = JitCompiler.posixArgs("m.cc", "m.so", "/d", "/c/h.h", "/c", "c++17", "O2", [], "gcc");
    ok("posix -shared", pa.indexOf("-shared") >= 0, pa.join(" "));
    ok("posix -fPIC", pa.indexOf("-fPIC") >= 0);
    ok("posix -std", pa.indexOf("-std=c++17") >= 0);
    ok("posix opt", pa.indexOf("-O2") >= 0);
    ok("posix -include header", pa.indexOf("-include") >= 0 && pa.indexOf("/c/h.h") >= 0);
    ok("posix visibility", pa.indexOf("-fvisibility=hidden") >= 0);
    var pb = JitCompiler.posixArgs("m.cc", "m.so", "/d", "/c/h.h", "/c", "c++17", "Od", [], "gcc");
    ok("posix Od to O0", pb.indexOf("-O0") >= 0);

    head("string args");
    ok("needsStringHeader", JitCompiler.needsStringHeader("int f(std::string s);"));
    ok("no header needed", !JitCompiler.needsStringHeader("int f(int x);"));
    var sm = Jit.compile("strs", 'int lens(const char* s) { return (int)strlen(s); }
int mixs(int a, const char* b) { return a + (int)strlen(b); }
int adds(std::string a, std::string b) { return (int)(a.size() + b.size()); }
int first(std::string s) { return s.empty() ? -1 : (int)s[0]; }
');
    ok("string compile", sm.ok, sm.diag.length > 0 ? JitCompiler.describe(sm.diag[0]) : "");
    eq("sig lens", sm.signature("lens"), "i(s)");
    eq("sig adds", sm.signature("adds"), "i(SS)");
    eq("lens hello", Std.string(sm.callAuto("lens", [], ["hello"])), "5");
    eq("lens utf8", Std.string(sm.callAuto("lens", [], ["caf\u00e9"])), "5");
    eq("mixs int+str", Std.string(sm.callAuto("mixs", [10], ["abcd"])), "14");
    eq("adds two strings", Std.string(sm.callAuto("adds", [], ["abc", "de"])), "5");
    eq("first char", Std.string(sm.callAuto("first", [], ["A"])), "65");
    eq("empty string len", Std.string(sm.callAuto("lens", [], [""])), "0");
    eq("missing str arg", Std.string(sm.callAuto("lens", [], [])), "0");
    var sm2 = Jit.compile("strs2", 'int rev(const char* s, int n) { return (int)strlen(s) * 100 + n; }
int six(int a, int b, int c, int d, int e, int f) { return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6; }
int sn(std::string a, int m, std::string b, int n) { return (int)a.size() * 1000 + m * 100 + (int)b.size() * 10 + n; }
');
    ok("mixed compile", sm2.ok, sm2.diag.length > 0 ? JitCompiler.describe(sm2.diag[0]) : "");
    eq("sig rev", sm2.signature("rev"), "i(si)");
    eq("sig six", sm2.signature("six"), "i(iiiiii)");
    eq("rev str then int", Std.string(sm2.callAuto("rev", [7], ["abc"])), "307");
    eq("six numeric args", Std.string(sm2.callAuto("six", [1, 2, 3, 4, 5, 6])), "91");
    eq("string int interleave", Std.string(sm2.callAuto("sn", [2, 3], ["abcd", "xy"])), "4223");

    head("string return");
    var sr = Jit.compile("strret", 'std::string greet(std::string name) { return "Hello, " + name; }
std::string tag(int n) { return n > 0 ? std::string("pos") : std::string("neg"); }
std::string empty_one() { return std::string(); }
');
    ok("string return compile", sr.ok, sr.diag.length > 0 ? JitCompiler.describe(sr.diag[0]) : "");
    eq("greet Haxe", sr.callStr("greet", [], ["Haxe"]), "Hello, Haxe");
    eq("greet utf8", sr.callStr("greet", [], ["caf\u00e9"]), "Hello, caf\u00e9");
    eq("tag pos", sr.callStr("tag", [1]), "pos");
    eq("tag neg", sr.callStr("tag", [0]), "neg");
    eq("empty string return", sr.callStr("empty_one", []), "");
    eq("numeric call on string fn", Std.string(sr.callAuto("greet", [], ["x"])), "0");

    head("pointer variables");
    var pm = Jit.compile("ptrs", 'int value = 5;
int other = 9;
int* ptr = &value;
int read(int* p) { return *p; }
int write(int* p, int v) { *p = v; return *p; }
');
    ok("pointer compile", pm.ok, pm.diag.length > 0 ? JitCompiler.describe(pm.diag[0]) : "");
    eq("kind ptr", pm.kindOf("ptr"), "ptr");
    var pv = pm.get("ptr");
    ok("ptr reads as address", pv > 0, Std.string(pv));
    eq("addrOf value equals ptr", Std.string(pm.get("&value")), Std.string(pv));
    ok("addrOf differs", pm.get("&other") != pm.get("&value"));
    eq("read through ptr", Std.string(pm.callAuto("read", [pv])), "5");
    eq("write through ptr", Std.string(pm.callAuto("write", [pv, 42])), "42");
    eq("value changed", Std.string(pm.get("value")), "42");
    ok("repoint ptr", pm.set("ptr", pm.get("&other")));
    eq("read repointed", Std.string(pm.callAuto("read", [pm.get("ptr")])), "9");
    ok("null ptr set", pm.set("ptr", 0));
    eq("ptr null", Std.string(pm.get("ptr")), "0");

    head("struct and array access");
    var stc = Jit.compile("agg", 'struct Vec2 { double x; double y; };
struct Stat { int hp; int mp; double spd; };
Vec2 pos;
Stat hero;
double arr[4];
int ids[3];
');
    ok("agg compile", stc.ok, stc.diag.length > 0 ? JitCompiler.describe(stc.diag[0]) : "");
    ok("kind pos", stc.kindOf("pos") == "struct", stc.kindOf("pos"));
    ok("fields pos", stc.fieldsOf("pos").join(",") == "x,y", stc.fieldsOf("pos").join(","));
    eq("get pos.x init", Std.string(stc.get("pos.x")), "0");
    ok("set pos.x", stc.set("pos.x", 3.5));
    eq("get pos.x", Std.string(stc.get("pos.x")), "3.5");
    ok("set pos.y", stc.set("pos.y", -2));
    eq("get pos.y", Std.string(stc.get("pos.y")), "-2");
    ok("set hero.hp", stc.set("hero.hp", 77));
    eq("get hero.hp", Std.string(stc.get("hero.hp")), "77");
    ok("set hero.spd", stc.set("hero.spd", 1.25));
    eq("get hero.spd", Std.string(stc.get("hero.spd")), "1.25");
    eq("arr size", Std.string(stc.arraySize("arr")), "4");
    ok("set arr[2]", stc.set("arr[2]", 9));
    eq("get arr[2]", Std.string(stc.get("arr[2]")), "9");
    eq("arr oob returns 0", Std.string(stc.get("arr[9]")), "0");
    ok("set ids[0]", stc.set("ids[0]", 5));
    eq("get ids[0]", Std.string(stc.get("ids[0]")), "5");
    eq("dbg ids getIndex0", Std.string(stc.getIndex("ids", 0)), "5");
    ok("dbg ids setIndex1", stc.setIndex("ids", 1, 7), "");
    eq("dbg ids getIndex1", Std.string(stc.getIndex("ids", 1)), "7");
    ok("unknown field nan", stc.get("nope.x") != stc.get("nope.x"));

    head("aggregate state across eval");
    var as = new JitSession("aggstate");
    var e1 = as.eval("struct P { double x; double y; };\nP pt;\ndouble buf[3];\n");
    ok("agg eval 1", e1, e1 ? "" : (as.diag.length > 0 ? JitCompiler.describe(as.diag[0]) : as.lastError));
    as.set("pt.x", 4);
    as.set("buf[1]", 6);
    eq("agg session x", Std.string(as.get("pt.x")), "4");
    var e2 = as.eval("double total() { return pt.x + buf[1]; }\n");
    ok("agg eval 2", e2, e2 ? "" : (as.diag.length > 0 ? JitCompiler.describe(as.diag[0]) : as.lastError));
    eq("agg survived recompile", Std.string(as.call("total")), "10");
    as.dispose();

    head("manual loader");
    var manSrc = "int sq(int x) { return x * x; }\nint add3(int a, int b, int c) { return a + b + c; }\ndouble half(double v) { return v / 2; }\n";
    var mp = Jit.compile("man", manSrc, {loader: "manual"});
    ok("manual compile+load", mp.ok, mp.diag.length > 0 ? JitCompiler.describe(mp.diag[0]) : "");
    if (mp.ok && mp.image != null) {
      var img = mp.image;
      ok("manual mapped", img.manual, "sections=" + img.sections.length + " imports=" + img.imports.join("+") + " reloc=" + img.relocCount + " rebased=" + img.rebased);
      eq("manual sq(7)", Std.string(mp.callAuto("sq", [7])), "49");
      eq("manual add3", Std.string(mp.callAuto("add3", [1, 2, 3])), "6");
      var top = Jit.compile("man2", "double tri(double v) { return v * 3; }\n", {loader: "manual"});
      ok("manual second module", top.ok, top.diag.length > 0 ? JitCompiler.describe(top.diag[0]) : "");
      eq("manual tri", Std.string(top.callAuto("tri", [5])), "15");
      Jit.dispose("man2");
      ok("manual unwind table", !JitPlatform.win || img.fnTable != 0, "entries=" + img.fnCount);
      var mth = Jit.compile("manthrow", '#include <stdexcept>
double boom(double v) { if (v > 0) throw std::runtime_error("mapped"); return v; }
', {loader: "manual"});
      ok("manual throw module", mth.ok, mth.diag.length > 0 ? JitCompiler.describe(mth.diag[0]) : "");
      ok("manual throw uses the system loader", mth.image == null, mth.image == null ? "" : "mapped=" + mth.image.manual);
      JitHost.capture = true;
      eq("manual throw trapped", Std.string(mth.callAuto("boom", [1])), "0");
      eq("manual throw quiet path", Std.string(mth.callAuto("boom", [-1])), "-1");
      ok("manual throw message", JitHost.logs.join(" ").indexOf("mapped") >= 0, JitHost.logs.join("|"));
    } else {
      ok("manual mapped", false, "image missing");
    }
    var manMod = Jit.get("man");
    var manBase:cpp.SizeT = (manMod != null && manMod.image != null) ? manMod.image.base : 0;
    Jit.dispose("man");
    for (i in 0...6) Jit.tick();
    ok("manual unloaded", manBase != 0 && hxcpp_jit_r.JitLoader.find(manBase) == null, "base=" + JitNative.toFloat(manBase) + " images=" + hxcpp_jit_r.JitLoader.count());
    var lb = Jit.compile("loadlib", "int six() { return 6; }\n", {loader: "loadlib"});
    eq("loadlib still works", Std.string(lb.callAuto("six", [])), "6");

    head("pack export / import");
    var pf = Jit.exportPack("packout");
    ok("export files", pf > 0, pf + " files");
    var pi = Jit.packInfo("packout");
    ok("pack manifest ok", StringTools.startsWith(pi, "pack ok"), pi);
    ok("manifest exists", sys.FileSystem.exists("packout/manifest.json"));
    var strsMod = Jit.get("strs");
    ok("headline dll packed", strsMod != null && sys.FileSystem.exists("packout/" + strsMod.key + "/mod" + Jit.cache.ext()));

    head("cache-only mode (no toolchain)");
    var coldSrc = "double twice(double v) { return v * 2; }\n";
    var c1 = Jit.compile("cold", coldSrc);
    ok("cold compile", c1.ok);
    Jit.exportPack("packcold");
    hxcpp_jit_r.JitToolchain.forceUnavailable = true;
    var coldDir = tmpRoot() + "/rjitcold_" + Std.string(Std.int(Sys.time() * 1000)) + "_" + Std.string(Std.random(1000));
    Jit.setup({cache: coldDir});
    ok("toolchain disabled", !Jit.ready, Jit.lastError);
    var beforeImp = Jit.compile("cold", coldSrc);
    ok("no cache yet fails", !beforeImp.ok, beforeImp.diag.length > 0 ? JitCompiler.describe(beforeImp.diag[0]) : "");
    var imp = Jit.importPack("packcold");
    ok("import files", imp > 0, imp + " files");
    var c2 = Jit.compile("cold", coldSrc);
    ok("cache-only hit", c2.ok && c2.cached, c2.diag.length > 0 ? JitCompiler.describe(c2.diag[0]) : ("cached=" + c2.cached));
    eq("cache-only call", Std.string(c2.callAuto("twice", [21])), "42");
    hxcpp_jit_r.JitToolchain.forceUnavailable = false;
    rmTree(coldDir);
    Jit.setup({cache: "jitcache"});
    ok("toolchain restored", Jit.ready);

    head("edge cases");
    var em = Jit.compile("empty", "");
    ok("empty source compiles", em.ok, em.diag.length > 0 ? JitCompiler.describe(em.diag[0]) : "");
    eq("empty has no funcs", Std.string(em.fnNames().length), "0");
    var bm = Jit.compile("broken", "int f() { return ; }");
    ok("broken source rejected", !bm.ok, bm.diag.length > 0 ? JitCompiler.describe(bm.diag[0]) : "no diag");
    ok("broken has no dll", bm.dll == "", bm.dll);
    var gm = Jit.compile("guard2", "int gf(int x) { return x + 1; }\n");
    eq("bad sig returns 0", Std.string(gm.callSig("gf", "garbage", [1])), "0");
    eq("unknown fn returns 0", Std.string(gm.callAuto("nope", [1])), "0");
    ok("unknown path is nan", gm.get("nosuch[0]") != gm.get("nosuch[0]"), "");
    var dm = Jit.compile("disp", "int dv() { return 1; }\n");
    Jit.dispose("disp");
    Jit.dispose("disp");
    Jit.dispose("no_such_module");
    ok("double dispose safe", true, "");

    head("concurrent cold build");
    var oldCache = Jit.cacheDir;
    var cdir = tmpRoot() + "/rjitconc_" + Std.string(Std.int(Sys.time() * 1000)) + "_" + Std.string(Std.random(1000));
    Jit.setup({cache: cdir});
    ok("cold cache switched", Jit.cache.root.indexOf("rjitconc_") >= 0 && absPath(Jit.cache.root), Jit.cache.root);
    Jit.maxParallel = 2;
    var done = 0;
    var faults:Array<String> = [];
    var salt = Std.string(Std.random(1000000));
    for (i in 0...4) {
      var src = "double gx" + i + " = " + (i + 1) + ".0;\nint cv" + i + "(int x) { return x * " + (i + 1) + "; }\n";
      Jit.compileAsync("conc" + i, "int pad" + i + " = " + Std.int(Math.random() * 99999) + ";\n" + src, function(m) {
        if (m != null && m.ok) done++;
        else faults.push(m == null ? "null" : (m.diag.length > 0 ? JitCompiler.describe(m.diag[0]) : "ok=false"));
      });
    }
    var spin = 0;
    while (Jit.pending() > 0 && spin < 1200) {
      Jit.tick();
      Sys.sleep(0.02);
      spin++;
    }
    ok("concurrent cold build", done == 4, "done=" + done + " pending=" + Jit.pending() + " ticks=" + spin + (faults.length > 0 ? " " + faults.join(" | ") : ""));
    Jit.maxParallel = 2;
    rmTree(cdir);
    Jit.setup({cache: oldCache});
    ok("cache restored", Jit.cache.root.indexOf("jitcache") >= 0, Jit.cache.root);

    head("bulk array io");
    var bk = Jit.compile("bulk", 'double samples[16];
int ids[8];
double sum_all() { double s = 0; for (int i = 0; i < 16; i++) s += samples[i]; return s; }
');
    ok("bulk compile", bk.ok, bk.diag.length > 0 ? JitCompiler.describe(bk.diag[0]) : "");
    ok("write doubles", bk.writeDoubles("samples", [for (i in 1...17) i * 1.0]), "");
    var rd = bk.readDoubles("samples");
    eq("read doubles count", Std.string(rd.length), "16");
    eq("read doubles edges", Std.string(rd[0] + rd[15]), "17");
    eq("native sees bulk data", Std.string(bk.callAuto("sum_all", [])), "136");
    ok("write ints", bk.writeInts("ids", [1, 2, 3, 4]), "");
    eq("read ints full", bk.readInts("ids").join(","), "1,2,3,4,0,0,0,0");
    eq("read ints partial", bk.readInts("ids", 4).join(","), "1,2,3,4");
    ok("array address", bk.arrayAddress("samples") != 0, "");
    ok("write doubles clamps", bk.writeDoubles("samples", [for (i in 0...100) i * 1.0]), "");
    eq("clamped count", Std.string(bk.readDoubles("samples").length), "16");
    eq("clamped last", Std.string(bk.readDoubles("samples")[15]), "15");
    ok("raw roundtrip", bk.readRaw("samples") != null && bk.readRaw("samples").length == 128, "");
    ok("bulk rejects non array", bk.readDoubles("nope").length == 0 && !bk.writeDoubles("nope", [1]), "");

    head("pointer handle");
    var addr = bk.arrayAddress("samples");
    var pt = hxcpp_jit_r.JitPtr.of(addr);
    ok("ptr not null", !pt.isNull(), pt.toString());
    ok("ptr readable", pt.valid(), pt.toString());
    eq("ptr read f64", Std.string(pt.readF64(8)), "1");
    ok("ptr write f64", pt.writeF64(42.5, 8), "");
    eq("ptr write visible", Std.string(bk.readDoubles("samples")[1]), "42.5");
    ok("ptr restore", pt.writeF64(2, 8), "");
    eq("ptr offset", Std.string(pt.offset(8).address == addr + 8), "true");
    var np = new hxcpp_jit_r.JitPtr(0);
    ok("null ptr safe", np.readF64() == 0 && np.readI32() == 0 && !np.writeI32(1) && np.readBytes(4) == null, "");

    head("auto sweep hook");
    var km = Jit.compile("sweepkeep", "double kv(double v) { return v + 1; }\n");
    ok("sweep keep compile", km.ok, km.diag.length > 0 ? JitCompiler.describe(km.diag[0]) : "");
    Jit.autoSweepEvery = 1;
    Jit.autoSweepKeep = 64;
    for (i in 0...4) Jit.tick();
    Jit.autoSweepEvery = 0;
    eq("module survives sweep", Std.string(km.callAuto("kv", [41])), "42");

    head("fast call");
    var fcm = Jit.compile("fastc", "RJIT(sq) { return RJIT_A0 * RJIT_A0; }\n");
    ok("fast compile", fcm.ok, "");
    var reps2 = 2000000;
    var tSlow = Sys.time();
    var accSlow:Float = 0;
    for (i in 0...reps2) accSlow += fcm.call("sq", i * 0.0001);
    var slowUs = (Sys.time() - tSlow) * 1000000.0 / reps2;
    var tFast = Sys.time();
    var accFast:Float = 0;
    for (i in 0...reps2) accFast += fcm.callFast("sq", i * 0.0001);
    var fastUs = (Sys.time() - tFast) * 1000000.0 / reps2;
    ok("fast matches call", Math.abs(accSlow - accFast) < 1.0, Jit.f3(accSlow) + " vs " + Jit.f3(accFast));
    ok("both paths measurably fast", fastUs > 0 && slowUs > 0 && slowUs < 1.0, "call=" + Jit.f3(slowUs) + "us  fast=" + Jit.f3(fastUs) + "us");

    head("file watch");
    var wpath = "watchme.cpp";
    sys.io.File.saveContent(wpath, "double wv() { return 1; }\n");
    ok("watch registered", Jit.watch(wpath, "watched"), "");
    ok("watched listed", Jit.watchedFiles().indexOf(wpath) >= 0, Jit.watchedFiles().join(","));
    var wm = Jit.get("watched");
    eq("watched initial", Std.string(wm == null ? -1 : wm.callAuto("wv", [])), "1");
    sys.io.File.saveContent(wpath, "double wv() { return 2; }\n");
    Jit.watchEvery = 1;
    var tries = 0;
    wm = Jit.get("watched");
    while (tries < 40 && (wm == null || wm.callAuto("wv", []) != 2)) {
      Jit.tick();
      Sys.sleep(0.02);
      tries++;
      wm = Jit.get("watched");
    }
    eq("watched reloaded", Std.string(wm == null ? -1 : wm.callAuto("wv", [])), "2");
    ok("unwatch", Jit.unwatch(wpath), "");
    sys.io.File.saveContent(wpath, "double wv() { return 3; }\n");
    for (i in 0...8) {
      Jit.tick();
      Sys.sleep(0.02);
    }
    wm = Jit.get("watched");
    eq("stops after unwatch", Std.string(wm == null ? -1 : wm.callAuto("wv", [])), "2");
    Jit.watchEvery = 30;
    try sys.FileSystem.deleteFile(wpath) catch (e:Dynamic) {};

    head("struct arrays and nested fields");
    var sa = Jit.compile("structarr", "
struct Vec2 { double x; double y; };
struct Obj { Vec2 pos; Vec2 vel; int tag; };
Vec2 pts[4] = {{1,2},{3,4},{5,6},{7,8}};
Obj box = {{10,20},{1,2},7};
double totalx() { double s = 0; for (int i = 0; i < 4; i++) s += pts[i].x; return s; }
");
    ok("struct array compiles", sa.ok, sa.diag.length > 0 ? JitCompiler.describe(sa.diag[0]) : "");
    eq("struct array kind", sa.kindOf("pts"), "structarray");
    eq("struct array len", Std.string(sa.arraySize("pts")), "4");
    eq("struct array elem size", Std.string(sa.elemSize("pts")), "16");
    eq("elem field read", Std.string(sa.get("pts[1].y")), "4");
    eq("elem field second", Std.string(sa.get("pts[0].x")), "1");
    ok("elem field write", sa.set("pts[2].x", 50), "");
    eq("elem field write back", Std.string(sa.get("pts[2].x")), "50");
    eq("native sees write", Std.string(sa.callAuto("totalx", [])), "61");
    eq("elem out of range", Std.string(sa.get("pts[9].x")), "0");
    ok("elem out of range write ignored", sa.set("pts[9].x", 123) && sa.get("pts[9].x") == 0, "");
    eq("nested field read", Std.string(sa.get("box.pos.x")), "10");
    eq("nested field deep", Std.string(sa.get("box.vel.y")), "2");
    eq("nested plain field", Std.string(sa.get("box.tag")), "7");
    ok("nested field write", sa.set("box.pos.y", 25), "");
    eq("nested field write back", Std.string(sa.get("box.pos.y")), "25");
    ok("leaf fields listed", sa.leafFieldsOf("box").indexOf("pos.x") >= 0, sa.leafFieldsOf("box").join(","));
    ok("bad path rejected", sa.set("pts[1]", 3) == false, "");

    var ssa = new JitSession("sessarr");
    ok("session struct array compiles", ssa.eval("
struct V2 { double x; double y; };
V2 path[4];
double peekx() { return path[1].x; }
"), ssa.lastError);
    ssa.set("path[1].x", 42);
    ok("session rebuild keeps struct array", ssa.eval("double extra() { return 1; }\n"), ssa.lastError);
    eq("session element restored", Std.string(ssa.get("path[1].x")), "42");
    eq("session element seen natively", Std.string(ssa.module.callAuto("peekx", [])), "42");

    head("pointer and string members");
    var ps = Jit.compile("members", '
struct Node { double v; Node* next; const char* name; };
Node na; Node nb;
void link() { na.v = 1; nb.v = 2; na.next = &nb; nb.next = 0; na.name = "root"; nb.name = "leaf"; }
const char* greeting() { return "hello"; }
');
    ok("member module compiles", ps.ok, ps.diag.length > 0 ? JitCompiler.describe(ps.diag[0]) : "");
    ps.callAuto("link", []);
    eq("pointer member set", Std.string(ps.get("na.next") != 0), "true");
    eq("pointer member walk", Std.string(new JitPtr(ps.get("na.next")).readF64()), "2");
    eq("pointer member null", Std.string(ps.get("nb.next")), "0");
    ok("pointer member write", ps.set("nb.next", ps.get("&na")), "");
    eq("pointer member write back", Std.string(new JitPtr(ps.get("nb.next")).readF64()), "1");
    eq("string member read", ps.str("na.name"), "root");
    eq("string member second", ps.str("nb.name"), "leaf");
    eq("struct address", Std.string(ps.get("&na") != 0), "true");
    eq("string return is address", Std.string(ps.callAuto("greeting", []) != 0), "true");
    eq("string return value", ps.callStr("greeting"), "hello");
    eq("pointer read string", new JitPtr(ps.callAuto("greeting", [])).readStr(), "hello");
    eq("string member missing is empty", ps.str("na.nosuch"), "");

    head("struct by value");
    var bv = Jit.compile("byvalue", '
struct Vec2 { double x; double y; };
Vec2 gv;
void setv(double x, double y) { gv.x = x; gv.y = y; }
double len2(Vec2 v) { return v.x + v.y; }
double scale2(Vec2 v, double k) { return (v.x + v.y) * k; }
Vec2 mk(double x, double y) { Vec2 r; r.x = x; r.y = y; return r; }
double len3(const Vec2& v) { return v.x * 3 + v.y; }
void bump(Vec2& v) { v.x = v.x + 10; }
');
    ok("by value module compiles", bv.ok, bv.diag.length > 0 ? JitCompiler.describe(bv.diag[0]) : "");
    bv.callAuto("setv", [3, 4]);
    eq("by value single", Std.string(bv.callAuto("len2", [bv.get("&gv")])), "7");
    eq("by value with scalar", Std.string(bv.callAuto("scale2", [bv.get("&gv"), 2])), "14");
    eq("by value via explicit sig", Std.string(bv.callSig("len2", "d(t)", [bv.get("&gv")])), "7");
    ok("by value bound handle", Std.string(bv.bind("len2").call(bv.get("&gv"))) == "7", "");
    var rv = bv.callStruct("mk", [5, 6]);
    eq("struct return x", Std.string(rv.readF64(0)), "5");
    eq("struct return y", Std.string(rv.readF64(8)), "6");
    eq("struct return through callAuto", Std.string(bv.callAuto("mk", [7, 8]) != 0), "true");
    var ring1 = bv.callStruct("mk", [11, 12]);
    var ring2 = bv.callStruct("mk", [21, 22]);
    eq("ring keeps earlier result", Std.string(ring1.readF64(0)), "11");
    eq("ring keeps later result", Std.string(ring2.readF64(8)), "22");
    eq("struct return second field", Std.string(new JitPtr(bv.callAuto("mk", [9, 10])).readF64(8)), "10");
    eq("const reference parameter", Std.string(bv.callAuto("len3", [bv.get("&gv")])), "13");
    ok("mutable reference parameter", bv.callAuto("bump", [bv.get("&gv")]) == 0 && bv.get("gv.x") == 13, "");

    head("references and string members");
    var rf = Jit.compile("refs", '
struct Rec { std::string name; double score; };
Rec item;
int counter = 21;
void bump(int& x) { x = x + 1; }
double doubled(const int& x) { return x * 2; }
double namelen(const std::string& s) { return (double)s.size(); }
void rename(const std::string& s) { item.name = s; }
');
    ok("references module compiles", rf.ok, rf.diag.length > 0 ? JitCompiler.describe(rf.diag[0]) : "");
    rf.set("counter", 21);
    ok("scalar reference write", rf.callAuto("bump", [rf.get("&counter")]) == 0 && rf.get("counter") == 22, "");
    eq("const scalar reference", Std.string(rf.callAuto("doubled", [rf.get("&counter")])), "44");
    eq("const string reference", Std.string(rf.callAuto("namelen", [], ["hello"])), "5");
    ok("string member write", rf.setStr("item.name", "alpha"), "");
    eq("string member read", rf.str("item.name"), "alpha");
    rf.callAuto("rename", [], ["beta"]);
    eq("string member seen natively", rf.str("item.name"), "beta");
    eq("string member length", Std.string(rf.callAuto("namelen", [0], [rf.str("item.name")])), "4");
    ok("string member rejects missing", !rf.setStr("item.nosuch", "x"), "");

    head("exceptions, defaults and overloads");
    var xm = Jit.compile("extras", '
#include <stdexcept>
double boom(double v) { if (v > 0) throw std::runtime_error("boom"); return v; }
double dft(double a, double b = 10, double c = 100) { return a + b + c; }
void shout(std::string& s) { s += "!"; }
int tv(int v) { return v + 100; }
double tv(double v) { return v + 0.5; }
');
    ok("extras module compiles", xm.ok, xm.diag.length > 0 ? JitCompiler.describe(xm.diag[0]) : "");
    JitHost.capture = true;
    eq("cpp exception is trapped", Std.string(xm.callAuto("boom", [1])), "0");
    ok("exception message reaches the log", JitHost.logs.join(" ").indexOf("boom") >= 0, JitHost.logs.join(" ").substr(0, 60));
    eq("no exception path", Std.string(xm.callAuto("boom", [-1])), "-1");
    eq("two defaults filled", Std.string(xm.callAuto("dft", [1])), "111");
    eq("one default filled", Std.string(xm.callAuto("dft", [1, 2])), "103");
    eq("all arguments given", Std.string(xm.callAuto("dft", [1, 2, 3])), "6");
    eq("mutable string reference", xm.callStr("shout", [], ["hi"]), "hi!");

    var pw = Jit.compile("pairstr", '
#include <string>
std::string tag(std::string& s) { s += "+"; return std::string("ret:"); }
');
    ok("pair string module", pw.ok, pw.diag.length > 0 ? JitCompiler.describe(pw.diag[0]) : "");
    var pair = pw.callStrBoth("tag", [], ["v"]);
    eq("return string kept", pair.a, "ret:");
    eq("written back string kept", pair.b, "v+");

    var pw = Jit.compile("pairstr", '
#include <string>
std::string tag(std::string& s) { s += "+"; return std::string("ret:"); }
');
    ok("pair string module", pw.ok, pw.diag.length > 0 ? JitCompiler.describe(pw.diag[0]) : "");
    var pair = pw.callStrBoth("tag", [], ["v"]);
    eq("return string kept", pair.a, "ret:");
    eq("written back string kept", pair.b, "v+");
    eq("typed overload picks int", Std.string(xm.callDyn("tv", [1])), "101");
    eq("typed overload picks double", Std.string(xm.callDyn("tv", [1.5])), "2");

    head("expressions");
    var ex = Jit.compile("exprm", "
double ax = 3; double ay = 4;
");
    ok("expression module", ex.ok, "");
    eq("expr path sum", Std.string(ex.get("ax + ay")), "7");
    eq("expr scales", Std.string(ex.expr("(ax + ay) * 2")), "14");
    eq("expr sqrt", Std.string(ex.expr("sqrt(ax*ax + ay*ay)")), "5");
    eq("expr compare", Std.string(ex.expr("ax < ay")), "1");
    eq("expr ternary", Std.string(ex.expr("ax > ay ? 10 : 20")), "20");
    eq("expr functions", Std.string(ex.expr("max(ax, ay) + min(ax, ay)")), "7");
    eq("expr clamp", Std.string(ex.expr("clamp(9, 0, 5)")), "5");
    eq("expr unary", Std.string(ex.expr("-ax + 1")), "-2");
    ok("expr unknown is nan", ex.expr("nope + 1") != ex.expr("nope + 1"), "");
    ok("expr divide by zero is nan", ex.expr("ax / 0") != ex.expr("ax / 0"), "");
    ok("expr trailing junk is nan", ex.expr("ax +") != ex.expr("ax +"), "");

    var ef = Jit.compile("exprfn", "double scale(double v, double k) { return v * k; }
double base = 2;
");
    ok("expr function module", ef.ok, "");
    eq("expr calls module function", Std.string(ef.expr("scale(3, 4)")), "12");
    eq("expr mixes function and variable", Std.string(ef.expr("scale(base, 2) + 1")), "5");
    ok("expr unknown function is nan", ef.expr("nosuch(1)") != ef.expr("nosuch(1)"), "");

    var ebx = Jit.compile("exprbits", '
struct Bag { std::string label; int mask; };
Bag bag;
');
    ok("bits module compiles", ebx.ok, ebx.diag.length > 0 ? JitCompiler.describe(ebx.diag[0]) : "");
    ebx.set("bag.mask", 12);
    eq("bit and", Std.string(ebx.expr("bag.mask & 10")), "8");
    eq("bit or", Std.string(ebx.expr("bag.mask | 3")), "15");
    eq("bit xor", Std.string(ebx.expr("bag.mask ^ 12")), "0");
    eq("shift left", Std.string(ebx.expr("1 << 4")), "16");
    eq("shift right", Std.string(ebx.expr("256 >> 3")), "32");
    eq("bit not", Std.string(ebx.expr("~0")), "-1");
    ok("string member write", ebx.setStr("bag.label", "hello"), "");
    eq("string expression", ebx.exprStr("bag.label"), "hello");
    eq("string concat", ebx.exprStr('bag.label + " world"'), "hello world");
    eq("string compare", Std.string(ebx.expr('bag.label == "hello"')), "1");
    eq("string length function", Std.string(ebx.expr("strlen(bag.label)")), "5");
    eq("string upper function", ebx.exprStr("upper(bag.label)"), "HELLO");
    eq("string literal compare", Std.string(ebx.expr('"x" == "x"')), "1");
    eq("mixed concat", ebx.exprStr('"a" + 1 + "b"'), "a1b");
    eq("string not found", ebx.exprStr('"abc" == "abd"'), "0");

    var ov = Jit.compile("overloads", "double pick1(double v) { return v + 1; }
double pick1(double a, double b) { return a * b; }
");
    ok("overload module", ov.ok, ov.diag.length > 0 ? JitCompiler.describe(ov.diag[0]) : "");
    eq("overload one argument", Std.string(ov.callAuto("pick1", [3])), "4");
    eq("overload two arguments", Std.string(ov.callAuto("pick1", [3, 4])), "12");
    eq("overload explicit sig", Std.string(ov.callSig("pick1", "d(dd)", [3, 4])), "12");

    head("bound handles");
    var bh = Jit.compile("bound", "double add(double a, double b) { return a + b; }\ndouble twice(double v) { return v * 2; }\n");
    var bf = bh.bind("add");
    ok("bind resolves", bf.valid(), bf.name + " " + bf.sig);
    eq("bound call", Std.string(bf.call(2, 3)), "5");
    var bg = bh.bind("twice");
    eq("bound single arg", Std.string(bg.call(21)), "42");
    ok("bind missing is invalid", !bh.bind("nope").valid(), "");
    ok("bind wrong sig is invalid", !bh.bind("add", "i(dd)").valid(), "");
    var repsB = 200000;
    var tB = Sys.time();
    var accB:Float = 0;
    for (i in 0...repsB) accB += bf.call(i, 1);
    var bUs = (Sys.time() - tB) * 1000000.0 / repsB;
    ok("bound call is fast", bUs < 0.5 && accB > 0, Jit.f3(bUs) + "us/call");

    head("multiple translation units");
    var mdir = Sys.getCwd() + "/multitu";
    if (!sys.FileSystem.exists(mdir)) sys.FileSystem.createDirectory(mdir);
    sys.io.File.saveContent(mdir + "/shared.h", "inline double sq(double v) { return v * v; }\n");
    sys.io.File.saveContent(mdir + "/main.cpp", "#include \"shared.h\"\ndouble quad(double v) { return sq(v) * 2; }\n");
    sys.io.File.saveContent(mdir + "/extra.cpp", "#include \"shared.h\"\ndouble twice(double v) { return v * 2; }\ndouble quadplus(double v) { return sq(v) * 2 + 1; }\n");
    var mm = Jit.compileFiles("multi", mdir + "/main.cpp", [mdir + "/extra.cpp"], {includes: [mdir]});
    ok("multi file compiles", mm.ok, mm.diag.length > 0 ? JitCompiler.describe(mm.diag[0]) + " | " + mm.log : mm.log);
    eq("main unit with local include", Std.string(mm.callAuto("quad", [3])), "18");
    eq("linked unit exported", Std.string(mm.callAuto("twice", [4])), "8");
    eq("linked unit with include", Std.string(mm.callAuto("quadplus", [3])), "19");
    ok("multi file lists both", mm.fnNames().indexOf("twice") >= 0 && mm.fnNames().indexOf("quad") >= 0, mm.fnNames().join(","));
    var rm = Jit.reload("multi");
    ok("multi file reload keeps units", rm != null && rm.ok && rm.callAuto("twice", [5]) == 10, rm == null ? "null" : "ok=" + rm.ok);

    sys.io.File.saveContent(mdir + "/gmain.cpp", "struct P { double x; double y; };
double quad(double v) { return v * 2; }
");
    sys.io.File.saveContent(mdir + "/gextra.cpp", "struct P { double x; double y; };
double counter = 5;
int hits[3] = {1,2,3};
P anchor = {7,8};
double alive() { return counter + hits[1]; }
");
    var mg = Jit.compileFiles("multiglob", mdir + "/gmain.cpp", [mdir + "/gextra.cpp"]);
    ok("extra unit globals compile", mg.ok, mg.diag.length > 0 ? JitCompiler.describe(mg.diag[0]) + " | " + mg.log : mg.log);
    eq("extra scalar read", Std.string(mg.get("counter")), "5");
    ok("extra scalar write", mg.set("counter", 9), "");
    eq("extra scalar seen natively", Std.string(mg.callAuto("alive", [])), "11");
    eq("extra array element", Std.string(mg.get("hits[1]")), "2");
    ok("extra array write", mg.set("hits[2]", 40), "");
    eq("extra array write back", Std.string(mg.get("hits[2]")), "40");
    eq("extra struct field", Std.string(mg.get("anchor.y")), "8");

    head("elf parser");
    var eb = haxe.io.Bytes.alloc(120);
    eb.set(0, 0x7F);
    eb.set(1, 0x45);
    eb.set(2, 0x4C);
    eb.set(3, 0x46);
    eb.set(4, 2);
    eb.set(5, 1);
    eb.setUInt16(16, 3);
    eb.setUInt16(18, 0x3E);
    eb.setInt32(32, 64);
    eb.setUInt16(54, 56);
    eb.setUInt16(56, 1);
    eb.setInt32(64, 1);
    eb.setInt32(64 + 4, 5);
    eb.setInt32(64 + 32, 4096);
    eb.setInt32(64 + 40, 8192);
    var ei = JitElf.parse(eb);
    ok("elf header parsed", ei.ok, ei.error);
    eq("elf phnum", Std.string(ei.phnum), "1");
    eq("elf machine", Std.string(ei.machine), "62");
    eq("elf load memsz", Std.string(Std.int(ei.phdrs[0].memsz)), "8192");
    ok("elf rejects short input", !JitElf.parse(haxe.io.Bytes.alloc(8)).ok, "");
    ok("elf manual map reports platform", !JitElf.load(mdir + "/extra.cpp").ok, "");
    ok("elf without tls", !JitElf.tls(ei), "");
    var tb = haxe.io.Bytes.alloc(64 + 112);
    tb.set(0, 0x7F);
    tb.set(1, 0x45);
    tb.set(2, 0x4C);
    tb.set(3, 0x46);
    tb.set(4, 2);
    tb.set(5, 1);
    tb.setUInt16(16, 3);
    tb.setUInt16(18, 0x3E);
    tb.setInt32(32, 64);
    tb.setUInt16(54, 56);
    tb.setUInt16(56, 2);
    tb.setInt32(64, 1);
    tb.setInt32(64 + 32, 4096);
    tb.setInt32(64 + 40, 8192);
    tb.setInt32(120, 7);
    tb.setInt32(120 + 32, 32);
    tb.setInt32(120 + 40, 32);
    var tinfo = JitElf.parse(tb);
    ok("elf tls detected", tinfo.ok && JitElf.tls(tinfo), tinfo.error);
    var rb = haxe.io.Bytes.alloc(24);
    rb.setInt32(0, 0x1000);
    rb.setInt32(8, 3);
    rb.setInt32(16, 0x2000);
    var tg = JitElf.relrTargets(rb, 0, 24);
    eq("relr direct slot", Std.string(Std.int(tg[0])), "4096");
    eq("relr bitmap slot", Std.string(Std.int(tg[1])), "4104");
    eq("relr resumes", Std.string(Std.int(tg[2])), "8192");

    head("thread local blocks");
    var seed = haxe.io.Bytes.alloc(8);
    seed.setInt32(0, 0x11223344);
    seed.setInt32(4, 0x55667788);
    var tid = JitNative.tlsRegister(32, JitLoader.ptrOf(seed), 8);
    ok("tls registered", tid > 0, "id=" + tid);
    var tblock = JitNative.tlsBlock(tid);
    ok("tls block allocated", tblock != 0, "");
    eq("tls init copied", Std.string(Std.int(JitNative.peek(tblock, 4))), Std.string(0x11223344));
    eq("tls second word", Std.string(Std.int(JitNative.peek(JitNative.toSizeT(JitNative.toFloat(tblock) + 4), 4))), Std.string(0x55667788));
    eq("tls zero filled", Std.string(Std.int(JitNative.peek(JitNative.toSizeT(JitNative.toFloat(tblock) + 8), 4))), "0");
    ok("tls resolver address", JitNative.tlsAddr() != 0, "");
    eq("tls block is per thread copy", Std.string(JitNative.tlsBlock(tid) == tblock), "true");

    head("string globals");
    var sg = Jit.compile("strglob", '
#include <string>
std::string title = "boot";
const char* label = "ready";
void retitle() { title = "hot"; }
');
    ok("string globals compile", sg.ok, sg.diag.length > 0 ? JitCompiler.describe(sg.diag[0]) : "");
    eq("string global kind", sg.kindOf("title"), "sstr");
    eq("string global read", sg.str("title"), "boot");
    ok("string global write", sg.setStr("title", "run"), "");
    eq("string global written", sg.str("title"), "run");
    sg.callAuto("retitle", []);
    eq("string global seen natively", sg.str("title"), "hot");
    eq("char pointer global", sg.str("label"), "ready");

    head("pointer arrays");
    var pa = Jit.compile("ptrarr", '
int a = 7; int b = 8;
int* slots[4];
void wire() { slots[0] = &a; slots[1] = &b; }
');
    ok("pointer array compiles", pa.ok, pa.diag.length > 0 ? JitCompiler.describe(pa.diag[0]) : "");
    pa.callAuto("wire", []);
    var pv = Std.string(new JitPtr(pa.get("slots[1]")).readI32());
    var pw = pa.set("slots[2]", pa.get("&a"));
    eq("pointer array round trip", pv + "/" + Std.string(new JitPtr(pa.get("slots[2]")).readI32()) + "/" + Std.string(pa.elemSize("slots")), "8/7/8");
    ok("pointer array writes", pw, "");
    eq("numeric array still works", Std.string(pa.get("slots[3]")), "0");

    head("array members");
    var am2 = Jit.compile("arrmem", '
struct Grid { double row[3]; int tag; };
Grid g;
Grid gs[2];
void fill() { g.row[0] = 1; g.row[1] = 2; g.row[2] = 3; gs[1].row[2] = 9; }
');
    ok("array member compiles", am2.ok, am2.diag.length > 0 ? JitCompiler.describe(am2.diag[0]) : "");
    am2.callAuto("fill", []);
    var mw = am2.set("g.row[0]", 5);
    var ew = am2.set("gs[0].row[1]", 4);
    eq("member array round trip", Std.string(am2.get("g.row[1]")) + "/" + Std.string(am2.get("g.row[0]")) + "/" + Std.string(am2.get("g.row[7]")), "2/5/0");
    eq("element array round trip", Std.string(am2.get("gs[1].row[2]")) + "/" + Std.string(am2.get("gs[0].row[1]")), "9/4");
    ok("member array writes", mw && ew, "");

    head("callbacks");
    var pb = Jit.compile("cbprobe", '
double probe(double (*f)(double), double v) { return v; }
double probe2(double a, double v) { return v; }
');
    ok("probe compiles", pb.ok, pb.diag.length > 0 ? JitCompiler.describe(pb.diag[0]) : "");
    eq("pointer param keeps second arg", Std.string(pb.callAuto("probe", [1.0, 9])), "9");
    eq("numeric param keeps second arg", Std.string(pb.callAuto("probe2", [1.0, 9])), "9");
    eq("probe sig", pb.signature("probe"), "d(pd)");
    Jit.bind("half", function(a0:Float, a1:Float, a2:Float, a3:Float):Float return a0 * 0.5);
    Jit.bind("plusone", function(a0:Float, a1:Float, a2:Float, a3:Float):Float return a0 + 1);
    var cbm = Jit.compile("cbtake", '
double apply1(double (*f)(double), double v) { return f(v); }
double apply2(int (*f)(int), double v) { return (double)f((int)v); }
');
    ok("callback host compiles", cbm.ok, cbm.diag.length > 0 ? JitCompiler.describe(cbm.diag[0]) : "");
    var fp1 = Jit.callback("half", "d(d)");
    ok("callback pointer built", fp1 != 0, "");
    eq("callback invoked", Std.string(cbm.callAuto("apply1", [fp1, 9])), "4.5");
    var fp2 = Jit.callback("plusone", "i(i)");
    eq("second callback invoked", Std.string(cbm.callAuto("apply2", [fp2, 41])), "42");
    Jit.bind("label", function(a0:Float, a1:Float, a2:Float, a3:Float):Dynamic return "len" + Std.int(a0));
    var cstr = Jit.compile("cbstr", 'int slen(const char* (*f)(double), double v) { const char* s = f(v); int n = 0; while (s[n]) n++; return n; }');
    ok("string callback host compiles", cstr.ok, cstr.diag.length > 0 ? JitCompiler.describe(cstr.diag[0]) : "");
    var fsp = Jit.callback("label", "s(d)");
    ok("string callback built", fsp != 0, "");
    eq("string callback text", Std.string(cstr.callAuto("slen", [fsp, 3])), "4");

    head("lifecycle and threads");
    var lm = Jit.compile("lifecycle", 'int one() { return 1; }');
    var lf = lm.bind("one");
    ok("bound handle valid", lf.valid(), "");
    Jit.dispose("lifecycle");
    ok("handle invalid after dispose", !lf.valid(), "");
    eq("stale handle returns zero", Std.string(lf.call()), "0");

    var tm = Jit.compile("threaded", 'double scale(double v) { return v * 2; }');
    var slots = [0.0, 0.0];
    for (i in 0...2) {
      var idx = i;
      Thread.create(function() {
        var acc = 0.0;
        for (k in 0...200) acc += tm.callAuto("scale", [k * 1.0]);
        slots[idx] = acc;
      });
    }
    var spin = 0;
    while ((slots[0] == 0 || slots[1] == 0) && spin < 2000) {
      Sys.sleep(0.01);
      spin++;
    }
    eq("concurrent calls agree", Std.string(slots[0] + slots[1]), "79600");

    head("cache cleanup");
    var pm2 = Jit.compile("prune", "double one() { return 1; }\n");
    ok("prune module compiles", pm2.ok, pm2.diag.length > 0 ? JitCompiler.describe(pm2.diag[0]) : "");
    var kdir = Jit.cache.dirFor(pm2.key);
    for (i in 0...4) Jit.reload("prune", {force: true});
    for (i in 0...8) Jit.tick();
    var stray = kdir + "/mod" + Jit.cache.ext() + ".123.tmp";
    sys.io.File.saveContent(stray, "x");
    var freed = Jit.clean();
    var bins = [for (f in sys.FileSystem.readDirectory(kdir)) if (StringTools.endsWith(f, Jit.cache.ext())) f];
    ok("old binaries pruned", bins.length <= 2, bins.join(","));
    ok("clean drops temp files", freed > 0 && !sys.FileSystem.exists(stray), "freed=" + freed);
    ok("clean keeps the newest binary", sys.FileSystem.exists(Jit.cache.dllFor(pm2.key) ?? ""), "");
    eq("no half written sources left", Std.string(countSuffix(Jit.cache.root, ".w")), "0");
    eq("no pch leftovers", Std.string(countSuffix(Jit.cache.root + "/pch", ".tmp")), "0");

    head("throughput");
    var pm = Jit.compile("perf", "RJIT(mix) { double s = 0; for (int i = 0; i < 8; i++) s += (double)i * RJIT_A0; return s; }\n");
    var reps = 500000;
    var acc:Float = 0;
    var t1 = Sys.time();
    for (i in 0...reps) acc += pm.call("mix", 1.0);
    var us = (Sys.time() - t1) * 1000000.0 / reps;
    ok("500k calls", acc == 28.0 * reps, Jit.f3(us) + "us/call  acc=" + Std.int(acc));

    head("stability");
    for (i in 0...20) Jit.tick();
    var broken = 0;
    for (x in Jit.all()) if (!x.ok) broken++;
    ok("no broken modules", broken == 0, broken + " broken");

    out.add("\n[jit] RESULT " + (fail == 0 ? "PASS" : "FAIL") + "  (" + pass + " passed, " + fail + " failed)\n");
    out.add(Jit.stats());
    Sys.println(out.toString());
    try {
      sys.io.File.saveContent("test-report.txt", out.toString());
    } catch (e:Dynamic) {}
  }
}
