package hxcpp_jit_r;

@:keep
class JitBoot {
  public static var report:String = "";
  public static var ok:Bool = false;

  static var started:Bool = run();

  static function run():Bool {
    var b = new StringBuf();
    try {
      Jit.verbose = true;
      Jit.setup({cache: "userdata/jitcache"});
      b.add(Jit.stats());
      #if jit_selftest
      b.add(Jit.selfTest());
      try {
        b.add(probe());
      } catch (e:Dynamic) {
        b.add("[jit] probe crash: " + Std.string(e) + "\n");
      }
      #end
      report = b.toString();
      ok = Jit.ready;
      Sys.println(report);
      try {
        if (!sys.FileSystem.exists("userdata")) sys.FileSystem.createDirectory("userdata");
        sys.io.File.saveContent("userdata/jit_report.txt", report);
      } catch (e:Dynamic) {}
    } catch (e:Dynamic) {
      report = b.toString() + "jit boot failed: " + Std.string(e);
      Sys.println(report);
      try sys.io.File.saveContent("userdata/jit_report.txt", report) catch (e2:Dynamic) {}
    }
    return true;
  }

  static function probe():String {
    var b = new StringBuf();
    var m = Jit.compile("autoprobe", 'int cnt = 0;
double half(double x) { return x / 2; }
void bump() { cnt += 1; }
struct Pt { double x; double y; };
Pt p;
double arr[3];
int slen(const char* s) { return (int)strlen(s); }
int scat(std::string a, std::string b) { return (int)(a.size() + b.size()); }
');
    b.add("[jit] auto ok=" + m.ok + " diag=" + m.diag.length + "\n");
    if (!m.ok) {
      for (d in m.diag) b.add("[jit]   " + d.kind + " " + d.code + " line " + d.line + "\n");
      return b.toString();
    }
    b.add("[jit] half(10)=" + m.callAuto("half", [10]) + " sig=" + m.signature("half") + "\n");
    b.add("[jit] slen(cstr)=" + m.callAuto("slen", [], ["hello"]) + " sig=" + m.signature("slen") + "\n");
    b.add("[jit] scat(S,S)=" + m.callAuto("scat", [], ["abc", "de"]) + " sig=" + m.signature("scat") + "\n");
    m.callAuto("bump", []);
    m.callAuto("bump", []);
    b.add("[jit] cnt=" + m.getVar("cnt") + "\n");
    m.setVar("cnt", 50);
    b.add("[jit] cnt set=" + m.getVar("cnt") + "\n");
    m.set("p.x", 2.5);
    m.set("arr[1]", 7);
    b.add("[jit] p.x=" + m.get("p.x") + " arr[1]=" + m.get("arr[1]") + "\n");

    var man = Jit.compile("peprobe", "int sq(int v) { return v * v; }\n", {loader: "manual"});
    var mapped = man.image != null && man.image.manual;
    b.add("[jit] manual ok=" + man.ok + " mapped=" + mapped + " sq(9)=" + (man.ok ? m2s(man.callAuto("sq", [9])) : "n/a") + "\n");
    if (mapped) b.add("[jit] image sections=" + man.image.sections.length + " reloc=" + man.image.relocCount + " rebased=" + man.image.rebased + " imports=" + man.image.imports.join("+") + "\n");
    if (man.ok) {
      Jit.dispose("peprobe");
      for (i in 0...5) Jit.tick();
      b.add("[jit] manual unloaded images=" + JitLoader.count() + "\n");
    }
    return b.toString();
  }

  static function m2s(v:Float):String {
    return Std.string(Std.int(v));
  }
}
