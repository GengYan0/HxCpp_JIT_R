package hxcpp_jit_r;

class JitExpr {
  public static function looks(s:String):Bool {
    for (i in 0...s.length) {
      var c = s.charAt(i);
      if ("+-*/%()<>!=&|?:^,".indexOf(c) >= 0) return true;
      if (c == " " || c == "\t") return true;
    }
    return false;
  }

  public static function eval(src:String, resolve:String->Float, ?invoke:String->Array<Float>->Float):Float {
    var p = new JitExprParser(src, resolve, invoke);
    var v = p.parseExpr();
    p.skip();
    if (!p.atEnd()) return Math.NaN;
    return v;
  }
}

class JitExprParser {
  var s:String;
  var i:Int;
  var n:Int;
  var res:String->Float;
  var inv:String->Array<Float>->Float;

  public function new(src:String, resolve:String->Float, ?invoke:String->Array<Float>->Float) {
    s = src;
    i = 0;
    n = src.length;
    res = resolve;
    inv = invoke;
  }

  public function atEnd():Bool {
    return i >= n;
  }

  public function skip():Void {
    while (i < n) {
      var c = s.charCodeAt(i);
      if (c == 32 || c == 9 || c == 10 || c == 13) i++;
      else break;
    }
  }

  inline function peek():Int {
    return i < n ? s.charCodeAt(i) : -1;
  }

  public function parseExpr():Float {
    return parseTernary();
  }

  function parseTernary():Float {
    var c = parseOr();
    skip();
    if (peek() == 63) {
      i++;
      var a = parseExpr();
      skip();
      if (peek() == 58) i++;
      var b = parseExpr();
      return c != 0 ? a : b;
    }
    return c;
  }

  function parseOr():Float {
    var v = parseAnd();
    while (true) {
      skip();
      if (s.substr(i, 2) != "||") break;
      i += 2;
      var r = parseAnd();
      v = (v != 0 || r != 0) ? 1.0 : 0.0;
    }
    return v;
  }

  function parseAnd():Float {
    var v = parseCmp();
    while (true) {
      skip();
      if (s.substr(i, 2) != "&&") break;
      i += 2;
      var r = parseCmp();
      v = (v != 0 && r != 0) ? 1.0 : 0.0;
    }
    return v;
  }

  function parseCmp():Float {
    var v = parseAdd();
    while (true) {
      skip();
      var op:String = null;
      if (s.substr(i, 2) == "<=") op = "<=";
      else if (s.substr(i, 2) == ">=") op = ">=";
      else if (s.substr(i, 2) == "==") op = "==";
      else if (s.substr(i, 2) == "!=") op = "!=";
      else if (peek() == 60) op = "<";
      else if (peek() == 62) op = ">";
      if (op == null) break;
      i += op.length;
      var r = parseAdd();
      v = switch (op) {
        case "<": v < r ? 1.0 : 0.0;
        case "<=": v <= r ? 1.0 : 0.0;
        case ">": v > r ? 1.0 : 0.0;
        case ">=": v >= r ? 1.0 : 0.0;
        case "==": v == r ? 1.0 : 0.0;
        default: v != r ? 1.0 : 0.0;
      };
    }
    return v;
  }

  function parseAdd():Float {
    var v = parseMul();
    while (true) {
      skip();
      var c = peek();
      if (c == 43) {
        i++;
        v += parseMul();
      } else if (c == 45) {
        i++;
        v -= parseMul();
      } else break;
    }
    return v;
  }

  function parseMul():Float {
    var v = parseUnary();
    while (true) {
      skip();
      var c = peek();
      if (c == 42) {
        i++;
        v *= parseUnary();
      } else if (c == 47) {
        i++;
        var d = parseUnary();
        v = d == 0 ? Math.NaN : v / d;
      } else if (c == 37) {
        i++;
        var d = parseUnary();
        v = d == 0 ? Math.NaN : v - Math.floor(v / d) * d;
      } else break;
    }
    return v;
  }

  function parseUnary():Float {
    skip();
    var c = peek();
    if (c == 45) {
      i++;
      return -parseUnary();
    }
    if (c == 43) {
      i++;
      return parseUnary();
    }
    if (c == 33) {
      i++;
      var v = parseUnary();
      return v == 0 ? 1.0 : 0.0;
    }
    return parsePower();
  }

  function parsePower():Float {
    var v = parseAtom();
    skip();
    if (peek() == 94) {
      i++;
      return Math.pow(v, parseUnary());
    }
    return v;
  }

  function parseAtom():Float {
    skip();
    var c = peek();
    if (c == 40) {
      i++;
      var v = parseExpr();
      skip();
      if (peek() == 41) i++;
      return v;
    }
    if (c >= 48 && c <= 57) return parseNumber();
    if (c == 46) return parseNumber();
    if (isNameStart(c)) return parseName();
    return Math.NaN;
  }

  function parseNumber():Float {
    var s0 = i;
    while (i < n) {
      var c = s.charCodeAt(i);
      if ((c >= 48 && c <= 57) || c == 46) i++;
      else break;
    }
    var e = s.charCodeAt(i < n ? i : n - 1);
    if (i < n && (e == 101 || e == 69)) {
      var k = i + 1;
      if (k < n && (s.charCodeAt(k) == 43 || s.charCodeAt(k) == 45)) k++;
      if (k < n && s.charCodeAt(k) >= 48 && s.charCodeAt(k) <= 57) {
        i = k;
        while (i < n && s.charCodeAt(i) >= 48 && s.charCodeAt(i) <= 57) i++;
      }
    }
    return Std.parseFloat(s.substring(s0, i));
  }

  function parseName():Float {
    var s0 = i;
    while (i < n && isNameChar(s.charCodeAt(i))) i++;
    var name = s.substring(s0, i);
    skip();
    if (peek() == 40) {
      i++;
      var args:Array<Float> = [];
      skip();
      if (peek() == 41) {
        i++;
      } else {
        while (true) {
          args.push(parseExpr());
          skip();
          if (peek() == 44) {
            i++;
            continue;
          }
          if (peek() == 41) i++;
          break;
        }
      }
      return callFn(name, args);
    }
    if (name == "pi") return Math.PI;
    if (name == "e") return 2.718281828459045;
    var path = name;
    while (true) {
      var c2 = peek();
      if (c2 == 46) {
        i++;
        var q = i;
        while (i < n && isNameChar(s.charCodeAt(i))) i++;
        if (i == q) break;
        path += "." + s.substring(q, i);
      } else if (c2 == 91) {
        var rb = s.indexOf("]", i);
        if (rb < 0) break;
        path += s.substring(i, rb + 1);
        i = rb + 1;
      } else break;
    }
    return res(path);
  }

  function callFn(name:String, a:Array<Float>):Float {
    if (inv != null) {
      var r = inv(name, a);
      if (r == r) return r;
    }
    for (v in a) if (v != v) return Math.NaN;
    return switch (name) {
      case "abs": Math.abs(a[0]);
      case "sqrt": Math.sqrt(a[0]);
      case "floor": Math.floor(a[0]);
      case "ceil": Math.ceil(a[0]);
      case "round": Math.round(a[0]);
      case "trunc": a[0] < 0 ? Math.ceil(a[0]) : Math.floor(a[0]);
      case "sign": a[0] > 0 ? 1.0 : (a[0] < 0 ? -1.0 : 0.0);
      case "min": Math.min(a[0], a[1]);
      case "max": Math.max(a[0], a[1]);
      case "pow": Math.pow(a[0], a[1]);
      case "sin": Math.sin(a[0]);
      case "cos": Math.cos(a[0]);
      case "tan": Math.tan(a[0]);
      case "asin": Math.asin(a[0]);
      case "acos": Math.acos(a[0]);
      case "atan": Math.atan(a[0]);
      case "atan2": Math.atan2(a[0], a[1]);
      case "exp": Math.exp(a[0]);
      case "log": Math.log(a[0]);
      case "log2": Math.log(a[0]) / 0.6931471805599453;
      case "log10": Math.log(a[0]) / 2.302585092994046;
      case "hypot": Math.sqrt(a[0] * a[0] + a[1] * a[1]);
      case "mod": a[1] == 0 ? Math.NaN : a[0] - Math.floor(a[0] / a[1]) * a[1];
      case "clamp": a[0] < a[1] ? a[1] : (a[0] > a[2] ? a[2] : a[0]);
      case "lerp": a[0] + (a[1] - a[0]) * a[2];
      case "deg": a[0] * 180.0 / Math.PI;
      case "rad": a[0] * Math.PI / 180.0;
      default: Math.NaN;
    };
  }

  static inline function isNameStart(c:Int):Bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
  }

  static inline function isNameChar(c:Int):Bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95;
  }
}
