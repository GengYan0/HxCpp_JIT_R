package hxcpp_jit_r;

import sys.FileSystem;

class JitToolchain {
  public var exe:String = "";
  public var backend:String = "msvc";
  public var inc:Array<String> = [];
  public var lib:Array<String> = [];
  public var bin:Array<String> = [];
  public var msvc:String = "";
  public var sdk:String = "";
  public var arch:String = "x64";
  public var host:String = "HostX64/x64";
  public var ready:Bool = false;
  public var error:String = "";
  public var origin:String = "";
  public static var forceUnavailable:Bool = false;

  public function new() {}

  public function apply():Void {
    if (!ready) return;
    #if windows
    if (inc.length > 0) Sys.putEnv("INCLUDE", inc.join(";"));
    if (lib.length > 0) Sys.putEnv("LIB", lib.join(";"));
    if (bin.length > 0) Sys.putEnv("PATH", bin.join(";") + ";" + (Sys.getEnv("PATH") ?? ""));
    Sys.putEnv("VSLANG", "1033");
    #end
  }

  public function summary():String {
    if (!ready) return "toolchain unavailable: " + error;
    return 'backend=$backend exe=$exe arch=$arch origin=$origin';
  }

  public static function detect(prefer:String = "auto"):JitToolchain {
    if (forceUnavailable) {
      var d = new JitToolchain();
      d.error = "toolchain disabled by forceUnavailable";
      return d;
    }
    #if windows
    return detectWindows(prefer);
    #else
    return detectPosix(prefer);
    #end
  }

  #if windows
  static function detectWindows(prefer:String):JitToolchain {
    var t = new JitToolchain();
    var is64 = #if HXCPP_M32 false #else true #end;
    t.arch = is64 ? "x64" : "x86";
    t.host = is64 ? "HostX64/x64" : "HostX86/x86";
    var envInc = Sys.getEnv("INCLUDE");
    var envLib = Sys.getEnv("LIB");
    var envCl = which("cl.exe");

    if (envCl != null && envInc != null && envLib != null && envInc.length > 4) {
      t.exe = envCl;
      t.backend = "msvc";
      t.inc = splitEnv(envInc);
      t.lib = splitEnv(envLib);
      t.msvc = Sys.getEnv("VCToolsInstallDir") ?? "";
      t.sdk = Sys.getEnv("WindowsSdkDir") ?? "";
      for (d in splitEnv(Sys.getEnv("PATH") ?? "")) {
        var n = d.toLowerCase();
        if (n.indexOf("/vc/tools/msvc/") >= 0 || n.indexOf("/windows kits/") >= 0) t.bin.push(d);
      }
      t.bin.push(dirOf(envCl));
      t.ready = true;
      t.origin = "environment";
      if (prefer == "clang") pickClang(t);
      return t;
    }

    for (root in vsRoots()) {
      var m = pickMsvc(root);
      if (m == null) continue;
      var cl = root + "/VC/Tools/MSVC/" + m.ver + "/bin/" + t.host + "/cl.exe";
      if (!FileSystem.exists(cl)) continue;
      var s = pickSdk();
      if (s == null) continue;
      t.exe = cl;
      t.backend = "msvc";
      t.msvc = m.dir;
      t.sdk = s.dir;
      var sdkInc = s.dir + "/Include/" + s.ver;
      var sdkLib = s.dir + "/Lib/" + s.ver;
      t.inc = [
        m.dir + "/include",
        sdkInc + "/ucrt",
        sdkInc + "/um",
        sdkInc + "/shared",
        sdkInc + "/winrt",
        sdkInc + "/cppwinrt"
      ];
      t.lib = [
        m.dir + "/lib/" + t.arch,
        sdkLib + "/ucrt/" + t.arch,
        sdkLib + "/um/" + t.arch
      ];
      t.bin = [
        m.dir + "/bin/" + t.host,
        s.dir + "/bin/" + s.ver + "/" + t.arch
      ];
      t.ready = true;
      t.origin = root;
      if (prefer == "clang" && pickClang(t)) t.origin = root + " + clang";
      return t;
    }

    t.error = "no MSVC toolchain found (cl.exe not on PATH and no Visual Studio install detected)";
    return t;
  }

  static function pickClang(t:JitToolchain):Bool {
    var cands:Array<String> = [];
    var p = which("clang-cl.exe");
    if (p != null) cands.push(p);
    if (t.msvc != "") {
      var root = parentOf(t.msvc, 3);
      if (root != null) cands.push(root + "/Tools/Llvm/" + t.host + "/bin/clang-cl.exe");
    }
    var pf = Sys.getEnv("ProgramFiles");
    if (pf != null) cands.push(normalize(pf) + "/LLVM/bin/clang-cl.exe");
    for (c in cands) {
      if (!FileSystem.exists(c)) continue;
      t.exe = c;
      t.backend = "clangcl";
      t.bin.unshift(dirOf(c));
      return true;
    }
    return false;
  }
  #end

  #if !windows
  static function detectPosix(prefer:String):JitToolchain {
    var t = new JitToolchain();
    t.arch = #if HXCPP_M32 "x86" #else "x64" #end;
    var order = prefer == "gcc" ? ["g++", "clang++"] : ["clang++", "g++"];
    for (n in order) {
      var p = which(n);
      if (p == null) continue;
      t.exe = p;
      t.backend = n == "clang++" ? "clang" : "gcc";
      t.bin = [dirOf(p)];
      t.ready = true;
      t.origin = "posix";
      return t;
    }
    t.error = "neither clang++ nor g++ found on PATH";
    return t;
  }
  #end

  static function parentOf(p:String, levels:Int):Null<String> {
    var q = normalize(p);
    for (i in 0...levels) {
      var j = q.lastIndexOf("/");
      if (j <= 0) return null;
      q = q.substr(0, j);
    }
    return q;
  }

  static function normalize(p:String):String {
    return StringTools.replace(p, "\\", "/");
  }

  static function dirOf(p:String):String {
    var n = normalize(p);
    var i = n.lastIndexOf("/");
    return i < 0 ? "" : n.substr(0, i);
  }

  static function splitEnv(v:String):Array<String> {
    var out = [];
    if (v == null) return out;
    #if windows
    var sep = ";";
    #else
    var sep = ":";
    #end
    for (p in v.split(sep)) {
      var q = StringTools.trim(p);
      if (q != "") out.push(normalize(q));
    }
    return out;
  }

  static function which(exe:String):Null<String> {
    var p = Sys.getEnv("PATH");
    if (p == null) return null;
    for (d in splitEnv(p)) {
      var f = d + "/" + exe;
      if (FileSystem.exists(f)) return f;
    }
    return null;
  }

  static function vsRoots():Array<String> {
    var out:Array<String> = [];
    var seen = new Map<String, Bool>();
    var bases = [Sys.getEnv("ProgramFiles(x86)"), Sys.getEnv("ProgramFiles")];
    var names = ["Microsoft Visual Studio/2022", "Microsoft Visual Studio/2019", "Microsoft Visual Studio"];
    for (b in bases) {
      if (b == null || b == "") continue;
      var base = normalize(b);
      for (n in names) {
        var r = base + "/" + n;
        if (!FileSystem.exists(r)) continue;
        for (e in dirs(r)) {
          var root = r + "/" + e;
          if (FileSystem.exists(root + "/VC/Tools/MSVC") && !seen.exists(root)) {
            seen.set(root, true);
            out.push(root);
          }
        }
      }
    }
    return out;
  }

  static function dirs(p:String):Array<String> {
    try {
      return FileSystem.readDirectory(p);
    } catch (e:Dynamic) {
      return [];
    }
  }

  static function pickMsvc(root:String):Null<{ver:String, dir:String}> {
    var base = root + "/VC/Tools/MSVC";
    var vers = dirs(base);
    if (vers.length == 0) return null;
    vers.sort(function(a, b) return a < b ? 1 : (a > b ? -1 : 0));
    return {ver: vers[0], dir: base + "/" + vers[0]};
  }

  static function pickSdk():Null<{ver:String, dir:String}> {
    var bases = [Sys.getEnv("ProgramFiles(x86)"), Sys.getEnv("ProgramFiles")];
    for (b in bases) {
      if (b == null || b == "") continue;
      var base = normalize(b) + "/Windows Kits/10";
      if (!FileSystem.exists(base + "/Include")) continue;
      var vers = dirs(base + "/Include");
      if (vers.length == 0) continue;
      vers.sort(function(a, b) return a < b ? 1 : (a > b ? -1 : 0));
      for (v in vers) {
        if (FileSystem.exists(base + "/Include/" + v + "/ucrt") && FileSystem.exists(base + "/Lib/" + v + "/ucrt")) {
          return {ver: v, dir: base};
        }
      }
    }
    return null;
  }
}
