package hxcpp_jit_r;

import hxcpp_jit_r.JitCompiler.JitDiag;
import hxcpp_jit_r.JitCompiler.JitResult;
import hxcpp_jit_r.JitLoader.JitImage;
import sys.FileSystem;
import sys.io.File;

typedef JitOptions = {
  ?opt:String,
  ?std:String,
  ?flags:Array<String>,
  ?cache:String,
  ?force:Bool,
  ?verbose:Bool,
  ?backend:String,
  ?lineShift:Int,
  ?sigs:Array<String>,
  ?loader:String
}

private typedef JitJob = {
  name:String,
  src:String,
  key:String,
  shift:Int,
  sigs:Array<String>,
  cb:Null<JitModule>->Void,
  done:Bool,
  result:Null<JitResult>
}

class Jit {
  public static var cacheDir:String = "jitcache";
  public static var verbose:Bool = true;
  public static var debug:Bool = false;
  public static var tool(default, null):JitToolchain = null;
  public static var cache(default, null):JitCache = null;
  public static var compiler(default, null):JitCompiler = null;
  public static var ready(default, null):Bool = false;
  public static var lastError:String = "";
  public static var totalBuilds:Int = 0;
  public static var totalCacheHits:Int = 0;

  static var mods:Map<String, JitModule> = new Map();
  static var nextId:Int = 1;
  static var retired:Array<{h:cpp.SizeT, t:Int, image:JitImage}> = [];
  static var jobs:Array<JitJob> = [];
  static var queue:Array<JitJob> = [];
  static var running:Int = 0;
  public static var maxParallel:Int = 2;
  public static var loader:String = "loadlib";
  public static var autoSweepKeep:Int = 24;
  public static var autoSweepEvery:Int = 0;
  static var sinceSweep:Int = 0;
  static var frame:Int = 0;
  static var watched:Array<{path:String, name:String, sig:String, cb:Null<JitModule->Void>}> = [];
  public static var watchEvery:Int = 30;
  static var watchTick:Int = 0;
  static var inited:Bool = false;
  static var hooked:Bool = false;

  public static function setup(?o:JitOptions):Bool {
    if (o != null) {
      if (o.cache != null) {
        cacheDir = o.cache;
        inited = false;
      }
      if (o.verbose != null) verbose = o.verbose;
    }
    if (inited) return ready;
    inited = true;
    cache = new JitCache(cacheDir);
    cache.prepare();
    tool = JitToolchain.detect(o != null && o.backend != null ? o.backend : "auto");
    compiler = new JitCompiler(tool, cache);
    if (o != null) {
      if (o.opt != null) compiler.opt = normOpt(o.opt);
      if (o.std != null) compiler.std = o.std;
      if (o.flags != null) compiler.extra = o.flags;
      if (o.loader != null) loader = o.loader;
    }
    if (!tool.ready) {
      ready = false;
      lastError = tool.error;
      if (verbose) Sys.println("[jit] " + lastError + " (cache-only mode)");
      return false;
    }
    tool.apply();
    ready = true;
    if (verbose) Sys.println("[jit] " + tool.summary());
    return true;
  }

  static function ensure():Bool {
    if (!inited) setup();
    return ready;
  }

  static function normOpt(v:String):String {
    var s = StringTools.trim(v);
    if (s == "") return "O2";
    if (s == "0") return "Od";
    if (s == "1") return "O1";
    if (s == "2") return "O2";
    if (s == "x") return "Ox";
    return s;
  }

  static function applyFlags(o:Null<JitOptions>):Void {
    if (o == null) return;
    if (o.opt != null) compiler.opt = normOpt(o.opt);
    if (o.std != null) compiler.std = o.std;
    if (o.flags != null) compiler.extra = o.flags;
  }

  static function flagStr(o:Null<JitOptions> = null):String {
    var extra = o == null || o.sigs == null ? "" : "|sig:" + o.sigs.join(",");
    var std = compiler == null ? "c++17" : compiler.std;
    var opt = compiler == null ? "O2" : compiler.opt;
    var ex = compiler == null ? "" : compiler.extra.join(" ");
    return "s" + std + "|o" + opt + "|cg" + JitCodegen.BUILD + extra + "|" + ex;
  }

  public static function log(s:String):Void {
    Sys.println(s);
    Sys.stdout().flush();
  }

  public static function compile(name:String, src:String, ?o:JitOptions):JitModule {
    if (debug) log("[jit] compile enter " + name);
    ensure();
    if (debug) log("[jit] ensured " + ready);
    var m = new JitModule(name, nextId++, "", src);
    applyFlags(o);
    if (o != null && o.verbose != null) verbose = o.verbose;
    if (o != null && o.loader != null) loader = o.loader;
    var key = JitCache.key(src, flagStr(o));
    m.key = key;
    if (!ready) {
      var hit = cache == null ? null : cache.dllFor(key);
      if (hit == null) {
        m.diag.push(diag("E_TOOLCHAIN", lastError));
        return m;
      }
      m.cached = true;
      totalCacheHits++;
      if (!load(m, hit)) return m;
      m.symbols = scan(src);
      m.ok = true;
      var prev = mods.get(name);
      if (prev != null && prev != m) prev.dispose();
      mods.set(name, m);
      JitHost.add(m);
      if (verbose) Sys.println('[jit] $name ok (cached, no toolchain)');
      return m;
    }
    if (debug) log("[jit] key " + key);
    var force = o != null && o.force == true;
    var existing = force ? null : cache.dllFor(key);
    if (debug) log("[jit] existing " + existing);
    if (existing != null) {
      m.cached = true;
      totalCacheHits++;
      if (!load(m, existing)) return m;
    } else {
      var t0 = Sys.time();
      var r = compiler.build(key, src, o == null ? 0 : (o.lineShift ?? 0), o == null ? null : o.sigs);
      totalBuilds++;
      m.ms = r.ms;
      m.diag = r.diag;
      m.log = r.log;
      if (!r.ok) return m;
      if (!load(m, r.dll)) return m;
    }
    m.symbols = scan(src);
    m.ok = true;
    var prev = mods.get(name);
    if (prev != null && prev != m) prev.dispose();
    mods.set(name, m);
    JitHost.add(m);
    if (verbose) {
      var tag = m.cached ? "cached" : Std.int(m.ms) + "ms";
      Sys.println('[jit] $name ok ($tag)' + (m.symbols.length > 0 ? " " + m.symbols.toString() : ""));
    }
    return m;
  }

  public static function compileFile(path:String, ?name:String, ?o:JitOptions):JitModule {
    if (!FileSystem.exists(path)) {
      var m = new JitModule(name == null ? path : name, nextId++, "", "");
      m.diag.push(diag("E_NOFILE", path));
      return m;
    }
    var n = name == null ? haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(path)) : name;
    return compile(n, File.getContent(path), o);
  }

  public static function compileAsync(name:String, src:String, cb:Null<JitModule>->Void, ?o:JitOptions):Void {
    ensure();
    if (!ready) {
      cb(compile(name, src, o));
      return;
    }
    applyFlags(o);
    var key = JitCache.key(src, flagStr(o));
    if ((o == null || o.force != true) && cache.dllFor(key) != null) {
      cb(compile(name, src, o));
      return;
    }
    queue.push({
      name: name,
      src: src,
      key: key,
      shift: o == null ? 0 : (o.lineShift ?? 0),
      sigs: o == null ? null : o.sigs,
      cb: cb,
      done: false,
      result: null
    });
    pump();
  }

  public static function reload(name:String, src:String = null, ?o:JitOptions):JitModule {
    var m = mods.get(name);
    var s = src != null ? src : (m == null ? null : m.src);
    if (s == null) return null;
    var opts:JitOptions = {force: true};
    if (o != null) {
      if (o.opt != null) opts.opt = o.opt;
      if (o.std != null) opts.std = o.std;
      if (o.flags != null) opts.flags = o.flags;
      if (o.cache != null) opts.cache = o.cache;
    }
    return compile(name, s, opts);
  }

  public static function eval(code:String, ?o:JitOptions):Float {
    var n = "eval_" + JitCache.key(code, "").substr(0, 8);
    var oo:JitOptions = {
      opt: o == null ? null : o.opt,
      std: o == null ? null : o.std,
      flags: o == null ? null : o.flags,
      force: o == null ? null : o.force,
      lineShift: (o == null || o.lineShift == null ? 0 : o.lineShift) + 1
    };
    var m = compile(n, "RJIT(__e) {\n" + code + "\n}\n", oo);
    if (!m.ok) return Math.NaN;
    return m.call("__e");
  }

  public static function get(name:String):Null<JitModule> {
    return mods.get(name);
  }

  public static function all():Array<JitModule> {
    var out = [];
    for (k in mods.keys()) out.push(mods.get(k));
    return out;
  }

  public static function dispose(name:String):Void {
    var m = mods.get(name);
    if (m == null) return;
    mods.remove(name);
    m.dispose();
  }

  public static function disposeAll():Void {
    var names = [];
    for (k in mods.keys()) names.push(k);
    for (n in names) dispose(n);
  }

  public static function retire(h:cpp.SizeT, image:JitImage = null):Void {
    if (h != 0 || image != null) retired.push({h: h, t: frame, image: image});
  }

  public static function watch(path:String, ?name:String, ?onReload:JitModule->Void):Bool {
    if (!FileSystem.exists(path)) return false;
    var n = name == null ? haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(path)) : name;
    var cur = "";
    try cur = File.getContent(path) catch (e:Dynamic) return false;
    for (w in watched) {
      if (w.path == path) {
        w.name = n;
        w.sig = cur;
        w.cb = onReload;
        return true;
      }
    }
    watched.push({path: path, name: n, sig: cur, cb: onReload});
    if (mods.get(n) == null) compile(n, cur);
    return true;
  }

  public static function unwatch(path:String):Bool {
    var keep = [];
    var found = false;
    for (w in watched) {
      if (w.path == path) found = true else keep.push(w);
    }
    watched = keep;
    return found;
  }

  public static function watchedFiles():Array<String> {
    return [for (w in watched) w.path];
  }

  static function pollWatch():Void {
    for (w in watched) {
      var src = "";
      try src = File.getContent(w.path) catch (e:Dynamic) continue;
      if (src == w.sig) continue;
      w.sig = src;
      var m = compile(w.name, src, {force: true});
      if (m.ok) {
        if (verbose) log("[jit] reloaded " + w.name);
        if (w.cb != null) w.cb(m);
      } else if (verbose) {
        log("[jit] reload failed for " + w.name);
      }
    }
  }

  public static function tick():Void {
    frame++;
    if (watched.length > 0) {
      watchTick++;
      if (watchTick >= watchEvery) {
        watchTick = 0;
        pollWatch();
      }
    }
    if (retired.length > 0) {
      var keep = [];
      for (r in retired) {
        if (frame - r.t >= 3) {
          if (r.image != null) JitLoader.unload(r.image) else JitNative.unloadDll(r.h);
        } else keep.push(r);
      }
      retired = keep;
    }
    if (jobs.length > 0) {
      var keep = [];
      for (j in jobs) {
        if (j.done) {
          running--;
          try {
            finish(j);
          } catch (e:Dynamic) {
            if (verbose) Sys.println("[jit] finish failed: " + Std.string(e));
          }
        } else {
          keep.push(j);
        }
      }
      jobs = keep;
    }
    pump();
  }

  static function pump():Void {
    while (running < maxParallel && queue.length > 0) {
      var j = queue.shift();
      running++;
      jobs.push(j);
      start(j);
    }
  }

  static function start(j:JitJob):Void {
    var comp = compiler;
    var run = function() {
      var r:Null<JitResult> = null;
      try {
        r = comp.build(j.key, j.src, j.shift, j.sigs);
      } catch (e:Dynamic) {}
      j.result = r;
      j.done = true;
    };
    #if target.threaded
    sys.thread.Thread.create(run);
    #else
    run();
    #end
  }

  static function finish(j:JitJob):Void {
    var m = new JitModule(j.name, nextId++, j.key, j.src);
    var r = j.result;
    if (r == null) {
      m.diag.push(diag("E_COMPILE", "compiler invocation failed"));
      j.cb(m);
      return;
    }
    totalBuilds++;
    m.ms = r.ms;
    m.diag = r.diag;
    m.log = r.log;
    if (!r.ok) {
      if (verbose) Sys.println('[jit] ${j.name} async compile failed: ' + StringTools.trim(r.log));
      j.cb(m);
      return;
    }
    if (!load(m, r.dll)) {
      if (verbose) Sys.println('[jit] ${j.name} async load failed');
      j.cb(m);
      return;
    }
    m.symbols = scan(j.src);
    m.ok = true;
    var prev = mods.get(j.name);
    if (prev != null) prev.dispose();
    mods.set(j.name, m);
    JitHost.add(m);
    if (verbose) Sys.println('[jit] ${j.name} ok (async ' + Std.int(m.ms) + "ms)");
    j.cb(m);
  }

  public static function pending():Int {
    return jobs.length + queue.length;
  }

  public static function active():Int {
    return running;
  }

  public static function hook():Bool {
    #if openfl
    if (hooked) return true;
    try {
      var lib = openfl.Lib.current;
      if (lib == null || lib.stage == null) return false;
      lib.addEventListener(openfl.events.Event.ENTER_FRAME, function(_) tick());
      hooked = true;
      return true;
    } catch (e:Dynamic) {
      return false;
    }
    #else
    return false;
    #end
  }

  static function sym(image:JitImage, h:cpp.SizeT, n:String):cpp.SizeT {
    return image != null ? JitLoader.proc(image, n) : JitNative.getProc(h, n);
  }

  static function load(m:JitModule, dll:String):Bool {
    if (debug) log("[jit] load 1 " + dll);
    var h:cpp.SizeT = 0;
    if (loader == "auto" || loader == "manual") {
      var image = JitLoader.load(dll);
      if (image.ok) {
        m.image = image;
        h = image.base;
      } else if (loader == "manual") {
        m.diag.push(diag("E_PE", image.error));
        return false;
      } else if (debug) {
        log("[jit] manual map skipped: " + image.error);
      }
    }
    if (h == 0) {
      h = JitNative.loadDll(dll);
      if (debug) log("[jit] load 2 h=" + h);
      if (h == 0) {
        m.diag.push(diag("E_LOAD", dll + " " + JitNative.errorText(JitNative.lastError())));
        return false;
      }
    }
    var abi = sym(m.image, h, "rjit_abi");
    if (abi != 0) {
      var v = Std.int(JitNative.invoke(abi, 0, 0, 0, 0, 0, 0, 0, 0));
      if (v != JitAbi.VERSION) {
        if (m.image != null) JitLoader.unload(m.image) else JitNative.unloadDll(h);
        m.image = null;
        m.diag.push(diag("E_ABI", 'dll abi $v != host ' + JitAbi.VERSION));
        return false;
      }
    }
    var c = JitNative.mkctx(m.id);
    if (c == 0) {
      if (m.image != null) JitLoader.unload(m.image) else JitNative.unloadDll(h);
      m.image = null;
      m.diag.push(diag("E_CTX", "context allocation failed"));
      return false;
    }
    m.attach(h, c);
    m.dll = dll;
    var init = sym(m.image, h, "rjit_init");
    if (init != 0) {
      var rc = Std.int(JitNative.invoke(init, c, 0, 0, 0, 0, 0, 0, 0));
      if (rc != 0) m.diag.push(diag("E_INIT", "rjit_init returned " + rc));
    }
    if (debug) log("[jit] load 8 ok");
    return true;
  }

  public static function prefetch(?o:JitOptions):Int {
    var n = 0;
    for (m in all()) {
      if (m.src == null || m.src == "") continue;
      var opts:JitOptions = {};
      if (o != null) {
        if (o.opt != null) opts.opt = o.opt;
        if (o.std != null) opts.std = o.std;
        if (o.flags != null) opts.flags = o.flags;
        if (o.sigs != null) opts.sigs = o.sigs;
      }
      var mm = compile(m.name, m.src, opts);
      if (mm.ok) n++;
    }
    return n;
  }

  public static function prefetchList(items:Array<{name:String, src:String}>, ?o:JitOptions):Int {
    var n = 0;
    if (items == null) return 0;
    for (it in items) {
      var mm = compile(it.name, it.src, o);
      if (mm.ok) n++;
    }
    return n;
  }

  public static function exportPack(dir:String):Int {
    if (cache == null) ensure();
    if (cache == null) return 0;
    prefetch();
    return JitPack.exportPack(cache.root, dir);
  }

  public static function importPack(dir:String):Int {
    if (cache == null) ensure();
    if (cache == null) return 0;
    var bad = JitPack.checkPack(dir);
    if (bad != "") {
      lastError = bad;
      return -1;
    }
    return JitPack.importPack(cache.root, dir);
  }

  public static function packInfo(dir:String):String {
    return JitPack.manifestInfo(dir);
  }

  static function tickSweep():Void {
    if (autoSweepEvery <= 0) return;
    sinceSweep++;
    if (sinceSweep < autoSweepEvery) return;
    sinceSweep = 0;
    var n = sweep(autoSweepKeep);
    if (verbose && n > 0) log("[jit] swept " + n + " cached files");
  }

  static function diag(code:String, msg:String):JitDiag {
    return {file: "jit", line: 0, col: 0, kind: "error", code: code, msg: msg};
  }

  public static function scan(src:String):Array<String> {
    var out:Array<String> = [];
    var seen = new Map<String, Bool>();
    var n = src.length;
    var i = 0;
    while (i < n) {
      var p = src.indexOf("RJIT", i);
      if (p < 0) break;
      i = p + 4;
      if (i < n && src.charCodeAt(i) == 95) continue;
      var j = i;
      while (j < n) {
        var c = src.charCodeAt(j);
        if (c != 32 && c != 9) break;
        j++;
      }
      if (j >= n || src.charCodeAt(j) != 40) continue;
      j++;
      while (j < n && (src.charCodeAt(j) == 32 || src.charCodeAt(j) == 9)) j++;
      var s0 = j;
      while (j < n) {
        var c = src.charCodeAt(j);
        if (!((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95)) break;
        j++;
      }
      if (j > s0) {
        var nm = src.substring(s0, j);
        if (!seen.exists(nm)) {
          seen.set(nm, true);
          out.push(nm);
        }
      }
    }
    return out;
  }

  public static function bind(name:String, f:Dynamic):Void {
    JitHost.bind(name, f);
  }

  public static function unbind(name:String):Void {
    JitHost.unbind(name);
  }

  public static function setVar(k:String, v:Float):Void {
    JitHost.setVar(k, v);
  }

  public static function purge():Int {
    return cache == null ? 0 : cache.purge();
  }

  public static function sweep(keep:Int = 8):Int {
    if (cache == null) return 0;
    var live = new Map<String, Bool>();
    for (m in mods) if (m.ok) live.set(m.key, true);
    return cache.sweep(keep, live);
  }

  public static function stats():String {
    var b = new StringBuf();
    b.add("[jit] ready=" + ready + " builds=" + totalBuilds + " cacheHits=" + totalCacheHits + " modules=" + Lambda.count(mods) + "\n");
    if (tool != null) b.add("  " + tool.summary() + "\n");
    if (cache != null) b.add("  cache=" + cache.root + " size=" + Std.int(cache.size() / 1024.0) + "KB\n");
    for (m in all()) b.add("  " + m.stats() + "\n");
    return b.toString();
  }

  public static function f3(v:Float):String {
    var neg = v < 0;
    var n = Math.round(Math.abs(v) * 1000.0);
    var s = Std.string(Std.int(n / 1000)) + "." + StringTools.lpad(Std.string(n % 1000), "0", 3);
    return neg ? "-" + s : s;
  }

  public static function selfTest():String {
    if (!ensure()) return "[jit] selftest skipped: " + lastError;
    JitHost.capture = true;
    JitHost.logs = [];
    var src = 'RJIT(add) { return RJIT_A0 + RJIT_A1; }
RJIT(mul) { return RJIT_A0 * RJIT_A1; }
RJIT(mix) { return RJIT_CALL2("mul", RJIT_A0, RJIT_A1) + 1.0; }
RJIT(greet) { RJIT_LOG("hello-from-native"); RJIT_RETSTR("native-string"); return RJIT_N; }
RJIT(fib) { double a = 0, b = 1; int n = (int)RJIT_A0; for (int i = 0; i < n; i++) { double t = a + b; a = b; b = t; } return a; }
RJIT(sum) { double s = 0; for (int i = 0; i < (int)RJIT_A0; i++) s += (double)i; return s; }
';
    var m = compile("selftest", src, {opt: "O2"});
    if (!m.ok) return "[jit] selftest compile failed\n" + m.report();

    var out = new StringBuf();
    var pass = 0;
    var fail = 0;
    var check = function(label:String, got:String, want:String) {
      var good = got == want;
      if (good) pass++ else fail++;
      out.add((good ? "  PASS " : "  FAIL ") + label + " = " + got + (good ? "" : " (want " + want + ")") + "\n");
    };

    out.add("[jit] selftest\n");
    check("add(2,3)", Std.string(m.call("add", 2, 3)), "5");
    check("mul(6,7)", Std.string(m.call("mul", 6, 7)), "42");
    check("mix(6,7) via host callback", Std.string(m.call("mix", 6, 7)), "43");
    check("greet() retstr", m.callStr("greet", [1, 2]), "native-string");
    check("fib(30)", Std.string(m.call("fib", 30)), "832040");
    check("undefined(), safe no-op", Std.string(m.call("nope")), "0");
    check("host log captured", Std.string(JitHost.logs.indexOf("hello-from-native") >= 0), "true");

    var t0 = Sys.time();
    var acc:Float = 0;
    var reps = 200000;
    for (i in 0...reps) acc += m.call("sum", 100);
    var us = (Sys.time() - t0) * 1000000.0 / reps;
    out.add('  ...  cross-ABI call overhead ${f3(us)}us  (${reps}x sum(100) = ${Std.int(acc)})\n');
    out.add('  ...  build ${Std.int(m.ms)}ms  cached=${m.cached}  dll=${m.dll}\n');
    out.add("[jit] result " + (fail == 0 ? "PASS" : "FAIL") + " (" + pass + "/" + (pass + fail) + ")\n");
    return out.toString();
  }
}
