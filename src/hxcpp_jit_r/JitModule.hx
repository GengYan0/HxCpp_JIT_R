package hxcpp_jit_r;

import hxcpp_jit_r.JitCompiler.JitDiag;
import hxcpp_jit_r.JitPe.PeImage;
import hxcpp_jit_r.JitScan.JitFnInfo;
import hxcpp_jit_r.JitScan.JitVarInfo;
import hxcpp_jit_r.JitScan.JitStructInfo;

class JitModule {
  public var name:String;
  public var id:Int;
  public var key:String;
  public var src:String;
  public var dll:String = "";
  public var symbols:Array<String> = [];
  public var diag:Array<JitDiag> = [];
  public var log:String = "";
  public var ok:Bool = false;
  public var ms:Float = 0.0;
  public var cached:Bool = false;
  public var calls:Int = 0;
  public var pe:PeImage = null;

  var handle:cpp.SizeT = 0;
  var ctx:cpp.SizeT = 0;
  var index:Map<String, Int> = new Map();
  var ptrs:Array<cpp.SizeT> = [];
  var misses:Map<String, Bool> = new Map();
  var fns:Map<String, JitFnInfo> = new Map();
  var sigsOf:Map<String, Array<String>> = new Map();
  var vars:Map<String, JitVarInfo> = new Map();
  var structs:Map<String, JitStructInfo> = new Map();
  var disps:Map<String, cpp.SizeT> = new Map();

  public function new(name:String, id:Int, key:String, src:String) {
    this.name = name;
    this.id = id;
    this.key = key;
    this.src = src;
  }

  public function resolve(n:String):cpp.SizeT {
    if (pe != null) return JitPe.proc(pe, n);
    if (handle == 0) return 0;
    return JitNative.getProc(handle, n);
  }

  public function attach(h:cpp.SizeT, c:cpp.SizeT):Void {
    handle = h;
    ctx = c;
    scan();
  }

  public function scan():Void {
    fns = new Map();
    vars = new Map();
    sigsOf = new Map();
    structs = new Map();
    for (s in JitScan.structs(src)) structs.set(s.name, s);
    for (f in JitScan.functions(src)) {
      if (!fns.exists(f.name)) fns.set(f.name, f);
      var a = sigsOf.get(f.name);
      if (a == null) {
        a = [];
        sigsOf.set(f.name, a);
      }
      if (a.indexOf(f.sig) < 0) a.push(f.sig);
    }
    for (v in JitScan.globals(src)) vars.set(v.name, v);
  }

  public function signatures(n:String):Array<String> {
    var a = sigsOf.get(n);
    return a == null ? [] : a;
  }

  public function ptr(n:String):JitPtr {
    return new JitPtr(address(n));
  }

  static inline function guard(r:Float, method:String, n:String):Float {
    if (r != r) {
      JitHost.error(method, n, "native exception caught");
      return 0.0;
    }
    return r;
  }

  public function varNames():Array<String> {
    var out = [];
    for (k in vars.keys()) out.push(k);
    return out;
  }

  public function fnNames():Array<String> {
    var out = [];
    for (k in fns.keys()) out.push(k);
    return out;
  }

  public function arraySize(n:String):Int {
    var v = vars.get(n);
    return v == null ? 0 : v.size;
  }

  public function kindOf(n:String):String {
    var v = vars.get(n);
    return v == null ? "" : v.kind;
  }

  public function fieldsOf(n:String):Array<String> {
    var v = vars.get(n);
    if (v == null || v.kind != "struct") return [];
    var st = structs.get(v.structName);
    if (st == null) return [];
    return [for (f in st.fields) f.name];
  }

  public function signature(n:String):String {
    var f = fns.get(n);
    return f == null ? "" : f.sig;
  }

  public function getVar(n:String):Float {
    var v = vars.get(n);
    if (v == null || handle == 0 || v.kind != "num") return 0.0;
    var p = resolve("rjit_getv_" + n);
    if (p == 0) return 0.0;
    return JitNative.invoke(p, ctx, 0, 0, 0, 0, 0, 0, 0);
  }

  public function setVar(n:String, v:Float):Bool {
    var info = vars.get(n);
    if (info == null || info.isConst || handle == 0 || info.kind != "num") return false;
    var p = resolve("rjit_setv_" + n);
    if (p == 0) return false;
    JitNative.invoke(p, ctx, 1, v, 0, 0, 0, 0, 0);
    return true;
  }

  public function setVarSupported(n:String):Bool {
    var v = vars.get(n);
    return v != null && !v.isConst && v.kind == "num";
  }

  public function getField(v:String, f:String):Float {
    if (handle == 0) return Math.NaN;
    var p = resolve("rjit_getf_" + JitCodegen.fieldName(v, f));
    if (p == 0) return Math.NaN;
    return JitNative.invoke(p, ctx, 0, 0, 0, 0, 0, 0, 0);
  }

  public function setField(v:String, f:String, val:Float):Bool {
    if (handle == 0) return false;
    var p = resolve("rjit_setf_" + JitCodegen.fieldName(v, f));
    if (p == 0) return false;
    JitNative.invoke(p, ctx, 1, val, 0, 0, 0, 0, 0);
    return true;
  }

  public function getIndex(v:String, i:Int):Float {
    if (handle == 0) return Math.NaN;
    var p = resolve("rjit_geta_" + v);
    if (p == 0) return Math.NaN;
    return JitNative.invoke(p, ctx, 1, i, 0, 0, 0, 0, 0);
  }

  public function setIndex(v:String, i:Int, val:Float):Bool {
    if (handle == 0) return false;
    var p = resolve("rjit_seta_" + v);
    if (p == 0) return false;
    JitNative.invoke(p, ctx, 2, i, val, 0, 0, 0, 0);
    return true;
  }

  public function get(path:String):Float {
    var v = path;
    var dot = path.indexOf(".");
    var lb = path.indexOf("[");
    if (dot > 0) {
      var f = path.substr(dot + 1);
      if (f.indexOf(".") >= 0 || f.indexOf("[") >= 0) return Math.NaN;
      return getField(path.substr(0, dot), f);
    }
    if (lb > 0) {
      var rb = path.indexOf("]", lb);
      if (rb < 0) return Math.NaN;
      var i = Std.parseInt(StringTools.trim(path.substring(lb + 1, rb)));
      if (i == null) return Math.NaN;
      return getIndex(path.substr(0, lb), i);
    }
    var info = vars.get(v);
    if (info == null) return Math.NaN;
    if (info.kind != "num") return Math.NaN;
    return getVar(v);
  }

  public function set(path:String, val:Float):Bool {
    var dot = path.indexOf(".");
    var lb = path.indexOf("[");
    if (dot > 0) {
      var f = path.substr(dot + 1);
      if (f.indexOf(".") >= 0 || f.indexOf("[") >= 0) return false;
      return setField(path.substr(0, dot), f, val);
    }
    if (lb > 0) {
      var rb = path.indexOf("]", lb);
      if (rb < 0) return false;
      var i = Std.parseInt(StringTools.trim(path.substring(lb + 1, rb)));
      if (i == null) return false;
      return setIndex(path.substr(0, lb), i, val);
    }
    return setVar(path, val);
  }

  static function bytesOf(strs:Array<String>, i:Int):haxe.io.Bytes {
    if (strs == null || i >= strs.length) return null;
    var s = strs[i];
    if (s == null) return null;
    return haxe.io.Bytes.ofString(s);
  }

  public function callAuto(n:String, args:Array<Float>, ?strs:Array<String>):Float {
    var f = fns.get(n);
    if (f == null || !f.callable || handle == 0) return callA(n, args);
    var fp = resolve("rjit_ptr_" + JitCodegen.ptrName(n, f.sig));
    if (fp == 0) fp = resolve("rjit_ptr_" + n);
    if (fp == 0) return callA(n, args);
    var d = disps.get(f.sig);
    if (d == null) {
      d = resolve(JitCodegen.dispName(f.sig));
      if (d == 0) return callA(n, args);
      disps.set(f.sig, d);
    }
    calls++;
    var r = f.sig.indexOf("s") >= 0 || f.sig.indexOf("S") >= 0
      ? JitNative.callViaB(d, fp, ctx, args.length, a(args, 0), a(args, 1), a(args, 2), a(args, 3), a(args, 4), a(args, 5),
          bytesOf(strs, 0), bytesOf(strs, 1), bytesOf(strs, 2), bytesOf(strs, 3))
      : JitNative.callVia(d, fp, ctx, args.length, a(args, 0), a(args, 1), a(args, 2), a(args, 3), a(args, 4), a(args, 5));
    return guard(r, "callAuto", n);
  }

  static inline function a(v:Array<Float>, i:Int):Float {
    return v.length > i ? v[i] : 0.0;
  }

  public function valid():Bool {
    return handle != 0 && ctx != 0;
  }

  public function fn(n:String):cpp.SizeT {
    var i = index.get(n);
    if (i != null) return ptrs[i];
    if (handle == 0 || misses.exists(n)) return 0;
    var r = resolve("rjit_" + n);
    if (r == 0) r = resolve(n);
    if (r == 0) {
      misses.set(n, true);
      return 0;
    }
    index.set(n, ptrs.length);
    ptrs.push(r);
    return r;
  }

  public function has(n:String):Bool {
    if (fn(n) != 0) return true;
    return symbols.indexOf(n) >= 0;
  }

  public function call(n:String, a0:Float = 0.0, a1:Float = 0.0, a2:Float = 0.0, a3:Float = 0.0, a4:Float = 0.0, a5:Float = 0.0):Float {
    var f = fn(n);
    if (f == 0) return 0.0;
    calls++;
    return guard(JitNative.invoke(f, ctx, 6, a0, a1, a2, a3, a4, a5), "call", n);
  }

  public function callA(n:String, args:Array<Float>):Float {
    var f = fn(n);
    if (f == 0) return 0.0;
    var a0 = args.length > 0 ? args[0] : 0.0;
    var a1 = args.length > 1 ? args[1] : 0.0;
    var a2 = args.length > 2 ? args[2] : 0.0;
    var a3 = args.length > 3 ? args[3] : 0.0;
    var a4 = args.length > 4 ? args[4] : 0.0;
    var a5 = args.length > 5 ? args[5] : 0.0;
    calls++;
    return guard(JitNative.invoke(f, ctx, args.length, a0, a1, a2, a3, a4, a5), "callA", n);
  }

  public function address(n:String):Float {
    var info = fns.get(n);
    if (info != null && handle != 0) {
      var p = resolve("rjit_ptr_" + JitCodegen.ptrName(n, info.sig));
      if (p != 0) return JitNative.invoke(p, ctx, 0, 0, 0, 0, 0, 0, 0);
    }
    var f = fn(n);
    return f == 0 ? 0.0 : JitNative.toFloat(f);
  }

  public function callSig(n:String, sig:String, args:Array<Float>, ?strs:Array<String>):Float {
    if (handle == 0) return 0.0;
    var d = disps.get(sig);
    if (d == null) {
      d = resolve(JitCodegen.dispName(sig));
      if (d == 0) return 0.0;
      disps.set(sig, d);
    }
    var fp = resolve("rjit_ptr_" + JitCodegen.ptrName(n, sig));
    if (fp == 0) return 0.0;
    calls++;
    var r = sig.indexOf("s") >= 0 || sig.indexOf("S") >= 0
      ? JitNative.callViaB(d, fp, ctx, args.length, a(args, 0), a(args, 1), a(args, 2), a(args, 3), a(args, 4), a(args, 5),
          bytesOf(strs, 0), bytesOf(strs, 1), bytesOf(strs, 2), bytesOf(strs, 3))
      : JitNative.callVia(d, fp, ctx, args.length, a(args, 0), a(args, 1), a(args, 2), a(args, 3), a(args, 4), a(args, 5));
    return guard(r, "callSig", n);
  }

  public function hasSig(sig:String):Bool {
    return handle != 0 && resolve(JitCodegen.dispName(sig)) != 0;
  }

  public function callStr(n:String, args:Array<Float> = null):String {
    JitHost.clearRet(id);
    callA(n, args == null ? [] : args);
    return JitHost.takeRet(id);
  }

  public function dispose():Void {
    if (handle == 0) return;
    var d = resolve("rjit_deinit");
    if (d != 0) JitNative.invoke(d, ctx, 0, 0, 0, 0, 0, 0, 0);
    JitHost.remove(id);
    if (ctx != 0) JitNative.freeCtx(ctx);
    Jit.retire(handle, pe);
    pe = null;
    handle = 0;
    ctx = 0;
    index = new Map();
    ptrs = [];
    misses = new Map();
  }

  public function stats():String {
    return 'module=$name id=$id symbols=${symbols.length} calls=$calls dll=$dll';
  }

  public function report():String {
    var b = new StringBuf();
    b.add('module "$name"  ok=$ok  cached=$cached  build=${Std.int(ms)}ms  dll=$dll\n');
    if (symbols.length > 0) b.add("symbols: " + symbols.join(", ") + "\n");
    for (d in diag) b.add("  " + JitCompiler.describe(d) + "\n");
    if (!ok && log != "") b.add(log + "\n");
    return b.toString();
  }
}
