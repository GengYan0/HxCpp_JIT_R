package hxcpp_jit_r;

import hxcpp_jit_r.JitScan.JitFnInfo;
import hxcpp_jit_r.JitScan.JitVarInfo;
import hxcpp_jit_r.JitScan.JitStructInfo;

class JitCodegen {
  public static inline var BUILD:Int = 8;

  public static function emit(fns:Array<JitFnInfo>, vars:Array<JitVarInfo>, extra:Array<String> = null, structs:Array<JitStructInfo> = null):String {
    var b = new StringBuf();
    var sigs = new Map<String, Bool>();
    var used = false;
    var needString = false;

    var ptrs = new Map<String, Bool>();
    for (f in fns) {
      if (!f.callable) continue;
      used = true;
      if (f.sig.indexOf("S") >= 0) needString = true;
      var key = ptrName(f.name, f.sig);
      if (!ptrs.exists(key)) {
        ptrs.set(key, true);
        var fnty = retType(f.ret) + "(*)(" + [for (a in f.args) cppType(a)].join(",") + ")";
        b.add('extern "C" RJIT_API double rjit_ptr_' + key + '(RJitCtx* ctx, RJitArgs* args) { return (double)(size_t)(void*)(' + fnty + ')&' + f.name + '; }\n');
      }
      if (!sigs.exists(f.sig)) {
        sigs.set(f.sig, true);
        b.add(dispatcher(f.sig));
      }
    }

    if (extra != null) {
      for (s in extra) {
        if (sigs.exists(s) || s.indexOf("(") < 0) continue;
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
        for (f in st.fields) {
          b.add('extern "C" RJIT_API double rjit_getf_' + fieldName(v.name, f.name) + '(RJitCtx* ctx, RJitArgs* args) { return (double)' + v.name + '.' + f.name + '; }\n');
          if (!v.isConst) b.add('extern "C" RJIT_API double rjit_setf_' + fieldName(v.name, f.name) + '(RJitCtx* ctx, RJitArgs* args) { ' + v.name + '.' + f.name + ' = (' + f.raw + ')args->a[0]; return (double)' + v.name + '.' + f.name + '; }\n');
        }
      } else {
        b.add('extern "C" RJIT_API double rjit_getv_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { return (double)(' + v.name + '); }\n');
        if (!v.isConst) b.add('extern "C" RJIT_API double rjit_setv_' + v.name + '(RJitCtx* ctx, RJitArgs* args) { ' + v.name + ' = (decltype(' + v.name + '))args->a[0]; return 0.0; }\n');
      }
    }

    if (!used) return "";
    var head = needString ? "\n#include <string>\n" : "\n";
    return head + b.toString();
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
    return 'extern "C" RJIT_API double ' + name + '(void* f, RJitArgs* a) { ' + call + ' }\n';
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
      default: "double";
    };
  }

  static function retCast(c:String):String {
    return switch (c) {
      case "v": "";
      case "p": "(double)(size_t)";
      case "s": "(double)(size_t)";
      default: "(double)";
    };
  }

  static function argExpr(c:String, i:Int):String {
    var raw = "a->a[" + i + "]";
    var sp = "a->s[" + i + "]";
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
      case "S": "std::string(" + sp + " != 0 ? " + sp + " : \"\", " + sp + " != 0 ? (size_t)a->sl[" + i + "] : (size_t)0)";
      default: raw;
    };
  }
}
