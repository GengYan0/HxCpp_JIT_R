import hxcpp_jit_r.Jit;
import hxcpp_jit_r.JitHost;
import hxcpp_jit_r.JitNative;
import hxcpp_jit_r.JitSession;
import hxcpp_jit_r.JitCompiler;

class Main {
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
    if (!Jit.setup({cache: "jitcache", opt: "O2"})) {
      Sys.println("setup failed: " + Jit.lastError);
      return;
    }
    out.add("  " + Jit.tool.summary() + "\n");
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
    var crashMsg:String = null;
    hxcpp_jit_r.JitHost.onError = function(method:String, n:String, msg:String) {
      crashMsg = method + "/" + n;
    };
    var cm = Jit.compile("crash", "double boom(double x) { volatile int* p = 0; *p = 1; return x; }\n");
    ok("crash module compiled", cm.ok);
    eq("crash returns 0", Std.string(cm.callAuto("boom", [1])), "0");
    eq("onError fired", Std.string(crashMsg), "callAuto/boom");
    hxcpp_jit_r.JitHost.onError = null;

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
    eq("lens cn utf8", Std.string(sm.callAuto("lens", [], ["\u4e2d\u6587"])), "6");
    eq("mixs int+str", Std.string(sm.callAuto("mixs", [10], ["abcd"])), "14");
    eq("adds two strings", Std.string(sm.callAuto("adds", [], ["abc", "de"])), "5");
    eq("first char", Std.string(sm.callAuto("first", [], ["A"])), "65");
    eq("empty string len", Std.string(sm.callAuto("lens", [], [""])), "0");
    eq("missing str arg", Std.string(sm.callAuto("lens", [], [])), "0");

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

    head("manual pe loader");
    var manSrc = "int sq(int x) { return x * x; }\nint add3(int a, int b, int c) { return a + b + c; }\ndouble half(double v) { return v / 2; }\n";
    var mp = Jit.compile("man", manSrc, {loader: "manual"});
    ok("manual compile+load", mp.ok, mp.diag.length > 0 ? JitCompiler.describe(mp.diag[0]) : "");
    if (mp.ok && mp.pe != null) {
      var pe = mp.pe;
      ok("manual mapped", pe.manual, "sections=" + pe.sections.length + " imports=" + pe.imports.join("+") + " reloc=" + pe.relocCount + " rebased=" + pe.rebased);
      eq("manual sq(7)", Std.string(mp.callAuto("sq", [7])), "49");
      eq("manual add3", Std.string(mp.callAuto("add3", [1, 2, 3])), "6");
      var top = Jit.compile("man2", "double tri(double v) { return v * 3; }\n", {loader: "manual"});
      ok("manual second module", top.ok, top.diag.length > 0 ? JitCompiler.describe(top.diag[0]) : "");
      eq("manual tri", Std.string(top.callAuto("tri", [5])), "15");
      Jit.dispose("man2");
    } else {
      ok("manual mapped", false, "pe missing");
    }
    var manMod = Jit.get("man");
    var manBase:cpp.SizeT = (manMod != null && manMod.pe != null) ? manMod.pe.base : 0;
    Jit.dispose("man");
    for (i in 0...6) Jit.tick();
    ok("manual unloaded", manBase != 0 && hxcpp_jit_r.JitPe.find(manBase) == null, "base=" + JitNative.toFloat(manBase) + " images=" + hxcpp_jit_r.JitPe.count());
    var lb = Jit.compile("loadlib", "int six() { return 6; }\n", {loader: "loadlib"});
    eq("loadlib still works", Std.string(lb.callAuto("six", [])), "6");

    head("pack export / import");
    var pf = Jit.exportPack("packout");
    ok("export files", pf > 0, pf + " files");
    var pi = Jit.packInfo("packout");
    ok("pack manifest ok", StringTools.startsWith(pi, "pack ok"), pi);
    ok("manifest exists", sys.FileSystem.exists("packout/manifest.json"));
    var strsMod = Jit.get("strs");
    ok("headline dll packed", strsMod != null && sys.FileSystem.exists("packout/" + strsMod.key + "/mod.dll"));

    head("cache-only mode (no toolchain)");
    var coldSrc = "double twice(double v) { return v * 2; }\n";
    var c1 = Jit.compile("cold", coldSrc);
    ok("cold compile", c1.ok);
    Jit.exportPack("packcold");
    hxcpp_jit_r.JitToolchain.forceUnavailable = true;
    var coldDir = "coldcache_" + Std.string(Std.random(1000000));
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
    Jit.setup({cache: "jitcache"});
    ok("toolchain restored", Jit.ready);

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
