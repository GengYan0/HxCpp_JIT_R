package hxcpp_jit_r;

class JitHost {
  static var mods:Map<Int, JitModule> = new Map();
  static var binds:Map<String, Dynamic> = new Map();
  static var rets:Map<Int, String> = new Map();
  static var vars:Map<String, Float> = new Map();

  public static var logger:String->Void = null;
  public static var onError:Null<(String, String, String) -> Void> = null;
  public static var lastError:String = "";
  public static var capture:Bool = false;
  public static var logs:Array<String> = [];
  public static var logLimit:Int = 512;

  public static function add(m:JitModule):Void {
    mods.set(m.id, m);
  }

  public static function remove(id:Int):Void {
    mods.remove(id);
    rets.remove(id);
  }

  public static function module(id:Int):Null<JitModule> {
    return mods.get(id);
  }

  public static function bind(name:String, f:Dynamic):Void {
    binds.set(name, f);
  }

  public static function unbind(name:String):Void {
    binds.remove(name);
  }

  public static function bindings():Array<String> {
    var out = [];
    for (k in binds.keys()) out.push(k);
    return out;
  }

  public static function setVar(key:String, v:Float):Void {
    vars.set(key, v);
  }

  public static function getVar(key:String):Float {
    var v = vars.get(key);
    return v == null ? 0.0 : v;
  }

  public static function clearRet(id:Int):Void {
    rets.remove(id);
  }

  public static function takeRet(id:Int):String {
    var r = rets.get(id);
    rets.remove(id);
    return r == null ? "" : r;
  }

  public static function error(method:String, name:String, msg:String):Void {
    lastError = msg;
    if (onError != null) onError(method, name, msg) else Sys.println("[jit] " + method + " " + name + ": " + msg);
  }

  public static function onLog(id:Int, s:String):Void {
    if (capture) {
      logs.push(s);
      if (logs.length > logLimit) logs.shift();
    }
    if (logger != null) logger(s) else Sys.println("[jit] " + s);
  }

  public static function onRetStr(id:Int, s:String):Void {
    rets.set(id, s);
  }

  public static function onGet(id:Int, key:String):Float {
    return getVar(key);
  }

  public static function onCall(id:Int, name:String, a0:Float, a1:Float, a2:Float, a3:Float):Float {
    var f = binds.get(name);
    if (f != null) return cast Reflect.callMethod(null, f, [a0, a1, a2, a3]);
    var m = mods.get(id);
    if (m != null && m.has(name)) return m.callA(name, [a0, a1, a2, a3]);
    return 0.0;
  }
}
