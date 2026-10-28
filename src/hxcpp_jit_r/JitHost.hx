package hxcpp_jit_r;

class JitHost {
  static var lock = new sys.thread.Mutex();
  static var mods:Map<Int, JitModule> = new Map();
  static var binds:Map<String, Dynamic> = new Map();
  static var rets:Map<Int, String> = new Map();
  static var ret2:Map<Int, String> = new Map();
  static var vars:Map<String, Float> = new Map();

  public static var logger:String->Void = null;
  public static var onError:Null<(String, String, String) -> Void> = null;
  public static var lastError:String = "";
  public static var capture:Bool = false;
  public static var logs:Array<String> = [];
  public static var logLimit:Int = 512;

  static function sync<T>(f:Void->T):T {
    lock.acquire();
    var r:T = null;
    try {
      r = f();
    } catch (e:Dynamic) {
      lock.release();
      throw e;
    }
    lock.release();
    return r;
  }

  public static function add(m:JitModule):Void {
    sync(function() { mods.set(m.id, m); return true; });
  }

  public static function remove(id:Int):Void {
    sync(function() {
      mods.remove(id);
      rets.remove(id);
      ret2.remove(id);
      return true;
    });
  }

  public static function module(id:Int):Null<JitModule> {
    return sync(function() return mods.get(id));
  }

  public static function bind(name:String, f:Dynamic):Void {
    sync(function() { binds.set(name, f); return true; });
  }

  public static function unbind(name:String):Void {
    sync(function() { binds.remove(name); return true; });
  }

  public static function bindings():Array<String> {
    return sync(function() {
      var out = [];
      for (k in binds.keys()) out.push(k);
      return out;
    });
  }

  public static function setVar(key:String, v:Float):Void {
    sync(function() { vars.set(key, v); return true; });
  }

  public static function getVar(key:String):Float {
    var v = sync(function() return vars.get(key));
    return v == null ? 0.0 : v;
  }

  public static function clearRet(id:Int):Void {
    sync(function() {
      rets.remove(id);
      ret2.remove(id);
      return true;
    });
  }

  public static function takeRet(id:Int):String {
    return sync(function() {
      var r = rets.get(id);
      rets.remove(id);
      return r == null ? "" : r;
    });
  }

  public static function error(method:String, name:String, msg:String):Void {
    lastError = msg;
    if (onError != null) onError(method, name, msg) else Sys.println("[jit] " + method + " " + name + ": " + msg);
  }

  public static function onLog(id:Int, s:String):Void {
    if (capture) sync(function() {
      logs.push(s);
      if (logs.length > logLimit) logs.shift();
      return true;
    });
    if (logger != null) logger(s) else Sys.println("[jit] " + s);
  }

  public static function onRetStr(id:Int, s:String):Void {
    sync(function() { rets.set(id, s); return true; });
  }

  public static function onRetStr2(id:Int, s:String):Void {
    sync(function() { ret2.set(id, s); return true; });
  }

  public static function takeRet2(id:Int):String {
    return sync(function() {
      var r = ret2.get(id);
      ret2.remove(id);
      return r == null ? "" : r;
    });
  }

  public static function onGet(id:Int, key:String):Float {
    return getVar(key);
  }

  public static function onCallStr(id:Int, name:String, a0:Float, a1:Float, a2:Float, a3:Float):String {
    var f = sync(function() return binds.get(name));
    if (f != null) return Std.string(Reflect.callMethod(null, f, [a0, a1, a2, a3]));
    return "";
  }

  public static function onCall(id:Int, name:String, a0:Float, a1:Float, a2:Float, a3:Float):Float {
    var f = sync(function() return binds.get(name));
    if (f != null) return cast Reflect.callMethod(null, f, [a0, a1, a2, a3]);
    var m = sync(function() return mods.get(id));
    if (m != null && m.has(name)) return m.callA(name, [a0, a1, a2, a3]);
    return 0.0;
  }
}
