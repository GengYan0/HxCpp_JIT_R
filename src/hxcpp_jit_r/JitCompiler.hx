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

class JitCompiler {
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

  public function build(key:String, src:String, lineShift:Int = 0, sigs:Array<String> = null):JitResult {
    var t0 = Sys.time();
    if (pchState == 0 && isMsvcLike()) prepare();
    var dir = cache.dirFor(key);
    var cpp = dir + "/mod" + (isMsvcLike() ? ".cpp" : ".cc");
    var tail = JitCodegen.emit(JitScan.functions(src), JitScan.globals(src), sigs, JitScan.structs(src));
    var pre = needsStringHeader(src) ? "#include <string>\n" : "";
    var shift = lineShift + (pre == "" ? 0 : 1);
    File.saveContent(cpp, pre + (tail == "" ? src : src + tail));
    var out = cache.nextBinary(key);
    var args = isMsvcLike() ? msvcArgs(cpp, out, dir) : gccArgs(cpp, out, dir);
    lastCommand = tool.exe + " " + args.join(" ");
    if (Jit.debug) Jit.log("[jit] exec " + lastCommand);
    var r = run(args);
    var log = r.err;
    var trimmed = StringTools.trim(r.out);
    if (trimmed != "" && trimmed != haxe.io.Path.withoutDirectory(cpp)) log = log + r.out;
    var ok = r.code == 0 && FileSystem.exists(out);
    return {
      ok: ok,
      dll: ok ? JitCache.normalize(out) : "",
      log: log,
      diag: parse(log, shift),
      ms: (Sys.time() - t0) * 1000.0
    };
  }

  function msvcArgs(cpp:String, out:String, dir:String):Array<String> {
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
    a.push(cpp);
    if (pchState == 1 && pchObj != "") a.push(pchObj);
    a.push("/Fe:" + out);
    a.push("/Fo:" + dir + "/");
    a.push("/link");
    a.push("/NOIMPLIB");
    a.push("/INCREMENTAL:NO");
    return a;
  }

  function gccArgs(cpp:String, out:String, dir:String):Array<String> {
    return posixArgs(cpp, out, dir, cache.headerFile(), cache.root, std, opt, extra, tool.backend);
  }

  public static function needsStringHeader(src:String):Bool {
    if (src.indexOf("std::string") < 0 && src.indexOf("std::wstring") < 0) return false;
    var t = src.split(" ").join("");
    if (t.indexOf("#include<string>") >= 0) return false;
    if (t.indexOf("#include<string.h>") >= 0) return true;
    return t.indexOf("#include<iostream>") < 0 && t.indexOf("#include<sstream>") < 0;
  }

  public static function posixArgs(cpp:String, out:String, dir:String, header:String, cacheRoot:String, std:String, opt:String, extra:Array<String>, backend:String):Array<String> {
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
    a.push(cpp);
    a.push("-o");
    a.push(out);
    if (backend == "gcc") a.push("-Wl,-undefined,dynamic_lookup");
    return a;
  }

  function run(args:Array<String>):{code:Int, out:String, err:String} {
    var p = new sys.io.Process(tool.exe, args);
    var name = haxe.io.Path.withoutDirectory(tool.exe);
    var timer:Null<haxe.Timer> = null;
    if (timeoutMs > 0) {
      try {
        timer = haxe.Timer.delay(function() {
          try {
            Sys.command("taskkill", ["/F", "/IM", name]);
          } catch (e:Dynamic) {}
        }, timeoutMs);
      } catch (e:Dynamic) {}
    }
    var eb = p.stderr.readAll();
    var ob = p.stdout.readAll();
    var code = p.exitCode();
    p.close();
    if (timer != null) timer.stop();
    #if windows
    var cp = JitNative.getACP();
    return {code: code, out: JitNative.decode(ob, cp), err: JitNative.decode(eb, cp)};
    #else
    return {code: code, out: ob.toString(), err: eb.toString()};
    #end
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
