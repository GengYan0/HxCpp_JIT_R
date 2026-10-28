package hxcpp_jit_r;

import sys.FileSystem;
import sys.io.File;

typedef JitDiag = {
  var file:String;
  var line:Int;
  var col:Int;
  var kind:String;
  var code:String;
  var msg:String;
}

typedef JitResult = {
  var ok:Bool;
  var dll:String;
  var log:String;
  var diag:Array<JitDiag>;
  var ms:Float;
}

typedef JitMulti = {
  var files:Array<String>;
  var texts:Array<String>;
  var includes:Array<String>;
  var missing:Array<String>;
}

class JitCompiler {
  static var buildLock = new sys.thread.Mutex();
  static var DIAG_WIN = ~/^(.+?)\(([0-9]+)(,([0-9]+))?\) *: *(fatal error|error|warning) ?([A-Z]+[0-9]+)? *: *(.*)$/;
  static var DIAG_NIX = ~/^(.+?):([0-9]+)(:([0-9]+))?: *(fatal error|error|warning) ?([A-Z]+[0-9]+)? *: *(.*)$/;

  public var tool:JitToolchain;
  public var cache:JitCache;
  public var std:String = "c++17";
  public var opt:String = "O2";
  public var extra:Array<String> = [];
  public var lastCommand:String = "";
  public var timeoutMs:Int = 90000;
  public var usePch:Bool = true;
  #if target.threaded
  static var pchLock = new sys.thread.Mutex();
  static var active:Int = 0;
  #end
  var pchState:Int = 0;
  var pchFile:String = "";
  var pchObj:String = "";

  public function new(tool:JitToolchain, cache:JitCache) {
    this.tool = tool;
    this.cache = cache;
  }

  public function isMsvcLike():Bool {
    return tool.backend == "msvc" || tool.backend == "clangcl";
  }

  public function flagKey():String {
    return JitCache.key("", tool.backend + "|" + std + "|" + opt + "|" + extra.join(" ") + "|" + JitAbi.VERSION);
  }

  public function prepare():Bool {
    if (!usePch || tool.backend != "msvc") return false;
    if (pchState == 1) return true;
    #if target.threaded
    pchLock.acquire();
    #end
    var r = false;
    try {
      r = prepareLocked();
    } catch (e:Dynamic) {
      if (Jit.debug) Jit.log("[jit] pch prepare failed: " + Std.string(e));
      r = false;
    }
    #if target.threaded
    pchLock.release();
    #end
    return r;
  }

  function prepareLocked():Bool {
    if (pchState != 0) return pchState == 1;
    pchState = -1;
    if (!tool.ready) return false;
    var base = cache.root + "/pch";
    mkdirs(base);
    var k = flagKey();
    var file = base + "/rjit_" + k + ".pch";
    var obj = base + "/pch_" + k + ".obj";
    if (FileSystem.exists(file) && FileSystem.exists(obj)) {
      pchFile = file;
      pchObj = obj;
      pchState = 1;
      return true;
    }
    var src = base + "/pch_" + k + ".cpp";
    File.saveContent(src, "int rjit_pch_anchor = 0;\n");
    var args = [
      "/nologo", "/c", "/utf-8", "/std:" + std, "/" + opt, "/EHsc", "/MT",
      "/DNDEBUG", "/DRJIT_DEFINE_ABI_EXPORT", "/D_CRT_SECURE_NO_WARNINGS",
      "/Ycrjit_abi.h", "/Fp" + file, "/Fo:" + base + "/",
      "/FIrjit_abi.h", "/I" + cache.root, src
    ];
    var r = run(args);
    if (r.code != 0 || !FileSystem.exists(file) || !FileSystem.exists(obj)) {
      if (Jit.debug) Jit.log("[jit] pch unavailable: " + r.err);
      return false;
    }
    pchFile = file;
    pchObj = obj;
    pchState = 1;
    return true;
  }

  static function mkdirs(p:String):Void {
    if (FileSystem.exists(p)) return;
    var q = StringTools.replace(p, "\\", "/");
    var i = q.lastIndexOf("/");
    if (i > 1) mkdirs(q.substr(0, i));
    try FileSystem.createDirectory(p) catch (e:Dynamic) {}
  }

  public function build(key:String, src:String, lineShift:Int = 0, sigs:Array<String> = null, multi:JitMulti = null):JitResult {
    var t0 = Sys.time();
    if (pchState != 1 && isMsvcLike()) prepare();
    var dir = cache.dirFor(key);
    var cpp = dir + "/mod" + (isMsvcLike() ? ".cpp" : ".cc");
    var texts = [src];
    if (multi != null) for (t in multi.texts) texts.push(t);
    var structsAll = [];
    for (t in texts) for (s in JitScan.structs(t)) structsAll.push(s);
    var fns = [];
    var seen = new Map<String, Bool>();
    var externs:Array<String> = [];
    for (i in 0...texts.length) {
      for (f in JitScan.functions(texts[i], structsAll)) {
        var k = f.name + "|" + f.sig;
        if (seen.exists(k)) continue;
        seen.set(k, true);
        fns.push(f);
        if (i > 0 && !f.isStatic) externs.push(declOf(f));
      }
    }
    var vars = JitScan.globals(src);
    var mainStructs = new Map<String, Bool>();
    for (x in JitScan.structs(src)) mainStructs.set(x.name, true);
    var seenVar = new Map<String, Bool>();
    for (v in vars) seenVar.set(v.name, true);
    if (multi != null) {
      for (t in multi.texts) {
        for (v in JitScan.globals(t)) {
          if (seenVar.exists(v.name) || v.isConst || v.isStatic) continue;
          var d = varDecl(v, mainStructs);
          if (d == null) continue;
          seenVar.set(v.name, true);
          externs.push(d);
          vars.push(v);
        }
      }
    }
    var tail = JitCodegen.emit(fns, vars, sigs, structsAll, externs);
    var pre = needsStringHeader(texts.join("\n")) ? "#include <string>\n" : "";
    var shift = lineShift + (pre == "" ? 0 : 1);
    var out = cache.nextBinary(key);
    var body = pre + (tail == "" ? src : src + tail);
    var tmpOut = out + "." + Std.random(1000000) + ".tmp";
    buildLock.acquire();
    if (!FileSystem.exists(cpp) || File.getContent(cpp) != body) File.saveContent(cpp, body);
    var more = multi == null ? null : multi.files;
    var incs = multi == null ? null : multi.includes;
    var args = isMsvcLike() ? msvcArgs(cpp, tmpOut, dir, more, incs) : gccArgs(cpp, tmpOut, dir, more, incs);
    lastCommand = tool.exe + " " + args.join(" ");
    if (Jit.debug) Jit.log("[jit] exec " + lastCommand);
    var r = run(args);
    buildLock.release();
    var log = r.err;
    var trimmed = StringTools.trim(r.out);
    if (trimmed != "" && trimmed != haxe.io.Path.withoutDirectory(cpp)) log = log + r.out;
    var ok = r.code == 0 && FileSystem.exists(tmpOut);
    if (ok) {
      try {
        if (FileSystem.exists(out)) FileSystem.deleteFile(out);
        FileSystem.rename(tmpOut, out);
      } catch (e:Dynamic) {}
      ok = FileSystem.exists(out);
    }
    if (FileSystem.exists(tmpOut)) try FileSystem.deleteFile(tmpOut) catch (e:Dynamic) {}
    if (ok) cache.prune(key, 2);
    return {
      ok: ok,
      dll: ok ? JitCache.normalize(out) : "",
      log: log,
      diag: parse(log, shift),
      ms: (Sys.time() - t0) * 1000.0
    };
  }

  public static function varDecl(v:JitScan.JitVarInfo, mainStructs:Map<String, Bool>):String {
    return switch (v.kind) {
      case "num", "ptr": v.type + " " + v.name;
      case "array": v.type + " " + v.name + "[" + v.size + "]";
      case "struct": mainStructs.exists(v.structName) ? v.structName + " " + v.name : null;
      case "structarray": mainStructs.exists(v.structName) ? v.structName + " " + v.name + "[" + v.size + "]" : null;
      default: null;
    };
  }

  public static function declOf(f:JitScan.JitFnInfo):String {
    var ret = StringTools.trim(f.rawRet);
    var args = f.rawArgs == null ? [] : f.rawArgs;
    return ret + " " + f.name + "(" + (args.length == 0 ? "" : args.join(", ")) + ")";
  }

  function msvcArgs(cpp:String, out:String, dir:String, more:Array<String> = null, incs:Array<String> = null):Array<String> {
    var a = extra.copy();
    a.push("/nologo");
    a.push("/LD");
    a.push("/utf-8");
    a.push("/std:" + std);
    a.push("/" + opt);
    a.push("/EHsc");
    a.push("/MT");
    a.push("/DNDEBUG");
    a.push("/DRJIT_DEFINE_ABI_EXPORT");
    a.push("/D_CRT_SECURE_NO_WARNINGS");
    if (tool.backend == "clangcl") a.push("/Wno-unused-command-line-argument");
    if (pchState == 1) {
      a.push("/Yurjit_abi.h");
      a.push("/Fp" + pchFile);
    }
    a.push("/FIrjit_abi.h");
    a.push("/I" + cache.root);
    a.push("/I" + dir);
    if (incs != null) for (p in incs) if (p != null && p != "") a.push("/I" + p);
    a.push(cpp);
    if (more != null) for (p in more) if (p != null && p != "") a.push(p);
    if (pchState == 1 && pchObj != "") a.push(pchObj);
    a.push("/Fe:" + out);
    a.push("/Fo:" + dir + "/");
    a.push("/link");
    a.push("/NOIMPLIB");
    a.push("/INCREMENTAL:NO");
    return a;
  }

  function gccArgs(cpp:String, out:String, dir:String, more:Array<String> = null, incs:Array<String> = null):Array<String> {
    return posixArgs(cpp, out, dir, cache.headerFile(), cache.root, std, opt, extra, tool.backend, more, incs);
  }

  public static function needsStringHeader(src:String):Bool {
    if (src.indexOf("std::string") < 0 && src.indexOf("std::wstring") < 0) return false;
    var t = src.split(" ").join("");
    if (t.indexOf("#include<string>") >= 0) return false;
    if (t.indexOf("#include<string.h>") >= 0) return true;
    return t.indexOf("#include<iostream>") < 0 && t.indexOf("#include<sstream>") < 0;
  }

  public static function posixArgs(cpp:String, out:String, dir:String, header:String, cacheRoot:String, std:String, opt:String, extra:Array<String>, backend:String, more:Array<String> = null, incs:Array<String> = null):Array<String> {
    var a = extra == null ? [] : extra.copy();
    var o = "O2";
    if (opt == "Od") o = "O0";
    else if (opt == "O1") o = "O1";
    else if (opt == "O2") o = "O2";
    else if (opt == "Ox") o = "O3";
    a.push("-shared");
    a.push("-fPIC");
    a.push("-" + o);
    a.push("-std=" + std);
    a.push("-DNDEBUG");
    a.push("-DRJIT_DEFINE_ABI_EXPORT");
    a.push("-fvisibility=hidden");
    a.push("-include");
    a.push(header);
    a.push("-I" + cacheRoot);
    a.push("-I" + dir);
    if (incs != null) for (p in incs) if (p != null && p != "") a.push("-I" + p);
    a.push(cpp);
    if (more != null) for (p in more) if (p != null && p != "") a.push(p);
    a.push("-o");
    a.push(out);
    #if mac
    if (backend == "gcc" || backend == "clang") a.push("-Wl,-undefined,dynamic_lookup");
    #end
    return a;
  }

  function run(args:Array<String>):{code:Int, out:String, err:String} {
    var p = new sys.io.Process(tool.exe, args);
    var name = haxe.io.Path.withoutDirectory(tool.exe);
    var timer:Null<haxe.Timer> = null;
    var killed = [false];
    var timedOut = timeoutMs > 0;
    if (timedOut) {
      #if target.threaded
      active++;
      #end
      try {
        timer = haxe.Timer.delay(function() {
          try {
            #if target.threaded
            if (active > 1) return;
            #end
            killed[0] = true;
            if (JitPlatform.win) Sys.command("taskkill", ["/F", "/T", "/IM", name]);
            else Sys.command("pkill", ["-TERM", name]);
          } catch (e:Dynamic) {}
        }, timeoutMs);
      } catch (e:Dynamic) {}
    }
    var eb = p.stderr.readAll();
    var ob = p.stdout.readAll();
    var code = p.exitCode();
    p.close();
    if (timer != null) timer.stop();
    if (timedOut) {
      #if target.threaded
      active--;
      #end
    }
    if (killed[0] && code == 0) code = -9;
    if (JitPlatform.win) {
      var cp = JitNative.getACP();
      return {code: code, out: JitNative.decode(ob, cp), err: JitNative.decode(eb, cp)};
    }
    return {code: code, out: ob.toString(), err: eb.toString()};
  }

  public function parse(log:String, lineShift:Int = 0):Array<JitDiag> {
    var out:Array<JitDiag> = [];
    var re = isMsvcLike() ? DIAG_WIN : DIAG_NIX;
    for (line in log.split("\n")) {
      var s = StringTools.trim(line);
      if (s == "") continue;
      if (!re.match(s)) continue;
      var file = re.matched(1);
      var col = re.matched(4);
      var kind = re.matched(5);
      var code = re.matched(6);
      var msg = re.matched(7);
      var nf = JitCache.normalize(file).toLowerCase();
      var isUser = StringTools.endsWith(nf, "mod.cpp") || StringTools.endsWith(nf, "mod.cc");
      var ln = Std.parseInt(re.matched(2));
      if (isUser && lineShift > 0) ln -= lineShift;
      out.push({
        file: isUser ? "user" : file,
        line: isUser ? ln : 0,
        col: col == null ? 0 : Std.parseInt(col),
        kind: kind,
        code: code == null ? "" : code,
        msg: msg
      });
    }
    return out;
  }

  public static function describe(d:JitDiag):String {
    if (d.file == "user") return StringTools.trim("line " + d.line + ": " + d.kind + " " + d.code + " " + d.msg);
    return StringTools.trim(d.file + ": " + d.kind + " " + d.code + " " + d.msg);
  }
}
