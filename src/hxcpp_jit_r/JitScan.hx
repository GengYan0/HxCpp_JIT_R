package hxcpp_jit_r;

typedef JitFnInfo = {
  var name:String;
  var ret:String;
  var args:Array<String>;
  var sig:String;
  var callable:Bool;
  var rawRet:String;
  var rawArgs:Array<String>;
  var defaults:Array<String>;
  var isStatic:Bool;
}

typedef JitArgText = {
  var type:String;
  var def:String;
}

typedef JitVarInfo = {
  var name:String;
  var type:String;
  var isConst:Bool;
  var isStatic:Bool;
  var kind:String;
  var elem:String;
  var size:Int;
  var structName:String;
}

typedef JitFieldInfo = {
  var name:String;
  var type:String;
  var raw:String;
  var nested:String;
  var size:Int;
}

typedef JitStructInfo = {
  var name:String;
  var fields:Array<JitFieldInfo>;
}

class JitScan {
  static function keywords():Array<String> {
    return [
    "if", "for", "while", "switch", "return", "else", "do", "case", "sizeof", "new", "delete",
    "struct", "class", "union", "enum", "namespace", "using", "typedef", "template", "operator",
      "catch", "try", "throw", "static_assert", "decltype", "alignof"
    ];
  }

  static function numerics():Array<String> {
    return [
    "int", "unsigned", "long", "short", "char", "bool", "float", "double", "size_t",
    "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
      "intptr_t", "uintptr_t", "ptrdiff_t", "unsigned long", "signed int", "unsigned int",
      "long long", "unsigned long long", "long int", "unsigned long int", "signed char",
      "unsigned char", "short int", "unsigned short", "signed long", "signed long long"
    ];
  }

  public static function strip(src:String):String {
    var b = new StringBuf();
    var i = 0;
    var n = src.length;
    var inLine = false;
    var inBlock = false;
    var inStr = 0;
    while (i < n) {
      var c = src.charCodeAt(i);
      var d = i + 1 < n ? src.charCodeAt(i + 1) : 0;
      if (inLine) {
        if (c == 10) {
          inLine = false;
          b.addChar(c);
        }
        i++;
        continue;
      }
      if (inBlock) {
        if (c == 42 && d == 47) {
          inBlock = false;
          i += 2;
          continue;
        }
        if (c == 10) b.addChar(c);
        i++;
        continue;
      }
      if (inStr > 0) {
        b.addChar(c);
        if (c == 92) {
          if (i + 1 < n) b.addChar(src.charCodeAt(i + 1));
          i += 2;
          continue;
        }
        if (c == inStr) inStr = 0;
        i++;
        continue;
      }
      if (c == 47 && d == 47) {
        inLine = true;
        i += 2;
        continue;
      }
      if (c == 47 && d == 42) {
        inBlock = true;
        i += 2;
        continue;
      }
      if (c == 82 && d == 34) {
        var lp = i + 2;
        var lim = i + 18 < n ? i + 18 : n;
        while (lp < lim && src.charCodeAt(lp) != 40) lp++;
        if (lp < lim && src.charCodeAt(lp) == 40) {
          var close = ")" + src.substring(i + 2, lp) + '"';
          var e = src.indexOf(close, lp + 1);
          var stop = e < 0 ? n : e + close.length;
          var k = i;
          while (k < stop) {
            b.addChar(src.charCodeAt(k));
            k++;
          }
          i = stop;
          continue;
        }
      }
      if (c == 34) {
        inStr = c;
        b.addChar(c);
        i++;
        continue;
      }
      if (c == 39) {
        var close = i + 2;
        if (close < n && d == 92) close = i + 3;
        if (close < n && src.charCodeAt(close) == 39) {
          var k = i;
          while (k <= close) {
            b.addChar(src.charCodeAt(k));
            k++;
          }
          i = close + 1;
          continue;
        }
        b.addChar(c);
        i++;
        continue;
      }
      b.addChar(c);
      i++;
    }
    return b.toString();
  }

  public static function structs(src:String):Array<JitStructInfo> {
    var clean = strip(src);
    var defs:Array<{name:String, body:String}> = [];
    var i = 0;
    var n = clean.length;
    while (i < n) {
      var p = clean.indexOf("struct", i);
      if (p < 0) break;
      i = p + 6;
      if (p > 0 && isIdentChar(clean.charCodeAt(p - 1))) continue;
      if (i < n && isIdentChar(clean.charCodeAt(i))) continue;
      var q = skipSpace(clean, i);
      var n0 = q;
      while (q < n && isIdentChar(clean.charCodeAt(q))) q++;
      if (q == n0) continue;
      var nm = clean.substring(n0, q);
      var b = clean.indexOf("{", q);
      if (b < 0) break;
      var between = clean.substring(q, b);
      if (between.indexOf(";") >= 0) continue;
      var depth = 1;
      var e = b + 1;
      while (e < n && depth > 0) {
        var c = clean.charCodeAt(e);
        if (c == 123) depth++;
        else if (c == 125) depth--;
        e++;
      }
      if (depth != 0) break;
      defs.push({name: nm, body: clean.substring(b + 1, e - 1)});
      i = e;
    }
    var known = new Map<String, Bool>();
    for (d in defs) known.set(d.name, true);
    var out:Array<JitStructInfo> = [];
    for (d in defs) {
      var fields:Array<JitFieldInfo> = [];
      for (seg in d.body.split(";")) {
        var t = StringTools.trim(seg);
        if (t == "") continue;
        if (t.indexOf("(") >= 0) continue;
        if (t.indexOf("{") >= 0) continue;
        var sp = lastSpace(t);
        if (sp < 0) continue;
        var ty = StringTools.trim(t.substr(0, sp));
        var fn = StringTools.trim(t.substr(sp + 1));
        var asize = 0;
        var lb = fn.indexOf("[");
        if (lb > 0) {
          var rb = fn.indexOf("]", lb);
          if (rb < 0) continue;
          var asz = Std.parseInt(StringTools.trim(fn.substring(lb + 1, rb)));
          if (asz == null || asz <= 0) continue;
          asize = asz;
          fn = StringTools.trim(fn.substr(0, lb));
        }
        if (!isIdent(fn)) continue;
        var c = code(ty);
        var tq = StringTools.trim(ty);
        if (c == "?" && known.exists(tq) && tq != d.name) {
          if (asize > 0) continue;
          fields.push({name: fn, type: "struct", raw: ty, nested: tq, size: 0});
          continue;
        }
        if (c == "?" || c == "v" || c == "R") continue;
        fields.push({name: fn, type: c, raw: ty, nested: "", size: asize});
      }
      if (fields.length > 0) out.push({name: d.name, fields: fields});
    }
    return out;
  }

  static function scopeBlocked(lines:Array<String>):Array<Bool> {
    var out:Array<Bool> = [];
    var stack:Array<Bool> = [];
    for (line in lines) {
      var bad = false;
      for (v in stack) if (v) {
        bad = true;
        break;
      }
      out.push(bad);
      var segStart = 0;
      for (j in 0...line.length) {
        var ch = line.charCodeAt(j);
        if (ch == 123) {
          stack.push(!transparentScope(StringTools.trim(line.substring(segStart, j))));
          segStart = j + 1;
        } else if (ch == 125) {
          if (stack.length > 0) stack.pop();
          segStart = j + 1;
        } else if (ch == 59) segStart = j + 1;
      }
    }
    return out;
  }

  static function transparentScope(pre:String):Bool {
    if (pre == "") return false;
    if (StringTools.startsWith(pre, "namespace")) return true;
    if (StringTools.startsWith(pre, "extern")) return true;
    return false;
  }

  static function braceOnNextLine(lines:Array<String>, li:Int):Bool {
    var k = li + 1;
    while (k < lines.length) {
      var t = StringTools.trim(lines[k]);
      if (t == "") {
        k++;
        continue;
      }
      return t.charAt(0) == "{";
    }
    return false;
  }

  public static function functions(src:String, structs:Array<JitStructInfo> = null):Array<JitFnInfo> {
    var clean = strip(src);
    var kw = keywords();
    var nums = numerics();
    var sts = new Map<String, Bool>();
    if (structs != null) for (st in structs) sts.set(st.name, true);
    var ens = enumNames(clean);
    var out:Array<JitFnInfo> = [];
    var lines = clean.split("\n");
    var blocked = scopeBlocked(lines);
    for (li in 0...lines.length) {
      if (blocked[li]) continue;
      var s = StringTools.trim(lines[li]);
      if (s == "" || s.charAt(0) == "#") continue;
      if (s.indexOf("(") < 0 || s.indexOf(")") < 0) continue;
      if (s.indexOf("{") < 0 && !braceOnNextLine(lines, li)) continue;
      var p = s.indexOf("(");
      var q = p + 1;
      var dep = 1;
      while (q < s.length && dep > 0) {
        var ch = s.charCodeAt(q);
        if (ch == 40) dep++;
        else if (ch == 41) dep--;
        q++;
      }
      if (dep != 0) continue;
      q--;
      var before = StringTools.trim(s.substr(0, p));
      if (before == "" || before.indexOf("=") >= 0 || before.indexOf(".") >= 0) continue;
      var sp = lastSpace(before);
      if (sp < 0) continue;
      var ret = StringTools.trim(before.substr(0, sp));
      var name = StringTools.trim(before.substr(sp + 1));
      if (!isIdent(name)) continue;
      if (kw.indexOf(name) >= 0) continue;
      if (name.indexOf("::") >= 0) continue;
      if (kw.indexOf(ret) >= 0) continue;
      if (ret.indexOf("(") >= 0) continue;
      var params = s.substr(p + 1, q - p - 1);
      var rawArgs:Array<String> = [];
      var defaults:Array<String> = [];
      var argTexts = splitArgs(params);
      for (a in argTexts) {
        rawArgs.push(a.type);
        defaults.push(a.def);
      }
      var args:Array<String> = [];
      var ok = true;
      var strArgs = 0;
      var writeBack = 0;
      for (t in rawArgs) {
        var c = code(t);
        if (c == "R" && t.indexOf("const") < 0) c = "W";
        if (c == "?") {
          var bare = valueType(t);
          if (sts.exists(bare)) c = "t";
          else if (ens.exists(bare)) c = "i";
          else if (StringTools.endsWith(StringTools.trim(t), "&") && isNumeric(bare, nums)) c = "r";
        }
        if (c == "?") {
          ok = false;
          break;
        }
        if (c == "s" || c == "S") strArgs++;
        if (c == "W") writeBack++;
        args.push(c);
      }
      if (args.length > 6) ok = false;
      if (args.length - strArgs > 6) ok = false;
      if (strArgs > 4) ok = false;
      if (writeBack > 2) ok = false;
      for (d in defaults) if (!isDefaultLiteral(d)) ok = false;
      var rc = code(ret);
      if (rc == "v" && !isVoid(ret)) ok = false;
      if (rc == "?" && sts.exists(valueType(ret))) rc = "t";
      if (rc == "?" && ens.exists(valueType(ret))) rc = "i";
      if (rc == "?") ok = false;
      if (rc == "R") ok = false;
      var sig = rc + "(" + args.join("") + ")";
      var local = ret.indexOf("static") >= 0 || ret.indexOf("inline") >= 0;
      out.push({name: name, ret: rc, args: args, sig: sig, callable: ok, rawRet: ret, rawArgs: rawArgs, defaults: defaults, isStatic: local});
    }
    return out;
  }

  public static function globals(src:String):Array<JitVarInfo> {
    var clean = maskStructs(strip(src));
    var nums = numerics();
    var sts = new Map<String, JitStructInfo>();
    for (s in structs(src)) sts.set(s.name, s);
    var out:Array<JitVarInfo> = [];
    var seen = new Map<String, Bool>();
    var lines = clean.split("\n");
    var blocked = scopeBlocked(lines);
    for (li in 0...lines.length) {
      if (blocked[li]) continue;
      var raw = lines[li];
      if (raw.length == 0) continue;
      var s = StringTools.trim(raw);
      if (s == "" || s.charAt(0) == "#") continue;
      if (s.indexOf("(") >= 0) continue;
      var semi = s.lastIndexOf(";");
      if (semi < 0) continue;
      for (seg in s.substr(0, semi).split(";")) {
        var decl = StringTools.trim(seg);
        if (decl == "") continue;
        var eq = decl.indexOf("=");
        if (eq >= 0) decl = StringTools.trim(decl.substr(0, eq));
        if (decl.indexOf("{") >= 0 || decl.indexOf("}") >= 0) continue;
        var isConst = decl.indexOf("const") >= 0;
        var isStatic = decl.indexOf("static") >= 0 || decl.indexOf("extern") >= 0;
        decl = trimQualifiers(decl);
        var sp = lastSpace(decl);
        if (sp < 0) continue;
        var type = StringTools.trim(decl.substr(0, sp));
        var name = StringTools.trim(decl.substr(sp + 1));
        var kind = "num";
        var elem = "";
        var size = 0;
        var structName = "";
        var lb = name.indexOf("[");
        if (lb > 0) {
          var rb = name.indexOf("]", lb);
          if (rb < 0) continue;
          var sz = Std.parseInt(StringTools.trim(name.substring(lb + 1, rb)));
          name = StringTools.trim(name.substr(0, lb));
          if (!isIdent(name)) continue;
          if (sz == null || sz <= 0) continue;
          var c = code(type);
          if (c == "?") {
            var st = sts.get(StringTools.trim(type));
            if (st == null) continue;
            kind = "structarray";
            structName = st.name;
            size = sz;
          } else {
            if (c == "v" || c == "?" || c == "S" || c == "R" || c == "W") continue;
            kind = "array";
            elem = c;
            size = sz;
          }
        } else {
          if (!isIdent(name)) continue;
          if (isNumeric(type, nums)) {
            kind = "num";
          } else if (isPointerType(type)) {
            kind = "ptr";
          } else if (code(type) == "S") {
            kind = "sstr";
          } else {
            var st = sts.get(StringTools.trim(type));
            if (st == null) continue;
            kind = "struct";
            structName = st.name;
          }
        }
        if (seen.exists(name)) continue;
        seen.set(name, true);
        out.push({name: name, type: type, isConst: isConst, isStatic: isStatic, kind: kind, elem: elem, size: size, structName: structName});
      }
    }
    return out;
  }

  static function maskStructs(clean:String):String {
    var b = new StringBuf();
    var i = 0;
    var n = clean.length;
    var last = 0;
    while (i < n) {
      var p = clean.indexOf("struct", i);
      if (p < 0) break;
      i = p + 6;
      if (p > 0 && isIdentChar(clean.charCodeAt(p - 1))) continue;
      if (i < n && isIdentChar(clean.charCodeAt(i))) continue;
      var q = skipSpace(clean, i);
      var n0 = q;
      while (q < n && isIdentChar(clean.charCodeAt(q))) q++;
      if (q == n0) continue;
      var br = clean.indexOf("{", q);
      if (br < 0) break;
      if (clean.substring(q, br).indexOf(";") >= 0) continue;
      var depth = 1;
      var e = br + 1;
      while (e < n && depth > 0) {
        var c = clean.charCodeAt(e);
        if (c == 123) depth++;
        else if (c == 125) depth--;
        e++;
      }
      if (depth != 0) break;
      b.add(clean.substring(last, p));
      var k = p;
      while (k < e) {
        b.addChar(clean.charCodeAt(k) == 10 ? 10 : 32);
        k++;
      }
      last = e;
      i = e;
    }
    b.add(clean.substr(last));
    return b.toString();
  }

  static function skipSpace(s:String, i:Int):Int {
    var q = i;
    while (q < s.length) {
      var c = s.charCodeAt(q);
      if (c != 32 && c != 9 && c != 10 && c != 13) break;
      q++;
    }
    return q;
  }

  static function isIdentChar(c:Int):Bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95;
  }

  static function trimQualifiers(s:String):String {
    var out = s;
    for (q in ["static", "const", "volatile", "constexpr", "register", "extern"]) {
      while (true) {
        var t = StringTools.trim(out);
        if (!StringTools.startsWith(t, q + " ")) break;
        out = t.substr(q.length + 1);
      }
    }
    return StringTools.trim(out);
  }

  static function valueType(t:String):String {
    var s = StringTools.trim(t);
    while (StringTools.endsWith(s, "&")) s = StringTools.trim(s.substr(0, s.length - 1));
    return trimQualifiers(s);
  }

  static function isNumeric(t:String, nums:Array<String>):Bool {
    var s = trimQualifiers(t);
    if (s.indexOf("*") >= 0) return false;
    for (n in nums) if (s == n) return true;
    return false;
  }

  static function isPointerType(t:String):Bool {
    var s = trimQualifiers(t);
    if (!StringTools.endsWith(s, "*")) return false;
    while (StringTools.endsWith(s, "*")) s = StringTools.trim(s.substr(0, s.length - 1));
    s = StringTools.trim(s);
    if (s == "") return false;
    for (i in 0...s.length) {
      var c = s.charCodeAt(i);
      if (isIdentChar(c) || c == 58 || c == 60 || c == 62 || c == 32) continue;
      return false;
    }
    return true;
  }

  static function isVoid(t:String):Bool {
    return StringTools.trim(t) == "void";
  }

  static var typeTable:Map<String, String> = null;

  static function typeCodes():Map<String, String> {
    if (typeTable != null) return typeTable;
    var m = new Map<String, String>();
    for (t in ["double"]) m.set(t, "d");
    for (t in ["float"]) m.set(t, "f");
    for (t in ["bool"]) m.set(t, "b");
    for (t in ["char", "signed char", "unsigned char", "int8_t", "uint8_t"]) m.set(t, "c");
    for (t in ["short", "short int", "signed short", "signed short int", "unsigned short",
               "unsigned short int", "int16_t", "uint16_t"]) m.set(t, "h");
    for (t in ["int", "signed", "signed int", "int32_t"]) m.set(t, "i");
    for (t in ["unsigned", "unsigned int", "uint32_t"]) m.set(t, "u");
    for (t in ["long long", "long long int", "signed long long", "signed long long int",
               "unsigned long long", "unsigned long long int", "long long unsigned int",
               "long", "long int", "signed long", "signed long int",
               "unsigned long", "unsigned long int",
               "int64_t", "uint64_t", "size_t", "ssize_t", "ptrdiff_t",
               "intptr_t", "uintptr_t", "intmax_t", "uintmax_t"]) m.set(t, "l");
    typeTable = m;
    return m;
  }

  public static function code(t:String):String {
    var s = trimQualifiers(t);
    while (s.indexOf("  ") >= 0) s = s.split("  ").join(" ");
    if (s == "") return "v";
    if (s == "void") return "v";
    if (s.indexOf("std::string") >= 0 && s.indexOf("*") < 0) return s.indexOf("&") >= 0 ? "R" : "S";
    if (s.indexOf("*") >= 0) {
      var stars = 0;
      for (i in 0...s.length) if (s.charCodeAt(i) == 42) stars++;
      if (stars != 1) return "p";
      var base = StringTools.trim(s.substr(0, s.indexOf("*")));
      base = StringTools.trim(StringTools.replace(base, "const", ""));
      if (base == "char") return "s";
      return "p";
    }
    var c = typeCodes().get(s);
    if (c != null) return c;
    if (isNumeric(s, numerics())) return "i";
    return "?";
  }

  public static function enumNames(clean:String):Map<String, Bool> {
    var out = new Map<String, Bool>();
    for (line in clean.split("\n")) {
      var t = StringTools.trim(line);
      var p = 0;
      while (true) {
        var k = t.indexOf("enum", p);
        if (k < 0) break;
        p = k + 4;
        if (k > 0 && isIdentChar(t.charCodeAt(k - 1))) continue;
        if (p < t.length && isIdentChar(t.charCodeAt(p))) continue;
        var q = p;
        while (q < t.length && (t.charCodeAt(q) == 32 || t.charCodeAt(q) == 9)) q++;
        if (StringTools.startsWith(t.substr(q), "class ")) q += 6
        else if (StringTools.startsWith(t.substr(q), "struct ")) q += 7;
        var n0 = q;
        while (q < t.length && isIdentChar(t.charCodeAt(q))) q++;
        if (q > n0) out.set(t.substring(n0, q), true);
      }
    }
    return out;
  }

  static function isDefaultLiteral(d:String):Bool {
    var t = StringTools.trim(d);
    if (t == "") return true;
    if (t == "true" || t == "false" || t == "nullptr" || t == "NULL") return true;
    if (t.length >= 2) {
      var c = t.charAt(0);
      if ((c == '"' || c == "'") && t.charAt(t.length - 1) == c) return true;
    }
    if (~/^[+-]?0[xX][0-9a-fA-F]+[uUlL]*$/.match(t)) return true;
    if (~/^[+-]?[0-9]+\.?[0-9]*([eE][+-]?[0-9]+)?[fFuUlL]*$/.match(t)) return true;
    if (~/^[+-]?\.[0-9]+([eE][+-]?[0-9]+)?[fFuLl]*$/.match(t)) return true;
    return false;
  }

  static function splitArgs(p:String):Array<JitArgText> {
    var out:Array<String> = [];
    var t = StringTools.trim(p);
    if (t == "" || t == "void") return [];
    var depth = 0;
    var start = 0;
    for (i in 0...t.length) {
      var c = t.charCodeAt(i);
      if (c == 40 || c == 60 || c == 91) depth++;
      else if (c == 41 || c == 62 || c == 93) depth--;
      else if (c == 44 && depth == 0) {
        out.push(StringTools.trim(t.substring(start, i)));
        start = i + 1;
      }
    }
    out.push(StringTools.trim(t.substr(start)));
    var res:Array<JitArgText> = [];
    for (x in out) {
      if (x == "" || x == "void") continue;
      var def = "";
      var d = 0;
      for (i in 0...x.length) {
        var c = x.charCodeAt(i);
        if (c == 40 || c == 60 || c == 91) d++;
        else if (c == 41 || c == 62 || c == 93) d--;
        else if (c == 61 && d == 0) {
          def = StringTools.trim(x.substr(i + 1));
          x = StringTools.trim(x.substr(0, i));
          break;
        }
      }
      if (x.indexOf("(*") >= 0) {
        res.push({type: "void*", def: def});
        continue;
      }
      var sp = lastSpace(x);
      res.push({type: sp < 0 ? x : StringTools.trim(x.substr(0, sp)), def: def});
    }
    return res;
  }


  static function lastSpace(s:String):Int {
    var t = StringTools.trim(s);
    var i = t.length - 1;
    while (i >= 0) {
      var c = t.charCodeAt(i);
      if (c == 32 || c == 9) return i;
      i--;
    }
    return -1;
  }

  static function isIdent(s:String):Bool {
    if (s.length == 0) return false;
    for (i in 0...s.length) {
      var c = s.charCodeAt(i);
      var okc = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95;
      if (!okc) return false;
      if (i == 0 && c >= 48 && c <= 57) return false;
    }
    return true;
  }
}
