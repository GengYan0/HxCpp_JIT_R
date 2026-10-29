package hxcpp_jit_r;

import sys.FileSystem;
import sys.io.File;

class JitCache {
  public var root:String;

  public function new(root:String) {
    var n = root == null || root == "" ? "." : normalize(root);
    var p = n;
    if (FileSystem.exists(n)) {
      p = try FileSystem.fullPath(n) catch (e:Dynamic) n;
    } else if (!isAbsolute(n)) {
      p = normalize(Sys.getCwd()) + "/" + n;
    }
    this.root = p == null || p == "" || p == "null" ? "." : p;
  }

  static function isAbsolute(p:String):Bool {
    if (p.substr(0, 1) == "/") return true;
    return p.length > 2 && p.charAt(1) == ":" && (p.charAt(2) == "/" || p.charAt(2) == "\\");
  }

  public function headerFile():String {
    return root + "/rjit_abi.h";
  }

  public function prepare():Bool {
    mkdirs(root);
    var h = headerFile();
    if (FileSystem.exists(h)) {
      var cur:String = null;
      try cur = File.getContent(h) catch (e:Dynamic) {}
      if (cur == JitAbi.HEADER) return true;
    }
    if (!writeAtomic(h, JitAbi.HEADER)) return false;
    var after:String = null;
    try after = File.getContent(h) catch (e:Dynamic) {}
    return after == JitAbi.HEADER;
  }

  public static function writeAtomic(p:String, body:String):Bool {
    var t = p + "." + Std.random(1000000) + ".w";
    try File.saveContent(t, body) catch (e:Dynamic) return false;
    if (!publish(t, p)) {
      if (FileSystem.exists(t)) del(t);
      return false;
    }
    return true;
  }

  public static function publish(tmp:String, target:String):Bool {
    if (!FileSystem.exists(tmp)) return false;
    try {
      FileSystem.rename(tmp, target);
      return true;
    } catch (e:Dynamic) {}
    if (!FileSystem.exists(target)) {
      try {
        FileSystem.rename(tmp, target);
        return true;
      } catch (e:Dynamic) {
        return false;
      }
    }
    if (!del(target)) return false;
    try {
      FileSystem.rename(tmp, target);
      return true;
    } catch (e:Dynamic) {
      return false;
    }
  }

  public function dirFor(key:String):String {
    var d = root + "/" + key;
    mkdirs(d);
    return d;
  }

  public function ext():String {
    return JitPlatform.win ? ".dll" : ".so";
  }

  public function dllFor(key:String):Null<String> {
    var d = dirFor(key);
    var e = ext();
    var best = 0;
    var bestPath:Null<String> = null;
    for (f in list(d)) {
      if (!StringTools.startsWith(f, "mod") || !StringTools.endsWith(f, e)) continue;
      var mid = f.substr(3, f.length - 3 - e.length);
      var n = mid == "" ? 1 : (Std.parseInt(mid) ?? 99);
      if (bestPath == null || n > best) {
        best = n;
        bestPath = d + "/" + f;
      }
    }
    return bestPath;
  }

  public function nextBinary(key:String):String {
    var d = dirFor(key);
    var e = ext();
    var top = 0;
    for (f in list(d)) {
      if (!StringTools.startsWith(f, "mod") || !StringTools.endsWith(f, e)) continue;
      var mid = f.substr(3, f.length - 3 - e.length);
      var n = mid == "" ? 1 : (Std.parseInt(mid) ?? 0);
      if (n > top) top = n;
    }
    return top == 0 ? d + "/mod" + e : d + "/mod" + (top + 1) + e;
  }

  public function keys():Array<String> {
    var out:Array<String> = [];
    for (f in list(root)) {
      if (FileSystem.isDirectory(root + "/" + f)) out.push(f);
    }
    return out;
  }

  public function prune(key:String, keep:Int = 2):Int {
    var d = dirFor(key);
    var e = ext();
    var bins:Array<{p:String, n:Int}> = [];
    var n = 0;
    for (f in list(d)) {
      var p = d + "/" + f;
      if (StringTools.endsWith(f, ".tmp")) {
        if (del(p)) n++;
        continue;
      }
      if (!StringTools.startsWith(f, "mod") || !StringTools.endsWith(f, e)) continue;
      var mid = f.substr(3, f.length - 3 - e.length);
      bins.push({p: p, n: mid == "" ? 1 : (Std.parseInt(mid) ?? 0)});
    }
    if (bins.length <= keep) return n;
    bins.sort(function(a, b) return a.n - b.n);
    for (i in 0...(bins.length - keep)) if (del(bins[i].p)) n++;
    return n;
  }

  static function del(p:String):Bool {
    try {
      FileSystem.deleteFile(p);
      return true;
    } catch (e:Dynamic) {
      return false;
    }
  }

  public function purge():Int {
    var n = 0;
    for (f in list(root)) {
      var p = root + "/" + f;
      if (!FileSystem.isDirectory(p)) continue;
      n += countFiles(p);
      rmrf(p);
    }
    return n;
  }

  public function sweep(keep:Int, live:Map<String, Bool> = null):Int {
    var all = [];
    for (f in list(root)) {
      var p = root + "/" + f;
      if (FileSystem.isDirectory(p) && (live == null || !live.exists(f))) all.push({p: p, t: mtime(p)});
    }
    all.sort(function(a, b) return a.t < b.t ? 1 : (a.t > b.t ? -1 : 0));
    var n = 0;
    for (i in 0...all.length) {
      if (i < keep) continue;
      n += countFiles(all[i].p);
      rmrf(all[i].p);
    }
    return n;
  }

  public function size():Float {
    return bytes(root);
  }

  static function rmrf(p:String):Void {
    if (FileSystem.isDirectory(p)) {
      for (f in list(p)) rmrf(p + "/" + f);
      try FileSystem.deleteDirectory(p) catch (e:Dynamic) {}
    } else {
      try FileSystem.deleteFile(p) catch (e:Dynamic) {}
    }
  }

  static function list(p:String):Array<String> {
    if (!FileSystem.exists(p)) return [];
    try {
      return FileSystem.readDirectory(p);
    } catch (e:Dynamic) {
      return [];
    }
  }

  static function countFiles(p:String):Int {
    var n = 0;
    for (f in list(p)) {
      var q = p + "/" + f;
      if (FileSystem.isDirectory(q)) n += countFiles(q) else n++;
    }
    return n;
  }

  static function bytes(p:String):Float {
    var n:Float = 0;
    for (f in list(p)) {
      var q = p + "/" + f;
      if (FileSystem.isDirectory(q)) {
        n += bytes(q);
      } else {
        var sz = try FileSystem.stat(q).size catch (e:Dynamic) 0;
        n += sz;
      }
    }
    return n;
  }

  static function mtime(p:String):Float {
    var m:Float = 0;
    for (f in list(p)) {
      var q = p + "/" + f;
      var t = try FileSystem.stat(q).mtime.getTime() catch (e:Dynamic) 0;
      if (t > m) m = t;
    }
    return m;
  }

  public static function mkdirs(p:String):Void {
    if (FileSystem.exists(p)) return;
    var parent = parentOf(p);
    if (parent != null && parent != p) mkdirs(parent);
    try FileSystem.createDirectory(p) catch (e:Dynamic) {}
  }

  static function parentOf(p:String):Null<String> {
    var q = StringTools.replace(p, "\\", "/");
    var i = q.lastIndexOf("/");
    if (i <= 0) return null;
    return q.substr(0, i);
  }

  public static function normalize(p:String):String {
    var q = StringTools.replace(p, "\\", "/");
    while (q.length > 1 && StringTools.endsWith(q, "/")) q = q.substr(0, q.length - 1);
    return q;
  }

  public static function key(src:String, flags:String):String {
    var s = "j" + JitAbi.VERSION + "|" + flags + "|" + src;
    return haxe.crypto.Sha1.encode(s);
  }
}
