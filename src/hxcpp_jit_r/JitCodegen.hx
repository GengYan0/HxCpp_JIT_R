package hxcpp_jit_r;

import hxcpp_jit_r.JitScan.JitFnInfo;
import hxcpp_jit_r.JitScan.JitVarInfo;
import hxcpp_jit_r.JitScan.JitStructInfo;
import hxcpp_jit_r.JitScan.JitFieldInfo;

typedef JitLeaf = {
  var path:String;
  var type:String;
}

class JitCodegen {
  public static inline var BUILD:Int = 13;
  public static inline var MAX_DEPTH:Int = 3;

  public static function emit(fns:Array<JitFnInfo>, vars:Array<JitVarInfo>, extra:Array<String> = null, structs:Array<JitStructInfo> = null, externs:Array<String> = null):String {
    var b = new StringBuf();
    var sigs = new Map<String, Bool>();
    var used = false;
    var needString = false;

    if (externs != null) {
      for (e in externs) {
        if (e == null || e == "") continue;
        b.add("extern " + e + ";\n");
        used = true;
      }
    }

    var ptrs = new Map<String, Bool>();
    for (f in fns) {
      if (f.ret == "t") {
        used = true;
        b.add(retWrapper(f));
        continue;
      }
      if (f.ret == "S") {
        used = true;
        needString = true;
        b.add(strWrapper(f));
        continue;
      }
      if (!f.callable) continue;
      used = true;
      if (f.sig.indexOf("S") >= 0) needString = true;
      var key = ptrName(f.name, f.sig);
      if (!ptrs.exists(key)) {
        ptrs.set(key, true);
        var fnty = retType(f.ret) + "(*)(" + (needsCustom(f) ? argParts(f, "args").types : [for (a in f.args) cppType(a)]).join(",") + ")";
        b.add('extern "C" RJIT_API double rjit_ptr_' + key + '(RJitCtx* ctx, RJitArgs* args) { return (double)(size_t)(void*)(' + fnty + ')&' + f.name + '; }\n');
      }
      var df = defFrom(f);
      if (df >= 0) {
        for (k in df...f.args.length) b.add(arityDispatcher(f, k));
      }
      if (needsCustom(f)) {
        b.add(dispatcherFor(f));
      } else if (!sigs.exists(f.sig)) {
        sigs.set(f.sig, true);
        b.add(dispatcher(f.sig));
      }
    }

    if (extra != null) {
      for (s in extra) {
        if (sigs.exists(s) || s.indexOf("(") < 0) continue;
        if (StringTools.startsWith(s, "S(")) continue;
        sigs.set(s, true);
        used = true;
        if (s.indexOf("S") >= 0) needString = true;
        b.add(dispatcher(s));
      }
    }

    var stMap = new Map<String, JitStructInfo>();
    if (structs != null) for (s in structs) stMap.set(s.name, s);

    for (v in vars) {
      used = true;
      if (v.kind == "array") {
        b.add('extern "C" RJIT_API double rjit_addra_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { return (double)(size_t)(void*)&' + v.name + '[0]; }\n');
        b.add('extern "C" RJIT_API double rjit_geta_' + v.name + '(RJitCtx* ctx, RJitArgs* args) {\n'
          + '  int i = (int)args->a[0];\n'
          + '  if (i < 0 || i >= ' + v.size + ') return 0.0;\n'
          + '  return (double)' + v.name + '[i];\n}\n');
        if (!v.isConst) b.add('extern "C" RJIT_API double rjit_seta_' + v.name + '(RJitCtx* ctx, RJitArgs* args) {\n'
          + '  int i = (int)args->a[0];\n'
          + '  if (i < 0 || i >= ' + v.size + ') return 0.0;\n'
          + '  ' + v.name + '[i] = (' + v.type + ')args->a[1];\n'
          + '  return (double)' + v.name + '[i];\n}\n');
      } else if (v.kind == "struct") {
        var st = stMap.get(v.structName);
        if (st == null) continue;
        b.add('extern "C" RJIT_API double rjit_addrv_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { return (double)(size_t)(void*)&' + v.name + '; }\n');
        b.add('extern "C" RJIT_API double rjit_szof_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { return (double)sizeof(' + v.name + '); }\n');
        for (l in leafList(stMap, v.structName)) {
          var fn = v.name + "__" + l.path.split(".").join("__");
          var acc = v.name + "." + l.path;
          if (l.type == "S") {
            needString = true;
            b.add('extern "C" RJIT_API double rjit_getstr_' + fn + '(RJitCtx* ctx, RJitArgs* args) {\n  const std::string& v = ' + acc + ';\n  RJIT_RETSTRN(v.c_str(), (int)v.size());\n  return 0.0;\n}\n');
            if (!v.isConst) b.add('extern "C" RJIT_API double rjit_setstr_' + fn + '(RJitCtx* ctx, RJitArgs* args) {\n  ' + acc + '.assign(args->s[0] != 0 ? args->s[0] : "", args->s[0] != 0 ? (size_t)args->sl[0] : (size_t)0);\n  return 0.0;\n}\n');
            continue;
          }
          b.add('extern "C" RJIT_API double rjit_getf_' + fn + '(RJitCtx* ctx, RJitArgs* args) { return ' + getExpr(l.type, acc) + '; }\n');
          if (!v.isConst) b.add('extern "C" RJIT_API double rjit_setf_' + fn + '(RJitCtx* ctx, RJitArgs* args) { ' + acc + ' = ' + setExpr(l.type, acc) + '; return ' + getExpr(l.type, acc) + '; }\n');
        }
      } else if (v.kind == "structarray") {
        var st = stMap.get(v.structName);
        if (st == null) continue;
        b.add('extern "C" RJIT_API double rjit_addra_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { return (double)(size_t)(void*)&' + v.name + '[0]; }\n');
        b.add('extern "C" RJIT_API double rjit_addrv_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { return (double)(size_t)(void*)&' + v.name + '[0]; }\n');
        b.add('extern "C" RJIT_API double rjit_szof_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { return (double)sizeof(' + v.name + '[0]); }\n');
        for (l in leafList(stMap, v.structName)) {
          var fn = v.name + "__" + l.path.split(".").join("__");
          var acc = v.name + '[i].' + l.path;
          if (l.type == "S") {
            needString = true;
            b.add('extern "C" RJIT_API double rjit_getstra_' + fn + '(RJitCtx* ctx, RJitArgs* args) {\n'
              + '  int i = (int)args->a[0];\n'
              + '  if (i < 0 || i >= ' + v.size + ') return 0.0;\n'
              + '  const std::string& v = ' + acc + ';\n'
              + '  RJIT_RETSTRN(v.c_str(), (int)v.size());\n'
              + '  return 0.0;\n}\n');
            if (!v.isConst) b.add('extern "C" RJIT_API double rjit_setstra_' + fn + '(RJitCtx* ctx, RJitArgs* args) {\n'
              + '  int i = (int)args->a[0];\n'
              + '  if (i < 0 || i >= ' + v.size + ') return 0.0;\n'
              + '  ' + acc + '.assign(args->s[0] != 0 ? args->s[0] : "", args->s[0] != 0 ? (size_t)args->sl[0] : (size_t)0);\n'
              + '  return 0.0;\n}\n');
            continue;
          }
          b.add('extern "C" RJIT_API double rjit_getfa_' + fn + '(RJitCtx* ctx, RJitArgs* args) {\n'
            + '  int i = (int)args->a[0];\n'
            + '  if (i < 0 || i >= ' + v.size + ') return 0.0;\n'
            + '  return ' + getExpr(l.type, acc) + ';\n}\n');
          if (!v.isConst) b.add('extern "C" RJIT_API double rjit_setfa_' + fn + '(RJitCtx* ctx, RJitArgs* args) {\n'
            + '  int i = (int)args->a[0];\n'
            + '  if (i < 0 || i >= ' + v.size + ') return 0.0;\n'
            + '  ' + acc + ' = ' + setExpr(l.type, acc) + ';\n'
            + '  return ' + getExpr(l.type, acc) + ';\n}\n');
        }
      } else if (v.kind == "ptr") {
        b.add('extern "C" RJIT_API double rjit_addrv_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { return (double)(size_t)(void*)&' + v.name + '; }\n');
        b.add('extern "C" RJIT_API double rjit_getv_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { return (double)(size_t)(void*)(' + v.name + '); }\n');
        if (!v.isConst) b.add('extern "C" RJIT_API double rjit_setv_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { ' + v.name + ' = (decltype(' + v.name + '))(size_t)args->a[0]; return 0.0; }\n');
      } else {
        b.add('extern "C" RJIT_API double rjit_addrv_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { return (double)(size_t)(void*)&' + v.name + '; }\n');
        b.add('extern "C" RJIT_API double rjit_getv_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { return (double)(' + v.name + '); }\n');
        if (!v.isConst) b.add('extern "C" RJIT_API double rjit_setv_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { ' + v.name + ' = (decltype(' + v.name + '))args->a[0]; return 0.0; }\n');
      }
    }

    if (!used) return "";
    var head = needString ? "\n#include <string>\n" : "\n";
    return head + b.toString();
  }

  public static function leafList(stMap:Map<String, JitStructInfo>, sname:String, prefix:String = "", depth:Int = 0):Array<JitLeaf> {
    var out:Array<JitLeaf> = [];
    if (depth >= MAX_DEPTH) return out;
    var st = stMap.get(sname);
    if (st == null) return out;
    for (f in st.fields) {
      var path = prefix == "" ? f.name : prefix + "." + f.name;
      if (f.nested != "") {
        for (q in leafList(stMap, f.nested, path, depth + 1)) out.push(q);
      } else {
        out.push({path: path, type: f.type});
      }
    }
    return out;
  }

  public static function leafPaths(stMap:Map<String, JitStructInfo>, sname:String, prefix:String = "", depth:Int = 0):Array<String> {
    return [for (l in leafList(stMap, sname, prefix, depth)) l.path];
  }

  public static function getExpr(t:String, acc:String):String {
    return (t == "p" || t == "s") ? "(double)(size_t)(void*)(" + acc + ")" : "(double)(" + acc + ")";
  }

  public static function setExpr(t:String, acc:String):String {
    var slot = acc.indexOf("[i]") >= 0 ? 1 : 0;
    return "(decltype(" + acc + "))" + ((t == "p" || t == "s") ? "(size_t)" : "") + "args->a[" + slot + "]";
  }

  public static function fieldName(v:String, f:String):String {
    return v + "__" + f;
  }

  public static function ptrName(name:String, sig:String):String {
    return name + "_" + flat(sig);
  }

  public static function flat(sig:String):String {
    return sig.split("(").join("").split(")").join("");
  }

  public static function dispNameOf(name:String, sig:String):String {
    return "rjit_dn_" + name + "_" + flat(sig);
  }

  public static function dispName(sig:String):String {
    var p = sig.indexOf("(");
    if (p < 0) return "";
    var ret = sig.substr(0, p);
    var args = sig.substr(p + 1, sig.length - p - 2);
    return "rjit_disp_" + ret + "_" + args;
  }

  public static function dispatcher(sig:String):String {
    var p = sig.indexOf("(");
    var ret = sig.substr(0, p);
    var argSigs = sig.substr(p + 1, sig.length - p - 2);
    var types:Array<String> = [];
    var expr:Array<String> = [];
    var numSlot = 0;
    var strSlot = 0;
    for (i in 0...argSigs.length) {
      var c = argSigs.charAt(i);
      types.push(cppType(c));
      if (c == "s" || c == "S") {
        expr.push(argExpr(c, strSlot));
        strSlot++;
      } else {
        expr.push(argExpr(c, numSlot));
        numSlot++;
      }
    }
    var name = dispName(sig);
    var fnty = retType(ret) + "(*)(" + types.join(",") + ")";
    var body = "((" + fnty + ")f)(" + expr.join(", ") + ")";
    var call = ret == "v" ? body + "; return 0.0;" : "return " + retCast(ret) + body + ";";
    return 'extern "C" RJIT_API double ' + name + '(RJitCtx* ctx, void* f, RJitArgs* a) { try { ' + call + ' } catch (...) { return rjit_nan_val(); } }' + "\n";
  }

  public static function pointee(raw:String):String {
    var t = StringTools.trim(raw);
    while (StringTools.endsWith(t, "&")) t = StringTools.trim(t.substr(0, t.length - 1));
    return t;
  }

  public static function needsCustom(f:JitFnInfo):Bool {
    return f.args.indexOf("t") >= 0 || f.args.indexOf("r") >= 0 || f.args.indexOf("R") >= 0 || f.args.indexOf("W") >= 0;
  }

  public static function argParts(f:JitFnInfo, pfx:String):{types:Array<String>, expr:Array<String>, strs:Int, pre:Array<String>, post:String} {
    var types:Array<String> = [];
    var expr:Array<String> = [];
    var pre:Array<String> = [];
    var post = "";
    var num = 0;
    var str = 0;
    for (i in 0...f.args.length) {
      var c = f.args[i];
      var raw = f.rawArgs != null && i < f.rawArgs.length ? StringTools.trim(f.rawArgs[i]) : null;
      if ((c == "t" || c == "r") && raw != null && raw != "") {
        types.push(raw);
        expr.push("*((" + pointee(raw) + "*)(size_t)" + pfx + "->a[" + num + "])");
        num++;
      } else if (c == "R" || c == "W") {
        types.push(raw != null && raw != "" ? raw : "std::string&");
        if (c == "W") {
          var nm = "rjit_w" + str;
          pre.push("std::string " + nm + "(" + argExpr("S", str, pfx) + ");");
          expr.push(nm);
          if (post == "") post = "RJIT_RETSTRN(" + nm + ".c_str(), (int)" + nm + ".size());";
        } else {
          expr.push(argExpr("S", str, pfx));
        }
        str++;
      } else if (c == "s" || c == "S") {
        types.push(cppType(c));
        expr.push(argExpr(c, str, pfx));
        str++;
      } else {
        types.push(cppType(c));
        expr.push(argExpr(c, num, pfx));
        num++;
      }
    }
    return {types: types, expr: expr, strs: str, pre: pre, post: post};
  }

  static function body(f:JitFnInfo, a:{types:Array<String>, expr:Array<String>, pre:Array<String>, post:String}, fnty:String):String {
    var callExpr = "((" + fnty + ")f)(" + a.expr.join(", ") + ")";
    var head = a.pre.length == 0 ? "" : a.pre.join(" ") + " ";
    var tail = a.post == "" ? "" : " " + a.post;
    if (f.ret == "v") return head + callExpr + ";" + tail + " return 0.0;";
    return head + "double rjit_r = " + retCast(f.ret) + callExpr + ";" + tail + " return rjit_r;";
  }

  public static function defFrom(f:JitFnInfo):Int {
    if (f.defaults == null) return -1;
    var i = 0;
    while (i < f.defaults.length && f.defaults[i] == "") i++;
    return i < f.args.length ? i : -1;
  }

  public static function arityDispName(f:JitFnInfo, k:Int):String {
    return "rjit_da_" + f.name + "_" + flat(f.sig) + "_" + k;
  }

  public static function retWrapper(f:JitFnInfo):String {
    var a = argParts(f, "args");
    var rawRet = StringTools.trim(f.rawRet);
    while (StringTools.startsWith(rawRet, "static ")) rawRet = StringTools.trim(rawRet.substr(7));
    while (StringTools.startsWith(rawRet, "inline ")) rawRet = StringTools.trim(rawRet.substr(7));
    var fnty = rawRet + "(*)(" + a.types.join(",") + ")";
    var head = a.pre.length == 0 ? "" : a.pre.join(" ") + " ";
    var tail = a.post == "" ? "" : "    " + a.post + "\n";
    return 'extern "C" RJIT_API double rjit_ret_' + ptrName(f.name, f.sig) + '(RJitCtx* ctx, RJitArgs* args) {' + "\n"
      + '  static thread_local ' + rawRet + ' rjit_ring[8];' + "\n"
      + '  static thread_local unsigned rjit_slot = 0;' + "\n"
      + '  ' + rawRet + '& rjit_out = rjit_ring[rjit_slot++ & 7u];' + "\n"
      + '  try {' + "\n"
      + '    ' + head + 'rjit_out = ((' + fnty + ')&' + f.name + ')(' + a.expr.join(", ") + ');' + "\n"
      + tail
      + '  } catch (...) { return rjit_nan_val(); }' + "\n"
      + '  return (double)(size_t)(void*)&rjit_out;' + "\n"
      + '}' + "\n";
  }

  public static function arityDispatcher(f:JitFnInfo, k:Int):String {
    var a = argParts(f, "a");
    var part = {
      types: a.types,
      expr: a.expr.slice(0, k).concat([for (i in k...f.args.length) f.defaults[i]]),
      pre: a.pre,
      post: a.post
    };
    var fnty = retType(f.ret) + "(*)(" + a.types.join(",") + ")";
    return 'extern "C" RJIT_API double ' + arityDispName(f, k) + '(RJitCtx* ctx, void* f, RJitArgs* a) { try { ' + body(f, part, fnty) + ' } catch (...) { return rjit_nan_val(); } }' + "\n";
  }

  public static function dispatcherFor(f:JitFnInfo):String {
    var a = argParts(f, "a");
    var fnty = retType(f.ret) + "(*)(" + a.types.join(",") + ")";
    return 'extern "C" RJIT_API double ' + dispNameOf(f.name, f.sig) + '(RJitCtx* ctx, void* f, RJitArgs* a) { try { ' + body(f, a, fnty) + ' } catch (...) { return rjit_nan_val(); } }' + "\n";
  }

  static function cppType(c:String):String {
    return switch (c) {
      case "d": "double";
      case "f": "float";
      case "b": "bool";
      case "c": "char";
      case "h": "short";
      case "i": "int";
      case "u": "unsigned int";
      case "l": "long long";
      case "p": "void*";
      case "s": "const char*";
      case "S": "std::string";
      default: "double";
    };
  }

  static function retType(c:String):String {
    return switch (c) {
      case "v": "void";
      case "f": "float";
      case "b": "bool";
      case "c": "char";
      case "h": "short";
      case "i": "int";
      case "u": "unsigned int";
      case "l": "long long";
      case "p": "void*";
      case "s": "const char*";
      case "S": "std::string";
      default: "double";
    };
  }

  static function strWrapper(f:JitFnInfo):String {
    var a = argParts(f, "args");
    var fnty = "std::string(*)(" + a.types.join(",") + ")";
    var head = a.pre.length == 0 ? "" : a.pre.join(" ") + " ";
    return 'extern "C" RJIT_API double rjit_str_' + ptrName(f.name, f.sig) + '(RJitCtx* ctx, RJitArgs* args) {' + "\n"
      + '  try {' + "\n"
      + '    ' + head + 'std::string r = ((' + fnty + ')&' + f.name + ')(' + a.expr.join(", ") + ');' + "\n"
      + '    RJIT_RETSTRN(r.c_str(), (int)r.size());' + "\n"
      + '  } catch (...) { return rjit_nan_val(); }' + "\n"
      + '  return 0.0;' + "\n"
      + '}' + "\n";
  }

  static function retCast(c:String):String {
    return switch (c) {
      case "v": "";
      case "p": "(double)(size_t)";
      case "s": "(double)(size_t)";
      default: "(double)";
    };
  }

  static function argExpr(c:String, i:Int, p:String = "a"):String {
    var raw = p + "->a[" + i + "]";
    var sp = p + "->s[" + i + "]";
    return switch (c) {
      case "f": "(float)" + raw;
      case "b": "(bool)" + raw;
      case "c": "(char)" + raw;
      case "h": "(short)" + raw;
      case "i": "(int)" + raw;
      case "u": "(unsigned int)" + raw;
      case "l": "(long long)" + raw;
      case "p": "(void*)(size_t)" + raw;
      case "s": "(" + sp + " != 0 ? " + sp + " : \"\")";
      case "S": "std::string(" + sp + " != 0 ? " + sp + " : \"\", " + sp + " != 0 ? (size_t)" + p + "->sl[" + i + "] : (size_t)0)";
      default: raw;
    };
  }
}
