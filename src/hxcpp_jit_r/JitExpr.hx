package hxcpp_jit_r;

enum JitValue {
  JNum(f:Float);
  JStr(s:String);
}

class JitExpr {
  public static function looks(s:String):Bool {
    for (i in 0...s.length) {
      var c = s.charAt(i);
      if ("+-*/%()<>!=&|?:^,~".indexOf(c) >= 0) return true;
      if (c == " " || c == "\t") return true;
    }
    return false;
  }

  public static function eval(src:String, resolve:String->Float, ?resolveStr:String->String, ?invoke:String->Array<JitValue>->Null<JitValue>):Float {
    return JitExprParser.num(run(src, resolve, resolveStr, invoke));
  }

  public static function evalStr(src:String, resolve:String->Float, resolveStr:String->String, ?invoke:String->Array<JitValue>->Null<JitValue>):String {
    return JitExprParser.text(run(src, resolve, resolveStr, invoke));
  }

  static function run(src:String, resolve:String->Float, resolveStr:String->String, invoke:String->Array<JitValue>->Null<JitValue>):JitValue {
    var p = new JitExprParser(src, resolve, resolveStr, invoke);
    var v = p.parseExpr();
    p.skip();
    return p.atEnd() ? v : JNum(Math.NaN);
  }
}

class JitExprParser {
  var s:String;
  var i:Int;
  var n:Int;
  var res:String->Float;
  var resStr:String->String;
  var inv:String->Array<JitValue>->Null<JitValue>;

  public function new(src:String, resolve:String->Float, resolveStr:String->String, invoke:String->Array<JitValue>->Null<JitValue>) {
    s = src;
    i = 0;
    n = src.length;
    res = resolve;
    resStr = resolveStr;
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

  public function parseExpr():JitValue {
    return parseTernary();
  }

  function parseTernary():JitValue {
    var c = parseOr();
    skip();
    if (peek() == 63) {
      i++;
      var a = parseExpr();
      skip();
      if (peek() == 58) i++;
      var b = parseExpr();
      return truthy(c) ? a : b;
    }
    return c;
  }

  function parseOr():JitValue {
    var v = parseAnd();
    while (true) {
      skip();
      if (s.substr(i, 2) != "||") break;
      i += 2;
      var r = parseAnd();
      v = JNum((truthy(v) || truthy(r)) ? 1.0 : 0.0);
    }
    return v;
  }

  function parseAnd():JitValue {
    var v = parseBitOr();
    while (true) {
      skip();
      if (s.substr(i, 2) != "&&") break;
      i += 2;
      var r = parseBitOr();
      v = JNum((truthy(v) && truthy(r)) ? 1.0 : 0.0);
    }
    return v;
  }

  function parseBitOr():JitValue {
    var v = parseBitXor();
    while (true) {
      skip();
      var c = peek();
      if (c != 124 || s.substr(i, 2) == "||") break;
      i++;
      v = JNum(intOf(v) | intOf(parseBitXor()));
    }
    return v;
  }

  function parseBitXor():JitValue {
    var v = parseBitAnd();
    while (true) {
      skip();
      if (peek() != 94) break;
      i++;
      v = JNum(intOf(v) ^ intOf(parseBitAnd()));
    }
    return v;
  }

  function parseBitAnd():JitValue {
    var v = parseCmp();
    while (true) {
      skip();
      var c = peek();
      if (c != 38 || s.substr(i, 2) == "&&") break;
      i++;
      v = JNum(intOf(v) & intOf(parseCmp()));
    }
    return v;
  }

  function parseCmp():JitValue {
    var v = parseShift();
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
      var r = parseShift();
      v = JNum(compare(op, v, r) ? 1.0 : 0.0);
    }
    return v;
  }

  function parseShift():JitValue {
    var v = parseAdd();
    while (true) {
      skip();
      if (s.substr(i, 2) == "<<") {
        i += 2;
        v = JNum(intOf(v) << (intOf(parseAdd()) & 31));
      } else if (s.substr(i, 2) == ">>") {
        i += 2;
        v = JNum(intOf(v) >> (intOf(parseAdd()) & 31));
      } else break;
    }
    return v;
  }

  function parseAdd():JitValue {
    var v = parseMul();
    while (true) {
      skip();
      var c = peek();
      if (c == 43) {
        i++;
        v = add(v, parseMul());
      } else if (c == 45) {
        i++;
        v = JNum(num(v) - num(parseMul()));
      } else break;
    }
    return v;
  }

  function parseMul():JitValue {
    var v = parseUnary();
    while (true) {
      skip();
      var c = peek();
      if (c == 42) {
        i++;
        v = JNum(num(v) * num(parseUnary()));
      } else if (c == 47) {
        i++;
        var d = num(parseUnary());
        v = JNum(d == 0 ? Math.NaN : num(v) / d);
      } else if (c == 37) {
        i++;
        var d = num(parseUnary());
        v = JNum(d == 0 ? Math.NaN : num(v) - Math.floor(num(v) / d) * d);
      } else break;
    }
    return v;
  }

  function parseUnary():JitValue {
    skip();
    var c = peek();
    if (c == 45) {
      i++;
      return JNum(-num(parseUnary()));
    }
    if (c == 43) {
      i++;
      return parseUnary();
    }
    if (c == 33) {
      i++;
      return JNum(truthy(parseUnary()) ? 0.0 : 1.0);
    }
    if (c == 126) {
      i++;
      return JNum(~intOf(parseUnary()));
    }
    return parseAtom();
  }

  function parseAtom():JitValue {
    skip();
    var c = peek();
    if (c == 40) {
      i++;
      var v = parseExpr();
      skip();
      if (peek() == 41) i++;
      return v;
    }
    if (c == 34 || c == 39) return JStr(parseString());
    if (c >= 48 && c <= 57) return JNum(parseNumber());
    if (c == 46) return JNum(parseNumber());
    if (isNameStart(c)) return parseName();
    return JNum(Math.NaN);
  }

  function parseString():String {
    var q = peek();
    i++;
    var b = new StringBuf();
    while (i < n) {
      var c = s.charCodeAt(i);
      if (c == 92 && i + 1 < n) {
        var e = s.charAt(i + 1);
        i += 2;
        if (e == "n") b.add("\n");
        else if (e == "t") b.add("\t");
        else b.add(e);
        continue;
      }
      if (c == q) {
        i++;
        break;
      }
      b.addChar(c);
      i++;
    }
    return b.toString();
  }

  function parseNumber():Float {
    var s0 = i;
    while (i < n) {
      var c = s.charCodeAt(i);
      if ((c >= 48 && c <= 57) || c == 46) i++;
      else break;
    }
    if (i < n) {
      var e = s.charCodeAt(i);
      if (e == 101 || e == 69) {
        var k = i + 1;
        if (k < n && (s.charCodeAt(k) == 43 || s.charCodeAt(k) == 45)) k++;
        if (k < n && s.charCodeAt(k) >= 48 && s.charCodeAt(k) <= 57) {
          i = k;
          while (i < n && s.charCodeAt(i) >= 48 && s.charCodeAt(i) <= 57) i++;
        }
      }
    }
    return Std.parseFloat(s.substring(s0, i));
  }

  function parseName():JitValue {
    var s0 = i;
    while (i < n && isNameChar(s.charCodeAt(i))) i++;
    var name = s.substring(s0, i);
    skip();
    if (peek() == 40) {
      i++;
      var args:Array<JitValue> = [];
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
    if (name == "pi") return JNum(Math.PI);
    if (name == "e") return JNum(2.718281828459045);
    if (resStr != null) {
      var t = resStr(name);
      if (t != null) return JStr(t);
    }
    var v = res(name);
    if (v == v) return JNum(v);
    return JNum(Math.NaN);
  }

  function callFn(name:String, a:Array<JitValue>):JitValue {
    if (inv != null) {
      var r = inv(name, a);
      if (r != null) return r;
    }
    if (name == "strlen") return switch (a[0]) { case JStr(t): JNum(t.length * 1.0); default: JNum(Math.NaN); };
    if (name == "str") return JStr(text(a[0]));
    if (name == "upper") return switch (a[0]) { case JStr(t): JStr(t.toUpperCase()); default: JNum(Math.NaN); };
    if (name == "lower") return switch (a[0]) { case JStr(t): JStr(t.toLowerCase()); default: JNum(Math.NaN); };
    if (name == "contains") return switch ([a[0], a[1]]) {
      case [JStr(x), JStr(y)]: JNum(x.indexOf(y) >= 0 ? 1.0 : 0.0);
      default: JNum(Math.NaN);
    };
    for (v in a) if (num(v) != num(v)) return JNum(Math.NaN);
    return JNum(switch (name) {
      case "abs": Math.abs(num(a[0]));
      case "sqrt": Math.sqrt(num(a[0]));
      case "floor": Math.floor(num(a[0]));
      case "ceil": Math.ceil(num(a[0]));
      case "round": Math.round(num(a[0]));
      case "trunc": num(a[0]) < 0 ? Math.ceil(num(a[0])) : Math.floor(num(a[0]));
      case "sign": num(a[0]) > 0 ? 1.0 : (num(a[0]) < 0 ? -1.0 : 0.0);
      case "min": Math.min(num(a[0]), num(a[1]));
      case "max": Math.max(num(a[0]), num(a[1]));
      case "pow": Math.pow(num(a[0]), num(a[1]));
      case "sin": Math.sin(num(a[0]));
      case "cos": Math.cos(num(a[0]));
      case "tan": Math.tan(num(a[0]));
      case "asin": Math.asin(num(a[0]));
      case "acos": Math.acos(num(a[0]));
      case "atan": Math.atan(num(a[0]));
      case "atan2": Math.atan2(num(a[0]), num(a[1]));
      case "exp": Math.exp(num(a[0]));
      case "log": Math.log(num(a[0]));
      case "log2": Math.log(num(a[0])) / 0.6931471805599453;
      case "log10": Math.log(num(a[0])) / 2.302585092994046;
      case "hypot": Math.sqrt(num(a[0]) * num(a[0]) + num(a[1]) * num(a[1]));
      case "mod": num(a[1]) == 0 ? Math.NaN : num(a[0]) - Math.floor(num(a[0]) / num(a[1])) * num(a[1]);
      case "clamp": num(a[0]) < num(a[1]) ? num(a[1]) : (num(a[0]) > num(a[2]) ? num(a[2]) : num(a[0]));
      case "lerp": num(a[0]) + (num(a[1]) - num(a[0])) * num(a[2]);
      case "deg": num(a[0]) * 180.0 / Math.PI;
      case "rad": num(a[0]) * Math.PI / 180.0;
      default: Math.NaN;
    });
  }

  public static function num(v:JitValue):Float {
    return switch (v) {
      case JNum(f): f;
      case JStr(_): Math.NaN;
    };
  }

  public static function text(v:JitValue):String {
    return switch (v) {
      case JStr(s): s;
      case JNum(f): f != f ? "" : Std.string(f);
    };
  }

  static function intOf(v:JitValue):Int {
    var f = num(v);
    return f != f ? 0 : Std.int(f);
  }

  static function truthy(v:JitValue):Bool {
    return switch (v) {
      case JStr(s): s.length > 0;
      case JNum(f): f != 0 && f == f;
    };
  }

  static function add(a:JitValue, b:JitValue):JitValue {
    return switch ([a, b]) {
      case [JNum(x), JNum(y)]: JNum(x + y);
      default: JStr(text(a) + text(b));
    };
  }

  static function compare(op:String, a:JitValue, b:JitValue):Bool {
    switch ([a, b]) {
      case [JStr(x), JStr(y)]:
        return switch (op) {
          case "==": x == y;
          case "!=": x != y;
          case "<": x < y;
          case "<=": x <= y;
          case ">": x > y;
          default: x >= y;
        };
      case [JNum(_), JNum(_)]:
        var x = num(a);
        var y = num(b);
        return switch (op) {
          case "<": x < y;
          case "<=": x <= y;
          case ">": x > y;
          case ">=": x >= y;
          case "==": x == y;
          default: x != y;
        };
      default:
        return op == "!=";
    }
  }

  static inline function isNameStart(c:Int):Bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
  }

  static inline function isNameChar(c:Int):Bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 46 || c == 91 || c == 93;
  }
}
