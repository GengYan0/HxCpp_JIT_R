package hxcpp_jit_r;

import hxcpp_jit_r.JitCompiler.JitDiag;

class JitSession {
  public var name:String;
  public var source(default, null):String = "";
  public var module(default, null):Null<JitModule> = null;
  public var lastError:String = "";
  public var diag:Array<JitDiag> = [];
  public var evals:Int = 0;

  public function new(?name:String) {
    this.name = name == null ? "session" : name;
  }

  public function eval(code:String):Bool {
    return run(source + code + "\n");
  }

  public function evalFile(path:String):Bool {
    if (!sys.FileSystem.exists(path)) {
      lastError = "no such file: " + path;
      diag = [{file: "jit", line: 0, col: 0, kind: "error", code: "E_NOFILE", msg: path}];
      return false;
    }
    return eval(sys.io.File.getContent(path));
  }

  public function evalNum(code:String):Float {
    return Jit.eval(code);
  }

  public function redeclare(code:String):Bool {
    return run(code + "\n");
  }

  function run(full:String):Bool {
    var keep = snapshot();
    var m = Jit.compile(name, full, {force: true});
    diag = m.diag;
    if (!m.ok) {
      lastError = m.diag.length > 0 ? JitCompiler.describe(m.diag[0]) : "compile failed";
      return false;
    }
    source = full;
    module = m;
    restore(keep);
    evals++;
    lastError = "";
    return true;
  }

  public function snapshot():Map<String, Float> {
    var out = new Map();
    if (module == null) return out;
    for (n in module.varNames()) {
      var k = module.kindOf(n);
      if (k == "num") {
        out.set(n, module.getVar(n));
      } else if (k == "array") {
        var sz = module.arraySize(n);
        for (i in 0...sz) {
          var v = module.getIndex(n, i);
          if (v == v) out.set(n + "[" + i + "]", v);
        }
      } else if (k == "struct") {
        for (f in module.fieldsOf(n)) {
          var v = module.getField(n, f);
          if (v == v) out.set(n + "." + f, v);
        }
      }
    }
    return out;
  }

  public function restore(vals:Map<String, Float>):Void {
    if (module == null) return;
    for (k in vals.keys()) module.set(k, vals.get(k));
  }

  public function call(fn:String, args:Array<Float> = null, ?strs:Array<String>):Float {
    if (module == null) return 0.0;
    return module.callAuto(fn, args == null ? [] : args, strs);
  }

  public function callStr(fn:String, args:Array<Float> = null):String {
    if (module == null) return "";
    return module.callStr(fn, args);
  }

  public function has(fn:String):Bool {
    return module != null && module.has(fn);
  }

  public function address(fn:String):Float {
    return module == null ? 0.0 : module.address(fn);
  }

  public function get(key:String):Float {
    if (module != null) {
      var v = module.get(key);
      if (v == v) return v;
    }
    return JitHost.getVar(key);
  }

  public function set(key:String, v:Float):Bool {
    if (module != null && module.set(key, v)) return true;
    JitHost.setVar(key, v);
    return false;
  }

  public function vars():Array<String> {
    return module == null ? [] : module.varNames();
  }

  public function funcs():Array<String> {
    return module == null ? [] : module.fnNames();
  }

  public function reset():Void {
    source = "";
    evals = 0;
    lastError = "";
    diag = [];
    if (module != null) {
      module.dispose();
      module = null;
    }
  }

  public function dispose():Void {
    if (module != null) {
      module.dispose();
      module = null;
    }
    source = "";
  }

  public function report():String {
    var b = new StringBuf();
    b.add('session "$name"  evals=$evals\n');
    if (module != null) b.add("  " + module.stats() + "\n");
    for (d in diag) b.add("  " + JitCompiler.describe(d) + "\n");
    return b.toString();
  }
}
