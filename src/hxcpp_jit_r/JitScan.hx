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
      "intptr_t", "uintptr_t", "ptrdiff_t"
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
      if (c == 34 || c == 39) {
        inStr = c;
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
        if (!isIdent(fn)) continue;
        var c = code(ty);
        var tq = StringTools.trim(ty);
        if (c == "?" && known.exists(tq) && tq != d.name) {
          fields.push({name: fn, type: "struct", raw: ty, nested: tq});
          continue;
        }
        if (c == "?" || c == "v" || c == "R") continue;
        fields.push({name: fn, type: c, raw: ty, nested: ""});
      }
      if (fields.length > 0) out.push({name: d.name, fields: fields});
    }
    return out;
  }

  public static function functions(src:String, structs:Array<JitStructInfo> = null):Array<JitFnInfo> {
    var clean = strip(src);
    var kw = keywords();
    var nums = numerics();
    var sts = new Map<String, Bool>();
    if (structs != null) for (st in structs) sts.set(st.name, true);
    var out:Array<JitFnInfo> = [];
    var lines = clean.split("\n");
    for (li in 0...lines.length) {
      var line = lines[li];
      var head = line.substr(0, line.length - StringTools.ltrim(line).length);
      if (head.length > 0 && head.indexOf("\t") < 0 && head.length > 2) continue;
      var s = StringTools.trim(line);
      if (s == "" || s.charAt(0) == "#") continue;
      if (s.indexOf("(") < 0 || s.indexOf(")") < 0) continue;
      if (s.indexOf("{") < 0) continue;
      var p = s.indexOf("(");
      var q = s.indexOf(")", p);
      if (q < 0) continue;
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
      for (t in rawArgs) {
        var c = code(t);
        if (c == "R" && t.indexOf("const") < 0) c = "W";
        if (c == "?") {
          var raw0 = StringTools.trim(t);
          var bare = raw0;
          while (StringTools.endsWith(bare, "&")) bare = StringTools.trim(bare.substr(0, bare.length - 1));
          var base = trimQualifiers(bare);
          if (sts.exists(base)) c = "t";
          else if (bare != raw0 && isNumeric(base, nums)) c = "r";
        }
        if (c == "?") {
          ok = false;
          break;
        }
        if (c == "s" || c == "S") strArgs++;
        args.push(c);
      }
      if (args.length > 6) ok = false;
      if (args.length - strArgs > 6) ok = false;
      if (strArgs > 4) ok = false;
      var rc = code(ret);
      if (rc == "v" && !isVoid(ret)) ok = false;
      if (rc == "?" && sts.exists(trimQualifiers(ret))) rc = "t";
      if (rc == "?") ok = false;
      if (rc == "S" || rc == "R") ok = false;
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
    for (line in clean.split("\n")) {
      var raw = line;
      if (raw.length == 0) continue;
      var lead = raw.substr(0, raw.length - StringTools.ltrim(raw).length);
      if (lead.length > 0) continue;
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
            if (c == "v" || c == "p" || c == "s" || c == "S") continue;
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

  public static function code(t:String):String {
    var s = trimQualifiers(t);
    while (s.indexOf("  ") >= 0) s = s.split("  ").join(" ");
    if (s == "") return "v";
    if (s == "void") return "v";
    if (s.indexOf("std::string") >= 0) return s.indexOf("&") >= 0 ? "R" : "S";
    if (s.indexOf("*") >= 0) {
      if (s.indexOf("char") >= 0) return "s";
      return "p";
    }
    if (s == "double") return "d";
    if (s == "float") return "f";
    if (s == "bool") return "b";
    if (s == "char" || s == "signed char" || s == "unsigned char") return "c";
    if (s == "short" || s == "short int" || s == "signed short" || s == "unsigned short") return "h";
    if (s == "unsigned" || s == "unsigned int" || s == "unsigned long") return "u";
    if (s == "long long" || s == "unsigned long long" || s == "int64_t" || s == "uint64_t" || s == "long") return "l";
    if (isNumeric(s, numerics())) return "i";
    return "?";
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
