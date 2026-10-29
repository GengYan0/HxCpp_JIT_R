package hxcpp_jit_r;

import hxcpp_jit_r.JitCompiler.JitDiag;
import hxcpp_jit_r.JitCompiler.JitResult;
import hxcpp_jit_r.JitCompiler.JitMulti;
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
  ?loader:String,
  ?sources:Array<String>,
  ?includes:Array<String>
}

private typedef JitJob = {
  name:String,
  src:String,
  key:String,
  shift:Int,
  sigs:Array<String>,
  loader:String,
  multi:JitMulti,
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
  static var retired:Array<{h:cpp.SizeT, t:Int, image:JitImage, ctx:cpp.SizeT}> = [];
  static var jobs:Array<JitJob> = [];
  static var queue:Array<JitJob> = [];
  static var running:Int = 0;
  public static var maxParallel:Int = 2;
  public static var loader:String = "loadlib";
  public static var autoSweepKeep:Int = 24;
  public static var autoSweepEvery:Int = 0;
  static var sinceSweep:Int = 0;
  static var frame:Int = 0;
  static var defaultOpt:String = "O2";
  static var defaultStd:String = "c++17";
  static var defaultFlags:Array<String> = [];
  static var defaultLoader:String = "loadlib";
  static var watched:Array<{path:String, name:String, sig:String, cb:Null<JitModule->Void>, mt:Float, sz:Int}> = [];
  public static var watchEvery:Int = 30;
  public static var threadTimeout(default, set):Int = 2000;

  static function set_threadTimeout(v:Int):Int {
    threadTimeout = v < 1 ? 1 : v;
    JitNative.setWait(threadTimeout);
    return threadTimeout;
  }
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
    if (!cache.prepare() && verbose) Sys.println("[jit] cannot write " + cache.headerFile());
    JitNative.setHostThread();
    tool = JitToolchain.detect(o != null && o.backend != null ? o.backend : "auto");
    compiler = new JitCompiler(tool, cache);
    if (o != null) {
      if (o.opt != null) defaultOpt = normOpt(o.opt);
      if (o.std != null) defaultStd = o.std;
      if (o.flags != null) defaultFlags = o.flags.copy();
      if (o.loader != null) defaultLoader = o.loader;
    }
    compiler.opt = defaultOpt;
    compiler.std = defaultStd;
    compiler.extra = defaultFlags.copy();
    loader = defaultLoader;
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
    if (compiler == null) return;
    compiler.opt = o == null || o.opt == null ? defaultOpt : normOpt(o.opt);
    compiler.std = o == null || o.std == null ? defaultStd : o.std;
    compiler.extra = o == null || o.flags == null ? defaultFlags.copy() : o.flags.copy();
  }

  static function flagStr(o:Null<JitOptions> = null):String {
    var extra = o == null || o.sigs == null ? "" : "|sig:" + o.sigs.join(",");
    var std = compiler == null ? "c++17" : compiler.std;
    var opt = compiler == null ? "O2" : compiler.opt;
    var ex = compiler == null ? "" : compiler.extra.join(" ");
    return "s" + std + "|o" + opt + "|cg" + JitCodegen.BUILD + "|h" + JitCache.key(JitAbi.HEADER, "").substr(0, 12) + extra + "|" + ex;
  }

  public static function log(s:String):Void {
    Sys.println(s);
    Sys.stdout().flush();
  }

  public static function compile(name:String, src:String, ?o:JitOptions):JitModule {
    var savedVerbose = verbose;
    var savedLoader = loader;
    if (o != null && o.verbose != null) verbose = o.verbose;
    if (o != null && o.loader != null) loader = o.loader;
    var m:JitModule = null;
    try {
      m = compileNow(name, src, o);
    } catch (e:Dynamic) {
      verbose = savedVerbose;
      loader = savedLoader;
      throw e;
    }
    verbose = savedVerbose;
    loader = savedLoader;
    return m;
  }

  static function multiOf(o:Null<JitOptions>):Null<JitMulti> {
    if (o == null || o.sources == null) return null;
    var files:Array<String> = [];
    var texts:Array<String> = [];
    var missing:Array<String> = [];
    var incs:Array<String> = o.includes == null ? [] : o.includes.copy();
    var dirs = new Map<String, Bool>();
    for (p in o.sources) {
      if (p == null || p == "") continue;
      if (!FileSystem.exists(p)) {
        missing.push(p);
        continue;
      }
      files.push(p);
      texts.push(File.getContent(p));
      var d = haxe.io.Path.directory(JitCache.normalize(p));
      if (d != "" && !dirs.exists(d)) {
        dirs.set(d, true);
        incs.push(d);
      }
    }
    if (files.length == 0 && missing.length == 0) return null;
    return {files: files, texts: texts, includes: incs, missing: missing};
  }

  static function keySrc(src:String, multi:Null<JitMulti>):String {
    if (multi == null) return src;
    var b = new StringBuf();
    b.add(src);
    for (t in multi.texts) {
      b.add("\n--tu--\n");
      b.add(t);
    }
    return b.toString();
  }

  static function compileNow(name:String, src:String, ?o:JitOptions):JitModule {
    if (debug) log("[jit] compile enter " + name);
    ensure();
    if (debug) log("[jit] ensured " + ready);
    var multi = multiOf(o);
    var m = new JitModule(name, nextId++, "", src);
    m.extraSources = multi == null ? null : multi.texts;
    if (multi != null && multi.missing.length > 0) {
      for (p in multi.missing) m.diag.push(diag("E_NOFILE", p));
      m.ok = false;
      return m;
    }
    applyFlags(o);
    var key = JitCache.key(keySrc(src, multi), flagStr(o));
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
      m.symbols = scanAll(m.allSources());
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
    var loaded = false;
    if (existing != null) {
      m.cached = true;
      totalCacheHits++;
      loaded = load(m, existing);
      if (!loaded && ready) {
        var why = m.diag.length > 0 ? m.diag[0].code : "E_LOAD";
        if (verbose) log("[jit] cached binary rejected (" + why + "), rebuilding");
        try FileSystem.deleteFile(existing) catch (e:Dynamic) {}
        totalCacheHits--;
        m.cached = false;
        m.diag = [];
        m.log = "";
        m.image = null;
      }
    }
    if (!loaded) {
      var t0 = Sys.time();
      var r = compiler.build(key, src, o == null ? 0 : (o.lineShift ?? 0), o == null ? null : o.sigs, multi);
      totalBuilds++;
      m.ms = r.ms;
      m.diag = r.diag;
      m.log = r.log;
      if (!r.ok) return m;
      if (!load(m, r.dll)) return m;
    }
    m.symbols = scanAll(m.allSources());
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
    var m = compile(n, File.getContent(path), o);
    m.mainPath = path;
    return m;
  }

  static var cbCache:Map<String, Float> = new Map();
  static var cbName = ~/^[A-Za-z_][A-Za-z0-9_]*$/;

  public static function callback(name:String, shape:String = "d(d)"):Float {
    ensure();
    if (name == null || !cbName.match(name)) return 0;
    var key = name + "|" + shape;
    var hit = cbCache.get(key);
    if (hit != null) return hit;
    var l = shape.indexOf("(");
    var r = shape.indexOf(")", l < 0 ? 0 : l);
    if (l < 0 || r < 0) return 0;
    var ret = switch (StringTools.trim(shape.substr(0, l))) {
      case "d": "double";
      case "i": "int";
      case "f": "float";
      case "v": "void";
      case "s": "const char*";
      default: null;
    };
    if (ret == null) return 0;
    var ps:Array<String> = [];
    var vs:Array<String> = [];
    for (k in StringTools.trim(shape.substring(l + 1, r)).split(",")) {
      var c = StringTools.trim(k);
      var ty = switch (c) {
        case "d": "double";
        case "i": "int";
        case "f": "float";
        case "p": "const void*";
        default: null;
      };
      if (ty == null) return 0;
      ps.push(ty + " a" + ps.length);
      vs.push(c == "p" ? "(double)(size_t)a" + (ps.length - 1) : "(double)a" + (ps.length - 1));
    }
    while (vs.length < 4) vs.push("0.0");
    var arg = "(void*)0, \"" + name + "\", (int)strlen(\"" + name + "\"), " + vs.join(", ");
    var text = ret == "const char*";
    var body = text
      ? "if (!rjit_hs) return \"\";\n  return rjit_hs(" + arg + ");"
      : (ret == "void"
        ? "if (!rjit_hc) return;\n  (void)rjit_hc(" + arg + ");"
        : "if (!rjit_hc) return 0;\n  return (" + ret + ")rjit_hc(" + arg + ");");
    var src = "typedef double (*RJitHC)(void*, const char*, int, double, double, double, double);\n"
      + "typedef const char* (*RJitHS)(void*, const char*, int, double, double, double, double);\n"
      + "static RJitHC rjit_hc = 0;\n"
      + "static RJitHS rjit_hs = 0;\n"
      + 'extern "C" RJIT_API void rjit_cb_bind(void* f, void* t) { rjit_hc = (RJitHC)f; rjit_hs = (RJitHS)t; }\n'
      + 'extern "C" RJIT_API ' + ret + " rjit_cb(" + ps.join(", ") + ") {\n"
      + "  " + body + "\n}\n";
    var m = compile("rjitcb_" + name + "_" + new EReg("[^A-Za-z0-9]", "g").replace(shape, "_"), src);
    if (!m.ok) {
      log("[jit] callback compile failed: " + (m.diag.length > 0 ? JitCompiler.describe(m.diag[0]) : "no diag"));
      return 0;
    }
    var bind = m.resolve("rjit_cb_bind");
    if (bind != 0) JitNative.callVoid2(bind, JitNative.hostCall(), JitNative.hostStr());
    var a = JitNative.toFloat(m.resolve("rjit_cb"));
    if (a != 0) cbCache.set(key, a);
    return a;
  }

  public static function compileAsync(name:String, src:String, cb:Null<JitModule>->Void, ?o:JitOptions):Void {
    ensure();
    if (!ready) {
      cb(compile(name, src, o));
      return;
    }
    applyFlags(o);
    var multi = multiOf(o);
    var key = JitCache.key(keySrc(src, multi), flagStr(o));
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
      loader: o == null || o.loader == null ? loader : o.loader,
      multi: multi,
      cb: cb,
      done: false,
      result: null
    });
    pump();
  }

  public static function reload(name:String, src:String = null, ?o:JitOptions):JitModule {
    var m = mods.get(name);
    var s = src;
    if (s == null && m != null && m.mainPath != "" && FileSystem.exists(m.mainPath)) {
      try s = File.getContent(m.mainPath) catch (e:Dynamic) {}
    }
    if (s == null && m != null) s = m.src;
    if (s == null) return null;
    var opts:JitOptions = {force: true};
    if (m != null && m.sourcePaths != null && src == null) opts.sources = m.sourcePaths;
    if (o != null) {
      if (o.opt != null) opts.opt = o.opt;
      if (o.std != null) opts.std = o.std;
      if (o.flags != null) opts.flags = o.flags;
      if (o.cache != null) opts.cache = o.cache;
      if (o.sources != null) opts.sources = o.sources;
    }
    return compile(name, s, opts);
  }

  static var evalMods:Array<String> = [];
  public static var maxEvalModules:Int = 16;

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
    if (evalMods.indexOf(n) < 0) evalMods.push(n);
    while (evalMods.length > maxEvalModules) {
      var old = evalMods.shift();
      if (old != n) dispose(old);
    }
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
    if (StringTools.startsWith(name, "rjitcb_")) cbCache.clear();
  }

  public static function disposeAll():Void {
    var names = [];
    for (k in mods.keys()) names.push(k);
    for (n in names) dispose(n);
  }

  public static function forget(m:JitModule):Void {
    if (m == null) return;
    var cur = mods.get(m.name);
    if (cur == m) mods.remove(m.name);
  }

  public static function retire(h:cpp.SizeT, image:JitImage = null, ctx:cpp.SizeT = 0):Void {
    if (h != 0 || image != null || ctx != 0) retired.push({h: h, t: frame, image: image, ctx: ctx});
  }

  public static function watch(path:String, ?name:String, ?onReload:JitModule->Void):Bool {
    if (!FileSystem.exists(path)) return false;
    var n = name == null ? haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(path)) : name;
    var cur = "";
    var mt:Float = 0;
    var sz = 0;
    try {
      cur = File.getContent(path);
      var st = FileSystem.stat(path);
      mt = st.mtime.getTime();
      sz = st.size;
    } catch (e:Dynamic) return false;
    for (w in watched) {
      if (w.path == path) {
        w.name = n;
        w.sig = cur;
        w.cb = onReload;
        w.mt = mt;
        w.sz = sz;
        return true;
      }
    }
    watched.push({path: path, name: n, sig: cur, cb: onReload, mt: mt, sz: sz});
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
      var mt:Float = -1;
      var sz = -1;
      try {
        var st = FileSystem.stat(w.path);
        mt = st.mtime.getTime();
        sz = st.size;
      } catch (e:Dynamic) continue;
      if (mt == w.mt && sz == w.sz && Sys.time() * 1000.0 - mt > 2000.0) continue;
      var src = "";
      try src = File.getContent(w.path) catch (e:Dynamic) continue;
      w.mt = mt;
      w.sz = sz;
      if (src == w.sig) continue;
      w.sig = src;
      var opts:JitOptions = {force: true};
      var cur = mods.get(w.name);
      if (cur != null && cur.sourcePaths != null) opts.sources = cur.sourcePaths;
      var m = compile(w.name, src, opts);
      if (m.ok) {
        if (verbose) log("[jit] reloaded " + w.name);
        if (w.cb != null) w.cb(m);
      } else if (verbose) {
        log("[jit] reload failed for " + w.name);
      }
    }
  }

  static var timeoutsSeen:Int = 0;

  static function reportTimeouts():Void {
    var n = JitNative.jobTimeouts();
    if (n == timeoutsSeen) return;
    var missed = n - timeoutsSeen;
    timeoutsSeen = n;
    JitHost.error("callback", JitNative.jobTimeoutName(), missed + " queued call(s) timed out, the host did not pump");
  }

  public static function tick():Void {
    JitNative.pump();
    reportTimeouts();
    frame++;
    tickSweep();
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
          if (r.ctx != 0) JitNative.freeCtx(r.ctx);
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
      try {
        start(j);
      } catch (e:Dynamic) {
        j.result = null;
        j.done = true;
      }
    }
  }

  static function start(j:JitJob):Void {
    var comp = compiler;
    var run = function() {
      var r:Null<JitResult> = null;
      try {
        r = comp.build(j.key, j.src, j.shift, j.sigs, j.multi);
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
    m.extraSources = j.multi == null ? null : j.multi.texts;
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
    var savedLoader = loader;
    if (j.loader != null) loader = j.loader;
    if (!load(m, r.dll)) {
      loader = savedLoader;
      if (verbose) Sys.println('[jit] ${j.name} async load failed');
      j.cb(m);
      return;
    }
    loader = savedLoader;
    m.symbols = scanAll(m.allSources());
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

  static function usesExceptions(m:JitModule):Bool {
    if (m == null) return false;
    for (s in m.allSources()) {
      if (s == null) continue;
      if (s.indexOf("throw") >= 0 || s.indexOf("catch") >= 0 || s.indexOf("try {") >= 0 || s.indexOf("try{") >= 0) return true;
    }
    return false;
  }

  static function sym(image:JitImage, h:cpp.SizeT, n:String):cpp.SizeT {
    return image != null ? JitLoader.proc(image, n) : JitNative.getProc(h, n);
  }

  static function load(m:JitModule, dll:String):Bool {
    if (debug) log("[jit] load 1 " + dll);
    var h:cpp.SizeT = 0;
    var map = loader == "auto" || loader == "manual";
    if (map && usesExceptions(m)) {
      map = false;
      if (verbose) log("[jit] manual mapping cannot unwind C++ exceptions, using the system loader");
    }
    if (map) {
      var image = JitLoader.load(dll);
      if (image.ok) {
        m.image = image;
        h = image.base;
      } else if (loader == "manual" && !image.needsLoader) {
        m.diag.push(diag("E_IMAGE", image.error));
        return false;
      } else if (debug || image.needsLoader) {
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
    var c = JitNative.mkctx(m.id, JitAbi.VERSION);
    if (c == 0) {
      if (m.image != null) JitLoader.unload(m.image) else JitNative.unloadDll(h);
      m.image = null;
      m.diag.push(diag("E_CTX", "context allocation failed"));
      return false;
    }
    var init = sym(m.image, h, "rjit_init");
    if (init != 0) {
      var rc = JitNative.callInt1(init, c);
      if (rc != 0) {
        JitNative.freeCtx(c);
        if (m.image != null) JitLoader.unload(m.image) else JitNative.unloadDll(h);
        m.image = null;
        m.diag.push(diag("E_INIT", "rjit_init returned " + rc));
        return false;
      }
    }
    m.attach(h, c);
    m.dll = dll;
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

  public static function scanAll(texts:Array<String>):Array<String> {
    var out:Array<String> = [];
    var seen = new Map<String, Bool>();
    for (t in texts) {
      for (s in scan(t)) {
        if (seen.exists(s)) continue;
        seen.set(s, true);
        out.push(s);
      }
    }
    return out;
  }

  public static function compileFiles(name:String, mainPath:String, otherPaths:Array<String>, ?o:JitOptions):JitModule {
    if (!FileSystem.exists(mainPath)) {
      var m = new JitModule(name, nextId++, "", "");
      m.diag.push(diag("E_NOFILE", mainPath));
      return m;
    }
    var opts:JitOptions = {sources: otherPaths};
    if (o != null) {
      if (o.opt != null) opts.opt = o.opt;
      if (o.std != null) opts.std = o.std;
      if (o.flags != null) opts.flags = o.flags;
      if (o.force != null) opts.force = o.force;
      if (o.verbose != null) opts.verbose = o.verbose;
      if (o.lineShift != null) opts.lineShift = o.lineShift;
      if (o.sigs != null) opts.sigs = o.sigs;
      if (o.loader != null) opts.loader = o.loader;
      if (o.includes != null) opts.includes = o.includes;
    }
    var m = compile(name, File.getContent(mainPath), opts);
    m.sourcePaths = otherPaths == null ? null : otherPaths.copy();
    m.mainPath = mainPath;
    return m;
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

  public static function clean(keep:Int = 2):Int {
    if (cache == null) return 0;
    var n = 0;
    for (k in cache.keys()) n += cache.prune(k, keep);
    return n;
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
