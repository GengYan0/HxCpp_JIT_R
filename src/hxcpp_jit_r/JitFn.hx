package hxcpp_jit_r;

class JitFn {
  public var name(default, null):String;
  public var sig(default, null):String;
  public var returnsString(default, null):Bool;
  var mod:JitModule;
  var fp:cpp.SizeT;
  var disp:cpp.SizeT;
  var ctx:cpp.SizeT;
  var str:Bool;

  public function new(m:JitModule, n:String, s:String, fp:cpp.SizeT, d:cpp.SizeT, c:cpp.SizeT, needsStr:Bool, retStr:Bool) {
    mod = m;
    name = n;
    sig = s;
    this.fp = fp;
    disp = d;
    ctx = c;
    str = needsStr;
    returnsString = retStr;
  }

  public function valid():Bool {
    return fp != 0 && disp != 0 && mod.alive;
  }

  public function call(a0:Float = 0.0, a1:Float = 0.0, a2:Float = 0.0, a3:Float = 0.0, a4:Float = 0.0, a5:Float = 0.0):Float {
    if (fp == 0 || disp == 0 || !mod.alive) return 0.0;
    mod.countCall();
    var r = str
      ? JitNative.callViaB(disp, fp, ctx, 6, a0, a1, a2, a3, a4, a5, null, null, null, null)
      : JitNative.callVia(disp, fp, ctx, 6, a0, a1, a2, a3, a4, a5);
    return mod.guardAt(r, "JitFn.call", name);
  }

  public function callA(args:Array<Float>, ?strs:Array<String>):Float {
    if (fp == 0 || disp == 0 || !mod.alive) return 0.0;
    var ar = args == null ? [] : args;
    var n = ar.length;
    mod.countCall();
    var r = str
      ? JitNative.callViaB(disp, fp, ctx, n, at(ar, 0), at(ar, 1), at(ar, 2), at(ar, 3), at(ar, 4), at(ar, 5),
          bytesOf(strs, 0), bytesOf(strs, 1), bytesOf(strs, 2), bytesOf(strs, 3))
      : JitNative.callVia(disp, fp, ctx, n, at(ar, 0), at(ar, 1), at(ar, 2), at(ar, 3), at(ar, 4), at(ar, 5));
    return mod.guardAt(r, "JitFn.callA", name);
  }

  public function callStr(args:Array<Float> = null, ?strs:Array<String>):String {
    var ar = args == null ? [] : args;
    var id = mod.hostId();
    JitHost.clearRet(id);
    if (returnsString) {
      var p = mod.resolve("rjit_str_" + JitCodegen.ptrName(name, sig));
      if (p != 0) {
        mod.countCall();
        var r = JitNative.invokeB(p, ctx, ar.length, at(ar, 0), at(ar, 1), at(ar, 2), at(ar, 3), at(ar, 4), at(ar, 5),
          bytesOf(strs, 0), bytesOf(strs, 1), bytesOf(strs, 2), bytesOf(strs, 3));
        mod.guardAt(r, "JitFn.callStr", name);
        return JitHost.takeRet(id);
      }
    }
    callA(ar, strs);
    return JitHost.takeRet(id);
  }

  public function address():Float {
    return JitNative.toFloat(fp);
  }

  static inline function at(v:Array<Float>, i:Int):Float {
    return v.length > i ? v[i] : 0.0;
  }

  static function bytesOf(strs:Array<String>, i:Int):haxe.io.Bytes {
    if (strs == null || i >= strs.length) return null;
    var s = strs[i];
    if (s == null) return null;
    return haxe.io.Bytes.ofString(s);
  }
}
