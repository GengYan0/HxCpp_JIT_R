package hxcpp_jit_r;

import hxcpp_jit_r.JitCompiler.JitDiag;
import hxcpp_jit_r.JitLoader.JitImage;
import hxcpp_jit_r.JitScan.JitFnInfo;
import hxcpp_jit_r.JitScan.JitVarInfo;
import hxcpp_jit_r.JitScan.JitStructInfo;
import hxcpp_jit_r.JitExpr.JitValue;

typedef JitSeg = {
  var field:Bool;
  var name:String;
  var index:Int;
}

class JitModule {
  public var name:String;
  public var id:Int;
  public var alive:Bool = true;
  public var key:String;
  public var src:String;
  public var dll:String = "";
  public var symbols:Array<String> = [];
  public var skipped:Array<String> = [];
  public var diag:Array<JitDiag> = [];
  public var log:String = "";
  public var ok:Bool = false;
  public var ms:Float = 0.0;
  public var cached:Bool = false;
  public var pinned:Bool = false;
  public var poisoned:Bool = false;
  public var calls:Int = 0;
  public var image:JitImage = null;
  public var extraSources:Array<String> = null;
  public var sourcePaths:Array<String> = null;
  public var mainPath:String = "";

  var handle:cpp.SizeT = 0;
  var ctx:cpp.SizeT = 0;
  var index:Map<String, Int> = new Map();
  var ptrs:Array<cpp.SizeT> = [];
  var misses:Map<String, Bool> = new Map();
  var poisonReported:Bool = false;
  var fns:Map<String, JitFnInfo> = new Map();
  var bySig:Map<String, JitFnInfo> = new Map();
  var sigsOf:Map<String, Array<String>> = new Map();
  var vars:Map<String, JitVarInfo> = new Map();
  var structs:Map<String, JitStructInfo> = new Map();
  var disps:Map<String, Float> = new Map();
  var pre:Map<String, Float> = new Map();

  public function new(name:String, id:Int, key:String, src:String) {
    this.name = name;
    this.id = id;
    this.key = key;
    this.src = src;
  }

  public function resolve(n:String):cpp.SizeT {
    if (image != null) return JitLoader.proc(image, n);
    if (handle == 0) return 0;
    return JitNative.getProc(handle, n);
  }

  public function attach(h:cpp.SizeT, c:cpp.SizeT):Void {
    handle = h;
    ctx = c;
    scan();
    warm();
  }

  public function warm():Void {
    if (handle == 0) return;
    for (k in bySig.keys()) {
      var f = bySig.get(k);
      if (f == null) continue;
      dispFor(f);
      ptrOf(f.name, f.sig);
      if (f.ret != "S") continue;
      var ks = "str|" + f.name + "|" + f.sig;
      if (pre.exists(ks)) continue;
      var p = resolve("rjit_str_" + JitCodegen.ptrName(f.name, f.sig));
      if (p != 0) pre.set(ks, JitNative.toFloat(p));
    }
    for (n in fns.keys()) fn(n);
  }

  public function dispFor(f:JitFnInfo, arity:Int = -1):cpp.SizeT {
    if (f == null) return 0;
    var full = f.args.length;
    var k = arity < 0 || arity >= full ? full : arity;
    if (k != full) {
      var ka = "da|" + f.name + "|" + f.sig + "|" + k;
      var va = pre.get(ka);
      if (va != null) return JitNative.toSizeT(va);
      var da = resolve(JitCodegen.arityDispName(f, k));
      if (da != 0) pre.set(ka, JitNative.toFloat(da));
      return da;
    }
    if (!JitCodegen.needsCustom(f)) return dispOf(f.sig);
    var kk = "dn|" + f.name + "|" + f.sig;
    var v = pre.get(kk);
    if (v != null) return JitNative.toSizeT(v);
    var d = resolve(JitCodegen.dispNameOf(f.name, f.sig));
    if (d != 0) pre.set(kk, JitNative.toFloat(d));
    return d;
  }

  function dispOf(sg:String):cpp.SizeT {
    var v = disps.get(sg);
    if (v != null) return JitNative.toSizeT(v);
    var d = resolve(JitCodegen.dispName(sg));
    if (d != 0) disps.set(sg, JitNative.toFloat(d));
    return d;
  }

  function ptrOf(n:String, sg:String):cpp.SizeT {
    var k = n + "|" + sg;
    var v = pre.get(k);
    if (v != null) return JitNative.toSizeT(v);
    var p = resolve("rjit_ptr_" + JitCodegen.ptrName(n, sg));
    if (p != 0) pre.set(k, JitNative.toFloat(p));
    return p;
  }

  public function allSources():Array<String> {
    var out = [src];
    if (extraSources != null) for (t in extraSources) if (t != null) out.push(t);
    return out;
  }

  public function scan():Void {
    fns = new Map();
    bySig = new Map();
    vars = new Map();
    sigsOf = new Map();
    structs = new Map();
    skipped = [];
    var texts = allSources();
    for (t in texts) for (s in JitScan.structs(t)) structs.set(s.name, s);
    var allStructs = [];
    for (t in texts) for (st in JitScan.structs(t)) allStructs.push(st);
    for (t in texts) {
      for (f in JitScan.functions(t, allStructs)) {
        if (!f.callable && skipped.indexOf(f.name) < 0) skipped.push(f.name);
        if (!bySig.exists(f.name + "|" + f.sig)) bySig.set(f.name + "|" + f.sig, f);
        if (!fns.exists(f.name)) fns.set(f.name, f);
        var a = sigsOf.get(f.name);
        if (a == null) {
          a = [];
          sigsOf.set(f.name, a);
        }
        if (a.indexOf(f.sig) < 0) a.push(f.sig);
      }
    }
    for (v in JitScan.globals(src)) vars.set(v.name, v);
    if (extraSources != null) {
      var mainStructs = new Map<String, Bool>();
      for (st in JitScan.structs(src)) mainStructs.set(st.name, true);
      for (t in extraSources) {
        for (v in JitScan.globals(t)) {
          if (vars.exists(v.name) || v.isConst || v.isStatic) continue;
          if ((v.kind == "struct" || v.kind == "structarray") && !mainStructs.exists(v.structName)) continue;
          vars.set(v.name, v);
        }
      }
    }
  }

  public function signatures(n:String):Array<String> {
    var a = sigsOf.get(n);
    return a == null ? [] : a;
  }

  public function ptr(n:String):JitPtr {
    return new JitPtr(address(n));
  }

  inline function guard(r:Float, method:String, n:String):Float {
    if (poisoned) {
      if (!poisonReported) {
        poisonReported = true;
        JitHost.error(method, n, "the module faulted earlier and was not repaired, reload it");
      }
      return 0.0;
    }
    if (r != r) {
      if (JitNative.isFault(r) != 0 && Jit.poisonOnFault) {
        poisoned = true;
        JitHost.error(method, n, "the call faulted, the module is marked unusable, reload it");
      } else {
        JitHost.error(method, n, "native exception caught");
      }
      return 0.0;
    }
    return r;
  }

  public function guardAt(r:Float, method:String, n:String):Float {
    return guard(r, method, n);
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
    if (v == null || (v.kind != "struct" && v.kind != "structarray")) return [];
    var st = structs.get(v.structName);
    if (st == null) return [];
    return [for (f in st.fields) f.name];
  }

  public function leafFieldsOf(n:String):Array<String> {
    var v = vars.get(n);
    if (v == null || (v.kind != "struct" && v.kind != "structarray")) return [];
    return JitCodegen.leafPaths(structs, v.structName);
  }

  public function signature(n:String):String {
    var f = fns.get(n);
    return f == null ? "" : f.sig;
  }

  public function getVar(n:String):Float {
    var v = vars.get(n);
    if (v == null || handle == 0 || (v.kind != "num" && v.kind != "ptr")) return 0.0;
    var p = resolve("rjit_getv_" + n);
    if (p == 0) return 0.0;
    return JitNative.invoke(p, ctx, 0, 0, 0, 0, 0, 0, 0);
  }

  public function setVar(n:String, v:Float):Bool {
    var info = vars.get(n);
    if (info == null || info.isConst || handle == 0 || (info.kind != "num" && info.kind != "ptr")) return false;
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
    return getFieldPath(v, [f]);
  }

  public function setField(v:String, f:String, val:Float):Bool {
    return setFieldPath(v, [f], val);
  }

  public function getFieldPath(v:String, path:Array<String>):Float {
    if (handle == 0 || path == null || path.length == 0) return Math.NaN;
    var p = resolve("rjit_getf_" + v + "__" + path.join("__"));
    if (p == 0) return Math.NaN;
    return JitNative.invoke(p, ctx, 0, 0, 0, 0, 0, 0, 0);
  }

  public function setFieldPath(v:String, path:Array<String>, val:Float):Bool {
    if (handle == 0 || path == null || path.length == 0) return false;
    var p = resolve("rjit_setf_" + v + "__" + path.join("__"));
    if (p == 0) return false;
    JitNative.invoke(p, ctx, 1, val, 0, 0, 0, 0, 0);
    return true;
  }

  public function getElemField(v:String, i:Int, path:Array<String>):Float {
    if (handle == 0 || path == null || path.length == 0) return Math.NaN;
    var p = resolve("rjit_getfa_" + v + "__" + path.join("__"));
    if (p == 0) return Math.NaN;
    return JitNative.invoke(p, ctx, 1, i, 0, 0, 0, 0, 0);
  }

  public function setElemField(v:String, i:Int, path:Array<String>, val:Float):Bool {
    if (handle == 0 || path == null || path.length == 0) return false;
    var p = resolve("rjit_setfa_" + v + "__" + path.join("__"));
    if (p == 0) return false;
    JitNative.invoke(p, ctx, 2, i, val, 0, 0, 0, 0);
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

  public function arrayAddress(n:String):Float {
    var v = vars.get(n);
    if (v == null || v.kind != "array" || handle == 0) return 0;
    var p = resolve("rjit_addra_" + n);
    if (p == 0) return 0;
    return JitNative.invoke(p, ctx, 0, 0, 0, 0, 0, 0, 0);
  }

  public function elemSize(n:String):Int {
    var v = vars.get(n);
    if (v == null) return 0;
    if (v.kind == "structarray") {
      var p = resolve("rjit_szof_" + n);
      if (p == 0) return 0;
      return Std.int(JitNative.invoke(p, ctx, 0, 0, 0, 0, 0, 0, 0));
    }
    return elemSizeOf(v.elem);
  }

  public static function elemSizeOf(c:String):Int {
    return switch (c) {
      case "c", "b": 1;
      case "h": 2;
      case "l": 8;
      case "f": 4;
      case "d": 8;
      case "p", "s": 8;
      default: 4;
    }
  }

  public function readRaw(n:String, ?count:Int):haxe.io.Bytes {
    var v = vars.get(n);
    if (v == null || v.kind != "array") return null;
    var es = elemSize(n);
    if (es <= 0) return null;
    var cnt = count == null ? v.size : count;
    if (cnt > v.size) cnt = v.size;
    if (cnt < 0) cnt = 0;
    var a = arrayAddress(n);
    if (a == 0) return null;
    var bytes = haxe.io.Bytes.alloc(cnt * es);
    JitNative.copyOut(JitNative.toSizeT(a), bytes, cnt * es);
    return bytes;
  }

  public function writeRaw(n:String, bytes:haxe.io.Bytes):Bool {
    var v = vars.get(n);
    if (v == null || v.kind != "array" || v.isConst || bytes == null) return false;
    var a = arrayAddress(n);
    if (a == 0) return false;
    var cap = v.size * elemSize(n);
    var len = bytes.length > cap ? cap : bytes.length;
    JitNative.copyIn(JitNative.toSizeT(a), bytes, len);
    return true;
  }

  public function readDoubles(n:String, ?count:Int):Array<Float> {
    var v = vars.get(n);
    if (v == null || v.elem != "d") return [];
    var b = readRaw(n, count);
    if (b == null) return [];
    var out:Array<Float> = [];
    var i = 0;
    while (i + 8 <= b.length) {
      out.push(b.getDouble(i));
      i += 8;
    }
    return out;
  }

  public function writeDoubles(n:String, vals:Array<Float>):Bool {
    var v = vars.get(n);
    if (v == null || v.elem != "d" || vals == null) return false;
    var cnt = vals.length > v.size ? v.size : vals.length;
    var b = haxe.io.Bytes.alloc(cnt * 8);
    for (i in 0...cnt) b.setDouble(i * 8, vals[i]);
    return writeRaw(n, b);
  }

  public function readInts(n:String, ?count:Int):Array<Int> {
    var v = vars.get(n);
    if (v == null || (v.elem != "i" && v.elem != "u")) return [];
    var b = readRaw(n, count);
    if (b == null) return [];
    var out:Array<Int> = [];
    var i = 0;
    while (i + 4 <= b.length) {
      out.push(b.getInt32(i));
      i += 4;
    }
    return out;
  }

  public function writeInts(n:String, vals:Array<Int>):Bool {
    var v = vars.get(n);
    if (v == null || (v.elem != "i" && v.elem != "u") || vals == null) return false;
    var cnt = vals.length > v.size ? v.size : vals.length;
    var b = haxe.io.Bytes.alloc(cnt * 4);
    for (i in 0...cnt) b.setInt32(i * 4, vals[i]);
    return writeRaw(n, b);
  }

  public function callFast(n:String, a0:Float = 0.0, a1:Float = 0.0, a2:Float = 0.0, a3:Float = 0.0, a4:Float = 0.0, a5:Float = 0.0):Float {
    var f = fn(n);
    if (f == 0) return 0.0;
    calls++;
    return JitNative.invokeFast(f, ctx, 6, a0, a1, a2, a3, a4, a5);
  }

  public function get(path:String):Float {
    var s = StringTools.trim(path);
    if (s == "") return Math.NaN;
    if (s.charAt(0) == "&") {
      var t = StringTools.trim(s.substr(1));
      var q = parsePath(t);
      if (q != null && q.segs.length == 0) return addrOf(q.base);
      return Math.NaN;
    }
    var r = readPath(s);
    if (r != null) return r;
    if (JitExpr.looks(s)) return expr(s);
    return Math.NaN;
  }

  public function addrOf(n:String):Float {
    if (handle == 0) return 0.0;
    var p = resolve("rjit_addrv_" + n);
    if (p == 0) return 0.0;
    return JitNative.invoke(p, ctx, 0, 0, 0, 0, 0, 0, 0);
  }

  public function expr(e:String):Float {
    return JitExpr.eval(e, pathNum, pathStr, callExpr);
  }

  public function exprStr(e:String):String {
    return JitExpr.evalStr(e, pathNum, pathStr, callExpr);
  }

  function pathNum(n:String):Float {
    var r = readPath(n);
    return r == null ? Math.NaN : r;
  }

  function pathStr(n:String):String {
    var p = parsePath(n);
    if (p == null) return null;
    var info = vars.get(p.base);
    if (info == null) return null;
    var fields:Array<String> = [];
    for (q in p.segs) {
      if (!q.field) return null;
      fields.push(q.name);
    }
    if (fields.length == 0) return null;
    var t = fieldType(info.structName, fields);
    if (t != "S" && t != "s") return null;
    return str(n);
  }

  function callExpr(n:String, args:Array<JitValue>):Null<JitValue> {
    if (!fns.exists(n)) return null;
    var nums:Array<Float> = [];
    for (v in args) {
      switch (v) {
        case JNum(f): nums.push(f);
        case JStr(_): return null;
      }
    }
    return JNum(callAuto(n, nums));
  }

  public function set(path:String, val:Float):Bool {
    var s = StringTools.trim(path);
    if (s == "") return false;
    var p = parsePath(s);
    if (p == null) return false;
    return writePath(p, val);
  }

  public static function parsePath(p:String):Null<{base:String, segs:Array<JitSeg>}> {
    var s = StringTools.trim(p);
    var n = s.length;
    if (n == 0) return null;
    var i = 0;
    while (i < n && isNameChar(s.charCodeAt(i))) i++;
    if (i == 0) return null;
    var base = s.substring(0, i);
    var segs:Array<JitSeg> = [];
    while (i < n) {
      var c = s.charAt(i);
      if (c == ".") {
        i++;
        var s0 = i;
        while (i < n && isNameChar(s.charCodeAt(i))) i++;
        if (i == s0) return null;
        segs.push({field: true, name: s.substring(s0, i), index: 0});
      } else if (c == "[") {
        var rb = s.indexOf("]", i);
        if (rb < 0) return null;
        var num = Std.parseInt(StringTools.trim(s.substring(i + 1, rb)));
        if (num == null) return null;
        segs.push({field: false, name: "", index: num});
        i = rb + 1;
      } else {
        return null;
      }
    }
    return {base: base, segs: segs};
  }

  static inline function isNameChar(c:Int):Bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95;
  }

  function callIndex2(sym:String, ii:Int, jj:Int, two:Bool):Null<Float> {
    var fp = resolve(sym);
    if (fp == 0) return null;
    var r = two
      ? JitNative.invoke(fp, ctx, 2, ii, jj, 0, 0, 0, 0)
      : JitNative.invoke(fp, ctx, 1, ii, 0, 0, 0, 0, 0);
    return guard(r, "read", sym);
  }

  function readPath(s:String):Null<Float> {
    var p = parsePath(s);
    if (p == null) return null;
    var info = vars.get(p.base);
    if (info == null) return null;
    var segs = p.segs;
    if (segs.length == 0) {
      if (info.kind != "num" && info.kind != "ptr") return null;
      return getVar(p.base);
    }
    if (segs.length == 2 && segs[0].field && !segs[1].field && info.kind == "struct") {
      return callIndex2("rjit_getf2_" + p.base + "__" + segs[0].name, segs[1].index, 0, false);
    }
    if (segs.length == 3 && !segs[0].field && segs[1].field && !segs[2].field && info.kind == "structarray") {
      return callIndex2("rjit_getfa2_" + p.base + "__" + segs[1].name, segs[0].index, segs[2].index, true);
    }
    if (segs[0].field) {
      var fields = [];
      for (q in segs) {
        if (!q.field) return null;
        fields.push(q.name);
      }
      if (info.kind != "struct") return null;
      return getFieldPath(p.base, fields);
    }
    if (info.kind == "array") {
      if (segs.length != 1) return null;
      return getIndex(p.base, segs[0].index);
    }
    if (info.kind == "structarray") {
      var fields = [];
      for (i in 1...segs.length) {
        if (!segs[i].field) return null;
        fields.push(segs[i].name);
      }
      if (fields.length == 0) return null;
      return getElemField(p.base, segs[0].index, fields);
    }
    return null;
  }

  function writePath(p:{base:String, segs:Array<JitSeg>}, val:Float):Bool {
    var info = vars.get(p.base);
    if (info == null || info.isConst) return false;
    var segs = p.segs;
    if (segs.length == 0) {
      if (info.kind != "num" && info.kind != "ptr") return false;
      return setVar(p.base, val);
    }
    if (segs.length == 2 && segs[0].field && !segs[1].field && info.kind == "struct") {
      var fp2 = resolve("rjit_setf2_" + p.base + "__" + segs[0].name);
      if (fp2 == 0) return false;
      guard(JitNative.invoke(fp2, ctx, 2, segs[1].index, val, 0, 0, 0, 0), "write", p.base);
      return true;
    }
    if (segs.length == 3 && !segs[0].field && segs[1].field && !segs[2].field && info.kind == "structarray") {
      var fq = resolve("rjit_setfa2_" + p.base + "__" + segs[1].name);
      if (fq == 0) return false;
      guard(JitNative.invoke(fq, ctx, 3, segs[0].index, segs[2].index, val, 0, 0, 0), "write", p.base);
      return true;
    }
    if (segs[0].field) {
      var fields = [];
      for (q in segs) {
        if (!q.field) return false;
        fields.push(q.name);
      }
      if (info.kind != "struct") return false;
      return setFieldPath(p.base, fields, val);
    }
    if (info.kind == "array") {
      if (segs.length != 1) return false;
      return setIndex(p.base, segs[0].index, val);
    }
    if (info.kind == "structarray") {
      var fields = [];
      for (i in 1...segs.length) {
        if (!segs[i].field) return false;
        fields.push(segs[i].name);
      }
      if (fields.length == 0) return false;
      return setElemField(p.base, segs[0].index, fields, val);
    }
    return false;
  }

  static function bytesOf(strs:Array<String>, i:Int):haxe.io.Bytes {
    if (strs == null || i >= strs.length) return null;
    var s = strs[i];
    if (s == null) return null;
    var u = haxe.io.Bytes.ofString(s);
    var b = haxe.io.Bytes.alloc(u.length + 1);
    b.blit(0, u, 0, u.length);
    b.set(u.length, 0);
    return b;
  }

  public function pick(n:String, nums:Int, strs:Int):JitFnInfo {
    var list = sigsOf.get(n);
    if (list == null || list.length <= 1) return fns.get(n);
    for (sg in list) {
      var p = sg.indexOf("(");
      var a = p < 0 ? "" : sg.substr(p + 1, sg.length - p - 2);
      var ns = 0;
      var ss = 0;
      for (i in 0...a.length) {
        var c = a.charAt(i);
        if (c == "s" || c == "S" || c == "R" || c == "W") ss++;
        else ns++;
      }
      if (ns == nums && ss == strs) return bySig.get(n + "|" + sg);
    }
    if (strs == 0) {
      for (sg in list) {
        var f = bySig.get(n + "|" + sg);
        if (f == null) continue;
        var df = JitCodegen.defFrom(f);
        if (df >= 0 && nums >= df && nums < f.args.length) return f;
      }
    }
    return fns.get(n);
  }

  public function callAuto(n:String, args:Array<Float>, ?strs:Array<String>):Float {
    var a = args == null ? [] : args;
    return callPicked(pick(n, a.length, strs == null ? 0 : strs.length), n, a, strs);
  }

  public function callDyn(n:String, args:Array<Dynamic>):Float {
    var nums:Array<Float> = [];
    var pref = "";
    for (v in args) {
      if (v is Bool) {
        nums.push((v:Bool) ? 1.0 : 0.0);
        pref += "b";
      } else if (v is Int) {
        var i:Int = v;
        nums.push(i * 1.0);
        pref += "i";
      } else {
        nums.push(v);
        pref += "d";
      }
    }
    return callPicked(pickTyped(n, pref), n, nums, null);
  }

  static inline function isNumCode(c:String):Bool {
    return "dfbchiul".indexOf(c) >= 0;
  }

  function pickTyped(n:String, pref:String):JitFnInfo {
    var list = sigsOf.get(n);
    if (list == null) return fns.get(n);
    var best:JitFnInfo = null;
    var bestScore = -9999;
    var tie = false;
    for (sg in list) {
      var f = bySig.get(n + "|" + sg);
      if (f == null) continue;
      if (f.args.length != pref.length) continue;
      var score = 0;
      for (i in 0...pref.length) {
        var want = pref.charAt(i);
        var got = f.args[i];
        if (want == got) score += 3;
        else if (isNumCode(want) && isNumCode(got)) score += 1;
        else score -= 2;
      }
      if (score > bestScore) {
        bestScore = score;
        best = f;
        tie = false;
      } else if (score == bestScore && f != best) {
        tie = true;
      }
    }
    if (tie) {
      JitHost.error("callDyn", n, "overloads share the same arity and types, use callSig");
      return null;
    }
    return best == null ? fns.get(n) : best;
  }

  function callPicked(f:JitFnInfo, n:String, args:Array<Float>, strs:Array<String>):Float {
    if (f == null || !f.callable || handle == 0) return callA(n, args);
    if (f.ret == "t") return callStruct(n, args, strs).address;
    var fp = ptrOf(n, f.sig);
    if (fp == 0) fp = resolve("rjit_ptr_" + n);
    if (fp == 0) return callA(n, args);
    var ar = f.args.length;
    if (JitCodegen.defFrom(f) >= 0 && (strs == null || strs.length == 0)) ar = args.length;
    var d = dispFor(f, ar);
    if (d == 0) return callA(n, args);
    calls++;
    var r = usesStr(f.sig)
      ? JitNative.callViaB(d, fp, ctx, args.length, a(args, 0), a(args, 1), a(args, 2), a(args, 3), a(args, 4), a(args, 5),
          bytesOf(strs, 0), bytesOf(strs, 1), bytesOf(strs, 2), bytesOf(strs, 3))
      : JitNative.callVia(d, fp, ctx, args.length, a(args, 0), a(args, 1), a(args, 2), a(args, 3), a(args, 4), a(args, 5));
    return guard(r, "callAuto", n);
  }

  public function callWide(n:String, wide:Array<haxe.Int64>, ?nums:Array<Float>, ?strs:Array<String>):haxe.Int64 {
    var ws = wide == null ? [] : wide;
    var ns = nums == null ? [] : nums;
    var ss = strs == null ? [] : strs;
    var f = pickWide(n, ws.length, ns.length, ss.length);
    if (f == null) {
      JitHost.error("callWide", n, "no signature fits " + ws.length + " 64 bit, " + ns.length + " numeric and " + ss.length + " string arguments, use callWideSig when overloads fit the same counts");
      return haxe.Int64.ofInt(0);
    }
    return callWideSig(n, f.sig, ws, ns, ss);
  }

  public function callWideSig(n:String, sig:String, wide:Array<haxe.Int64>, ?nums:Array<Float>, ?strs:Array<String>):haxe.Int64 {
    var f = bySig.get(n + "|" + sig);
    if (f == null) f = fns.get(n);
    if (f == null || !f.callable || handle == 0) {
      JitHost.error("callWide", n, "signature " + sig + " is not callable");
      return haxe.Int64.ofInt(0);
    }
    if (f.ret == "S" || f.ret == "t" || f.ret == "R" || f.ret == "v") {
      JitHost.error("callWide", n, "a " + f.ret + " result does not fit an Int64");
      return haxe.Int64.ofInt(0);
    }
    var fp = ptrOf(n, f.sig);
    if (fp == 0) fp = resolve("rjit_ptr_" + n);
    var d = resolve(JitCodegen.wideNameOf(f));
    if (fp == 0 || d == 0) {
      JitHost.error("callWide", n, "no wide entry point was generated for " + f.sig);
      return haxe.Int64.ofInt(0);
    }
    var ws = wide == null ? [] : wide;
    var ns = nums == null ? [] : nums;
    var ss = strs == null ? [] : strs;
    var slots:Array<Float> = [];
    var texts:Array<String> = [];
    var wi = 0;
    var ni = 0;
    var si = 0;
    var bad = "";
    for (i in 0...f.args.length) {
      var c = f.args[i];
      var def = f.defaults[i];
      if (c == "l") {
        var v:haxe.Int64;
        if (wi < ws.length) {
          v = ws[wi];
          wi++;
        } else {
          var dv = defaultNumber(def);
          if (dv == null) {
            bad = "argument " + i + " is 64 bit and has no default";
            break;
          }
          v = haxe.Int64.fromFloat(dv);
        }
        slots.push(JitNative.bitsOf64(v.low, v.high));
      } else if (c == "s" || c == "S" || c == "R" || c == "W") {
        if (si < ss.length) {
          texts.push(ss[si]);
          si++;
        } else {
          var ds = defaultText(def);
          if (ds == null) {
            bad = "argument " + i + " is text and has no default";
            break;
          }
          texts.push(ds);
        }
      } else {
        var nv:Null<Float>;
        if (ni < ns.length) {
          nv = ns[ni];
          ni++;
        } else {
          nv = defaultNumber(def);
          if (nv == null) {
            bad = "argument " + i + " has no default";
            break;
          }
        }
        slots.push(nv);
      }
    }
    if (bad == "") {
      if (wi < ws.length) bad = "too many 64 bit arguments";
      else if (ni < ns.length) bad = "too many numeric arguments";
      else if (si < ss.length) bad = "too many string arguments";
    }
    if (bad != "") {
      JitHost.error("callWide", n, bad);
      return haxe.Int64.ofInt(0);
    }
    calls++;
    var r = texts.length > 0 || usesStr(f.sig)
      ? JitNative.callViaB(d, fp, ctx, slots.length, a(slots, 0), a(slots, 1), a(slots, 2), a(slots, 3), a(slots, 4), a(slots, 5),
          bytesOf(texts, 0), bytesOf(texts, 1), bytesOf(texts, 2), bytesOf(texts, 3))
      : JitNative.callVia(d, fp, ctx, slots.length, a(slots, 0), a(slots, 1), a(slots, 2), a(slots, 3), a(slots, 4), a(slots, 5));
    if (r != r) {
      if (JitNative.isFault(r) != 0 && Jit.poisonOnFault) {
        poisoned = true;
        JitHost.error("callWide", n, "the call faulted, the module is marked unusable, reload it");
      } else {
        JitHost.error("callWide", n, "native exception caught");
      }
      return haxe.Int64.ofInt(0);
    }
    if (f.ret == "l") return haxe.Int64.make(JitNative.hiOf64(r), JitNative.loOf64(r));
    return haxe.Int64.fromFloat(r);
  }

  function pickWide(n:String, wc:Int, nc:Int, sc:Int):JitFnInfo {
    var list = sigsOf.get(n);
    if (list == null || list.length <= 1) return fns.get(n);
    var best:JitFnInfo = null;
    var tie = false;
    for (sg in list) {
      var f = bySig.get(n + "|" + sg);
      if (f == null) continue;
      if (!f.callable) continue;
      var wi = 0;
      var ni = 0;
      var si = 0;
      var ok = true;
      for (i in 0...f.args.length) {
        var c = f.args[i];
        var hasDef = f.defaults[i] != null && f.defaults[i] != "";
        if (c == "l") {
          if (wi < wc) wi++
          else if (!hasDef) { ok = false; break; }
        } else if (c == "s" || c == "S" || c == "R" || c == "W") {
          if (si < sc) si++
          else if (!hasDef) { ok = false; break; }
        } else {
          if (ni < nc) ni++
          else if (!hasDef) { ok = false; break; }
        }
      }
      if (!ok || wi != wc || ni != nc || si != sc) continue;
      if (best == null) best = f else tie = true;
    }
    if (tie) return null;
    return best;
  }

  public static function defaultNumber(t:String):Null<Float> {
    if (t == null) return null;
    var s = StringTools.trim(t);
    if (s == "") return null;
    if (s == "true") return 1.0;
    if (s == "false") return 0.0;
    if (s.length == 3 && s.charAt(0) == "'" && s.charAt(2) == "'") return s.charCodeAt(1);
    if (s.charAt(0) == '"' || s.charAt(0) == '\'') return null;
    while (s.length > 0 && "fFuUlL".indexOf(s.charAt(s.length - 1)) >= 0) s = s.substr(0, s.length - 1);
    if (s == "") return null;
    var neg = false;
    if (s.charAt(0) == "-") {
      neg = true;
      s = s.substr(1);
    } else if (s.charAt(0) == "+") s = s.substr(1);
    if (StringTools.startsWith(s, "0x") || StringTools.startsWith(s, "0X")) {
      var v = 0.0;
      for (i in 2...s.length) {
        var c = s.charAt(i);
        var d = "0123456789abcdef".indexOf(c.toLowerCase());
        if (d < 0) return null;
        v = v * 16.0 + d;
      }
      return neg ? -v : v;
    }
    var f = Std.parseFloat(s);
    if (Math.isNaN(f)) return null;
    return neg ? -f : f;
  }

  public static function defaultText(t:String):Null<String> {
    if (t == null) return null;
    var s = StringTools.trim(t);
    if (s.length < 2) return null;
    var q = s.charAt(0);
    if ((q == '"' || q == '\'') && s.charAt(s.length - 1) == q) return s.substring(1, s.length - 1);
    return null;
  }

  public static inline function usesStr(sig:String):Bool {
    return sig.indexOf("s") >= 0 || sig.indexOf("S") >= 0 || sig.indexOf("R") >= 0 || sig.indexOf("W") >= 0;
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
      var p = ptrOf(n, info.sig);
      if (p != 0) return JitNative.invoke(p, ctx, 0, 0, 0, 0, 0, 0, 0);
    }
    var f = fn(n);
    return f == 0 ? 0.0 : JitNative.toFloat(f);
  }

  public function callSig(n:String, sig:String, args:Array<Float>, ?strs:Array<String>):Float {
    if (handle == 0) return 0.0;
    var fi = bySig.get(n + "|" + sig);
    var d = fi == null ? dispOf(sig) : dispFor(fi);
    if (d == 0) return 0.0;
    var fp = ptrOf(n, sig);
    if (fp == 0) return 0.0;
    calls++;
    var r = usesStr(sig)
      ? JitNative.callViaB(d, fp, ctx, args.length, a(args, 0), a(args, 1), a(args, 2), a(args, 3), a(args, 4), a(args, 5),
          bytesOf(strs, 0), bytesOf(strs, 1), bytesOf(strs, 2), bytesOf(strs, 3))
      : JitNative.callVia(d, fp, ctx, args.length, a(args, 0), a(args, 1), a(args, 2), a(args, 3), a(args, 4), a(args, 5));
    return guard(r, "callSig", n);
  }

  public function hasSig(sig:String):Bool {
    return handle != 0 && resolve(JitCodegen.dispName(sig)) != 0;
  }

  public function callStr(n:String, args:Array<Float> = null, ?strs:Array<String>):String {
    JitHost.clearRet(id);
    var f = fns.get(n);
    if (f != null && f.ret == "S" && handle != 0) {
      var cached = pre.get("str|" + n + "|" + f.sig);
      var p:cpp.SizeT = cached == null ? resolve("rjit_str_" + JitCodegen.ptrName(n, f.sig)) : JitNative.toSizeT(cached);
      if (cached == null && p != 0) pre.set("str|" + n + "|" + f.sig, JitNative.toFloat(p));
      if (p != 0) {
        var ar = args == null ? [] : args;
        var r = JitNative.invokeB(p, ctx, ar.length, a(ar, 0), a(ar, 1), a(ar, 2), a(ar, 3), a(ar, 4), a(ar, 5),
          bytesOf(strs, 0), bytesOf(strs, 1), bytesOf(strs, 2), bytesOf(strs, 3));
        guard(r, "callStr", n);
        return JitHost.takeRet(id);
      }
    }
    if (f != null && f.ret == "s" && handle != 0) {
      var a = callAuto(n, args == null ? [] : args, strs);
      if (a == a && a != 0) return JitNative.readCStr(JitNative.toSizeT(a));
      return "";
    }
    callAuto(n, args == null ? [] : args, strs);
    return JitHost.takeRet(id);
  }

  var structRing:Array<haxe.io.Bytes> = [];
  var structSlot:Int = 0;

  public function callStruct(n:String, args:Array<Float> = null, ?strs:Array<String>):JitPtr {
    var f = fns.get(n);
    if (f == null || f.ret != "t" || handle == 0) return new JitPtr(0);
    var ar = args == null ? [] : args;
    var k = "ret|" + n + "|" + f.sig;
    var cached = pre.get(k);
    var p:cpp.SizeT = cached == null ? resolve("rjit_ret_" + JitCodegen.ptrName(n, f.sig)) : JitNative.toSizeT(cached);
    if (cached == null && p != 0) pre.set(k, JitNative.toFloat(p));
    if (p == 0) return new JitPtr(0);
    calls++;
    var r = usesStr(f.sig)
      ? JitNative.invokeB(p, ctx, ar.length, a(ar, 0), a(ar, 1), a(ar, 2), a(ar, 3), a(ar, 4), a(ar, 5),
          bytesOf(strs, 0), bytesOf(strs, 1), bytesOf(strs, 2), bytesOf(strs, 3))
      : JitNative.invoke(p, ctx, ar.length, a(ar, 0), a(ar, 1), a(ar, 2), a(ar, 3), a(ar, 4), a(ar, 5));
    var addr = guard(r, "callStruct", n);
    if (addr == 0) return new JitPtr(0);
    var szp = resolve("rjit_szr_" + JitCodegen.ptrName(n, f.sig));
    if (szp == 0) return new JitPtr(addr);
    var sz = Std.int(JitNative.invoke(szp, ctx, 0, 0, 0, 0, 0, 0, 0));
    if (sz <= 0) return new JitPtr(addr);
    var b = haxe.io.Bytes.alloc(sz);
    JitNative.copyOut(JitNative.toSizeT(addr), b, sz);
    if (structRing.length < 8) structRing.push(b) else structRing[structSlot & 7] = b;
    structSlot++;
    return new JitPtr(JitLoader.ptrOf(b), b);
  }

  public function callStrBoth(n:String, args:Array<Float> = null, ?strs:Array<String>):{a:String, b:String} {
    var a = callStr(n, args, strs);
    return {a: a, b: JitHost.takeRet2(id)};
  }

  public function str(path:String):String {
    var p = parsePath(path);
    if (p == null) return "";
    var info = vars.get(p.base);
    if (info == null) return "";
    if (p.segs.length == 0) {
      if (info.kind == "sstr") {
        var fp0 = resolve("rjit_gets_" + p.base);
        if (fp0 == 0) return "";
        JitHost.clearRet(id);
        guard(JitNative.invoke(fp0, ctx, 0, 0, 0, 0, 0, 0, 0), "str", p.base);
        return JitHost.takeRet(id);
      }
      if (info.kind == "ptr" && info.type.indexOf("char") >= 0) {
        var a0 = getVar(p.base);
        return a0 == 0 ? "" : JitNative.readCStr(JitNative.toSizeT(a0));
      }
      return "";
    }
    var fields:Array<String> = [];
    var idx = -1;
    for (q in p.segs) {
      if (q.field) fields.push(q.name);
      else if (idx < 0 && fields.length == 0) idx = q.index;
      else return "";
    }
    if (fields.length == 0) return "";
    if (idx >= 0 && info.kind != "structarray") return "";
    if (idx < 0 && info.kind != "struct") return "";
    var key = p.base + "__" + fields.join("__");
    if (fieldType(info.structName, fields) == "S") {
      var fnp = resolve((idx >= 0 ? "rjit_getstra_" : "rjit_getstr_") + key);
      if (fnp == 0) return "";
      JitHost.clearRet(id);
      var r = idx >= 0
        ? JitNative.invoke(fnp, ctx, 1, idx, 0, 0, 0, 0, 0)
        : JitNative.invoke(fnp, ctx, 0, 0, 0, 0, 0, 0, 0);
      guard(r, "str", key);
      return JitHost.takeRet(id);
    }
    var v = get(path);
    if (v != v || v == 0) return "";
    return JitNative.readCStr(JitNative.toSizeT(v));
  }

  public function setStr(path:String, val:String):Bool {
    var p = parsePath(path);
    if (p == null || val == null) return false;
    var info = vars.get(p.base);
    if (info == null || info.isConst) return false;
    if (p.segs.length == 0) {
      if (info.kind != "sstr") return false;
      var f0 = resolve("rjit_sets_" + p.base);
      if (f0 == 0) return false;
      return JitNative.invokeB(f0, ctx, 0, 0, 0, 0, 0, 0, 0, bytesOf([val], 0), null, null, null) == 0.0;
    }
    var fields:Array<String> = [];
    var idx = -1;
    for (q in p.segs) {
      if (q.field) fields.push(q.name);
      else if (idx < 0 && fields.length == 0) idx = q.index;
      else return false;
    }
    if (fields.length == 0) return false;
    if (idx >= 0 && info.kind != "structarray") return false;
    if (idx < 0 && info.kind != "struct") return false;
    var key = p.base + "__" + fields.join("__");
    if (fieldType(info.structName, fields) != "S") return false;
    var fnp = resolve((idx >= 0 ? "rjit_setstra_" : "rjit_setstr_") + key);
    if (fnp == 0) return false;
    var b = bytesOf([val], 0);
    var r = idx >= 0
      ? JitNative.invokeB(fnp, ctx, 1, idx, 0, 0, 0, 0, 0, b, null, null, null)
      : JitNative.invokeB(fnp, ctx, 0, 0, 0, 0, 0, 0, 0, b, null, null, null);
    return guard(r, "setStr", key) == 0.0;
  }

  function fieldType(sname:String, path:Array<String>):String {
    var cur = sname;
    for (i in 0...path.length) {
      var st = structs.get(cur);
      if (st == null) return "";
      var t = "";
      var nx = "";
      for (f in st.fields) {
        if (f.name != path[i]) continue;
        t = f.type;
        nx = f.nested;
      }
      if (t == "") return "";
      if (i == path.length - 1) return t;
      if (nx == "") return "";
      cur = nx;
    }
    return "";
  }

  public function bind(n:String, ?sig:String):JitFn {
    var f = fns.get(n);
    var s = sig != null ? sig : (f == null ? null : f.sig);
    if (s == null || handle == 0) return new JitFn(this, n, "", 0, 0, 0, false, false);
    var fp = ptrOf(n, s);
    var d = f != null && f.sig == s ? dispFor(f) : resolve(JitCodegen.dispName(s));
    var needsStr = usesStr(s);
    return new JitFn(this, n, s, fp, d, ctx, needsStr, f != null && f.ret == "S");
  }

  public function countCall():Void {
    calls++;
  }

  public function ctxAddress():cpp.SizeT {
    return ctx;
  }

  public function hostId():Int {
    return id;
  }

  public function dispose():Void {
    alive = false;
    Jit.forget(this);
    if (handle != 0) {
      var d = resolve("rjit_deinit");
      if (d != 0) JitNative.callVoid2(d, ctx, 0);
    }
    JitHost.remove(id);
    if (handle == 0) {
      if (ctx != 0) JitNative.freeCtx(ctx);
      ctx = 0;
      return;
    }
    if (pinned) {
      if (ctx != 0) JitNative.freeCtx(ctx);
    } else {
      Jit.retire(handle, image, ctx);
    }
    image = null;
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
