package hxcpp_jit_r;

import sys.FileSystem;
import sys.io.File;

typedef PackEntry = {
  var key:String;
  var file:String;
  var bytes:Int;
}

class JitPack {
  public static function manifest(root:String):String {
    var list:Array<PackEntry> = [];
    var dirs = safeList(root);
    for (d in dirs) {
      if (d == "pch") continue;
      var p = root + "/" + d;
      if (!FileSystem.isDirectory(p)) continue;
      for (f in safeList(p)) {
        if (!StringTools.startsWith(f, "mod")) continue;
        if (!StringTools.endsWith(f, ".dll") && !StringTools.endsWith(f, ".so")) continue;
        var full = p + "/" + f;
        var sz = try FileSystem.stat(full).size catch (e:Dynamic) 0;
        list.push({key: d, file: f, bytes: sz});
      }
    }
    var o = {
      abi: JitAbi.VERSION,
      codegen: JitCodegen.BUILD,
      platform: platform(),
      modules: list
    };
    return haxe.Json.stringify(o, "  ");
  }

  static function platform():String {
    var arch = #if HXCPP_M32 "x86" #else "x64" #end;
    return switch (Sys.systemName()) {
      case "Windows": "windows-" + arch;
      case "Mac": "macos-" + arch;
      default: "linux-" + arch;
    };
  }

  public static function exportPack(root:String, dir:String, only:Map<String, Bool> = null):Int {
    var target = JitCache.normalize(dir);
    mkdirs(target);
    var n = 0;
    for (d in safeList(root)) {
      if (d == "pch") continue;
      var p = root + "/" + d;
      if (!FileSystem.isDirectory(p)) continue;
      if (only != null && !only.exists(d)) continue;
      var has = false;
      for (f in safeList(p)) {
        if (StringTools.startsWith(f, "mod") && (StringTools.endsWith(f, ".dll") || StringTools.endsWith(f, ".so"))) has = true;
      }
      if (!has) continue;
      mkdirs(target + "/" + d);
      for (f in safeList(p)) {
        if (!isPayload(f)) continue;
        if (copyFile(p + "/" + f, target + "/" + d + "/" + f)) n++;
      }
    }
    var h = root + "/rjit_abi.h";
    if (FileSystem.exists(h)) {
      if (copyFile(h, target + "/rjit_abi.h")) n++;
    }
    File.saveContent(target + "/manifest.json", manifest(root));
    return n;
  }

  static function isPayload(f:String):Bool {
    if (StringTools.endsWith(f, ".pch") || StringTools.endsWith(f, ".pdb") || StringTools.endsWith(f, ".ilk")) return false;
    if (StringTools.endsWith(f, ".obj") || StringTools.endsWith(f, ".lib") || StringTools.endsWith(f, ".exp")) return false;
    if (StringTools.endsWith(f, ".dll") || StringTools.endsWith(f, ".so")) return true;
    if (StringTools.endsWith(f, ".cpp") || StringTools.endsWith(f, ".cc")) return true;
    if (StringTools.endsWith(f, ".json")) return true;
    return false;
  }

  public static function importPack(root:String, dir:String):Int {
    var src = JitCache.normalize(dir);
    if (!FileSystem.exists(src)) return 0;
    var n = 0;
    for (d in safeList(src)) {
      var p = src + "/" + d;
      if (!FileSystem.isDirectory(p)) continue;
      if (d == "pch") continue;
      mkdirs(root + "/" + d);
      for (f in safeList(p)) {
        if (!isPayload(f)) continue;
        var dst = root + "/" + d + "/" + f;
        if (FileSystem.exists(dst)) {
          n++;
          continue;
        }
        if (copyFile(p + "/" + f, dst)) n++;
      }
    }
    var h = src + "/rjit_abi.h";
    if (FileSystem.exists(h)) {
      var dstH = root + "/rjit_abi.h";
      if (!FileSystem.exists(dstH) || File.getContent(dstH) != JitAbi.HEADER) File.saveContent(dstH, JitAbi.HEADER);
      n++;
    }
    return n;
  }

  public static function checkPack(dir:String):String {
    var src = JitCache.normalize(dir);
    var mf = src + "/manifest.json";
    if (!FileSystem.exists(mf)) return "pack has no manifest.json";
    var o:Dynamic = null;
    try {
      o = haxe.Json.parse(File.getContent(mf));
    } catch (e:Dynamic) {
      return "manifest unreadable: " + Std.string(e);
    }
    var abi = Reflect.field(o, "abi");
    var cg = Reflect.field(o, "codegen");
    if (abi != null && abi != JitAbi.VERSION) return "pack abi " + abi + " != host " + JitAbi.VERSION;
    if (cg != null && cg != JitCodegen.BUILD) return "pack codegen " + cg + " != host " + JitCodegen.BUILD;
    var pf = Reflect.field(o, "platform");
    if (pf != null && pf != platform()) return "pack platform " + pf + " != host " + platform();
    return "";
  }

  public static function manifestInfo(dir:String):String {
    var src = JitCache.normalize(dir);
    var bad = checkPack(src);
    if (bad != "") return bad;
    var o:Dynamic = null;
    try {
      o = haxe.Json.parse(File.getContent(src + "/manifest.json"));
    } catch (e:Dynamic) {
      return "manifest unreadable: " + Std.string(e);
    }
    var mods:Array<Dynamic> = Reflect.field(o, "modules");
    var n = mods == null ? 0 : mods.length;
    var bytes:Float = 0;
    if (mods != null) for (m in mods) bytes += Reflect.field(m, "bytes");
    return "pack ok: abi=" + Reflect.field(o, "abi") + " codegen=" + Reflect.field(o, "codegen") + " platform=" + Reflect.field(o, "platform") + " modules=" + n + " bytes=" + Std.int(bytes);
  }

  static function copyFile(a:String, b:String):Bool {
    try {
      File.saveBytes(b, File.getBytes(a));
      return true;
    } catch (e:Dynamic) {
      return false;
    }
  }

  static function safeList(p:String):Array<String> {
    if (!FileSystem.exists(p)) return [];
    try {
      return FileSystem.readDirectory(p);
    } catch (e:Dynamic) {
      return [];
    }
  }

  static function mkdirs(p:String):Void {
    if (FileSystem.exists(p)) return;
    var q = JitCache.normalize(p);
    var i = q.lastIndexOf("/");
    if (i > 1) mkdirs(q.substr(0, i));
    try FileSystem.createDirectory(p) catch (e:Dynamic) {}
  }
}
