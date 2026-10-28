package hxcpp_jit_r;

import sys.FileSystem;
import sys.io.File;

typedef JitSection = {
  var name:String;
  var va:Int;
  var vsize:Int;
  var raw:Int;
  var rawSize:Int;
  var chars:Int;
}

typedef JitDir = {
  var rva:Int;
  var size:Int;
}

class JitImage {
  public var path:String = "";
  public var base:cpp.SizeT = 0;
  public var imageBase:Float = 0;
  public var sizeOfImage:Int = 0;
  public var sizeOfHeaders:Int = 0;
  public var entry:Int = 0;
  public var pe32plus:Bool = true;
  public var dirs:Array<JitDir> = [];
  public var sections:Array<JitSection> = [];
  public var exports:Map<String, Float> = new Map();
  public var forwarders:Map<String, String> = new Map();
  public var imports:Array<String> = [];
  public var handles:Array<cpp.SizeT> = [];
  public var fwdCache:Map<String, Float> = new Map();
  public var tlsIndex:Int = -1;
  public var tlsStart:cpp.SizeT = 0;
  public var tlsEnd:cpp.SizeT = 0;
  public var tlsZero:Int = 0;
  public var relocCount:Int = 0;
  public var rebased:Bool = false;
  public var fnTable:cpp.SizeT = 0;
  public var fnCount:Int = 0;
  public var ok:Bool = false;
  public var error:String = "";
  public var manual:Bool = false;
  public var needsLoader:Bool = false;
  public var handle:cpp.SizeT = 0;
  public var alloc:cpp.SizeT = 0;
  public var allocSize:Int = 0;
  public var initVa:cpp.SizeT = 0;
  public var finiVa:cpp.SizeT = 0;
  public var initArr:cpp.SizeT = 0;
  public var initArrSize:Int = 0;
  public var finiArr:cpp.SizeT = 0;
  public var finiArrSize:Int = 0;

  public function new() {}

  public function summary():String {
    if (!ok) return "image " + path + " FAILED: " + error;
    return 'image $path base=0x${StringTools.hex(Std.int(base), 0)} image=${sizeOfImage}B sections=${sections.length} exports=${Lambda.count(exports)} imports=${imports.length} reloc=$relocCount rebased=$rebased manual=$manual';
  }
}

class JitLoader {
  public static var verbose:Bool = false;
  public static var allowEntryFail:Bool = true;
  public static var skipEntry:Bool = false;
  public static var lastEntryFault:Int = 0;
  static var images:Map<String, JitImage> = new Map();

  static inline function at(base:cpp.SizeT, off:Int):cpp.SizeT {
    return JitNative.toSizeT(JitNative.toFloat(base) + off);
  }

  public static function ptrOf(b:haxe.io.Bytes):cpp.SizeT {
    return untyped __cpp__("(size_t){0}->b->Pointer()", b);
  }

  public static function track(img:JitImage):Void {
    images.set(Std.string(img.base), img);
  }

  public static function releaseImage(img:JitImage):Void {
    if (img == null) return;
    teardownTls(img);
    unregisterUnwind(img);
    releaseLibs(img);
    if (img.alloc != 0) {
      JitNative.vfree(img.alloc, img.allocSize);
      img.alloc = 0;
    } else if (img.base != 0) {
      JitNative.vfree(img.base, img.sizeOfImage);
    }
    img.base = 0;
    img.ok = false;
  }

  static inline function u32(v:Int):Float {
    return v >= 0 ? v * 1.0 : v + 4294967296.0;
  }

  static function readStr(base:cpp.SizeT, rva:Int, max:Int = 512):String {
    var b = new StringBuf();
    var i = 0;
    while (i < max) {
      var c = Std.int(JitNative.peek(at(base, rva + i), 1));
      if (c == 0) break;
      b.addChar(c);
      i++;
    }
    return b.toString();
  }

  public static function parse(path:String):JitImage {
    if (!FileSystem.exists(path)) {
      var img = new JitImage();
      img.path = JitCache.normalize(path);
      img.error = "file not found";
      return img;
    }
    var b:haxe.io.Bytes = null;
    try {
      b = File.getBytes(path);
    } catch (e:Dynamic) {
      var img = new JitImage();
      img.path = JitCache.normalize(path);
      img.error = "read failed: " + Std.string(e);
      return img;
    }
    return parseBytes(path, b);
  }

  public static function parseBytes(path:String, b:haxe.io.Bytes):JitImage {
    var img = new JitImage();
    img.path = JitCache.normalize(path);
    if (b == null) {
      img.error = "read failed";
      return img;
    }
    if (b.length < 0x40) {
      img.error = "too small";
      return img;
    }
    if (b.getUInt16(0) != 0x5A4D) {
      img.error = "missing MZ";
      return img;
    }
    var nt = b.getInt32(0x3C);
    if (nt <= 0 || nt + 24 > b.length) {
      img.error = "bad e_lfanew";
      return img;
    }
    if (b.getInt32(nt) != 0x00004550) {
      img.error = "missing PE signature";
      return img;
    }
    var fh = nt + 4;
    var numSec = b.getUInt16(fh + 2);
    var sizeOpt = b.getUInt16(fh + 16);
    var opt = fh + 20;
    if (opt + sizeOpt > b.length) {
      img.error = "truncated optional header";
      return img;
    }
    var magic = b.getUInt16(opt);
    if (magic != 0x20B && magic != 0x10B) {
      img.error = "unsupported magic " + StringTools.hex(magic, 4);
      return img;
    }
    img.pe32plus = magic == 0x20B;
    img.entry = b.getInt32(opt + 16);
    if (img.pe32plus) {
      img.imageBase = u32(b.getInt32(opt + 28)) * 4294967296.0 + u32(b.getInt32(opt + 24));
    } else {
      img.imageBase = u32(b.getInt32(opt + 28));
    }
    img.sizeOfImage = b.getInt32(opt + 56);
    img.sizeOfHeaders = b.getInt32(opt + 60);
    var ddOff = opt + (img.pe32plus ? 112 : 96);
    var ddCount = b.getInt32(opt + (img.pe32plus ? 108 : 92));
    if (ddCount < 0) ddCount = 0;
    if (ddCount > 16) ddCount = 16;
    for (i in 0...16) {
      if (i < ddCount && ddOff + i * 8 + 8 <= b.length) {
        img.dirs.push({rva: b.getInt32(ddOff + i * 8), size: b.getInt32(ddOff + i * 8 + 4)});
      } else {
        img.dirs.push({rva: 0, size: 0});
      }
    }
    var secOff = opt + sizeOpt;
    for (i in 0...numSec) {
      var s = secOff + i * 40;
      if (s + 40 > b.length) break;
      var rawName = b.getString(s, 8);
      var z = rawName.indexOf("\x00");
      var nm = z >= 0 ? rawName.substr(0, z) : rawName;
      img.sections.push({
        name: nm,
        vsize: b.getInt32(s + 8),
        va: b.getInt32(s + 12),
        rawSize: b.getInt32(s + 16),
        raw: b.getInt32(s + 20),
        chars: b.getInt32(s + 36)
      });
    }
    if (img.sizeOfImage <= 0) {
      img.error = "bad SizeOfImage";
      return img;
    }
    img.ok = true;
    return img;
  }

  public static function load(path:String):JitImage {
    if (!JitPlatform.win) return JitElf.load(path);
    var bytes:haxe.io.Bytes = null;
    try {
      bytes = File.getBytes(path);
    } catch (e:Dynamic) {
      var f = new JitImage();
      f.path = JitCache.normalize(path);
      f.error = "read failed: " + Std.string(e);
      return f;
    }
    var img = parseBytes(path, bytes);
    if (!img.ok) return img;
    var src = ptrOf(bytes);
    var want = img.imageBase > 0 && img.imageBase < 4294967296.0 * 8192 ? JitNative.toSizeT(img.imageBase) : 0;
    var base = JitNative.valloc(want, img.sizeOfImage);
    if (base == 0 && want != 0) base = JitNative.valloc(0, img.sizeOfImage);
    if (base == 0) {
      img.ok = false;
      img.error = "VirtualAlloc failed for " + img.sizeOfImage + " bytes";
      return img;
    }
    img.base = base;
    if (verbose) Sys.println("[load] alloc base=0x" + StringTools.hex(Std.int(JitNative.toFloat(base)), 0) + " want=0x" + StringTools.hex(Std.int(img.imageBase), 0) + " size=" + img.sizeOfImage);
    var delta = JitNative.toFloat(base) - img.imageBase;
    img.rebased = delta != 0;

    var hdr = img.sizeOfHeaders;
    if (hdr > img.sizeOfImage) hdr = img.sizeOfImage;
    if (hdr > bytes.length) hdr = bytes.length;
    if (hdr > 0) JitNative.memcpyRaw(base, src, hdr);

    for (s in img.sections) {
      if (s.raw <= 0 || s.rawSize <= 0) continue;
      var len = s.rawSize;
      if (s.vsize > 0 && len > s.vsize) len = s.vsize;
      if (s.raw + len > bytes.length) len = bytes.length - s.raw;
      if (len <= 0) continue;
      if (s.va < 0 || s.va + len > img.sizeOfImage) {
        img.ok = false;
        img.error = "section " + s.name + " does not fit the image";
        JitNative.vfree(base, img.sizeOfImage);
        img.base = 0;
        return img;
      }
      JitNative.memcpyRaw(at(base, s.va), JitNative.toSizeT(JitNative.toFloat(src) + s.raw), len);
    }

    if (verbose) Sys.println("[load] sections copied");
    if (img.rebased && !applyRelocs(img, delta)) {
      img.ok = false;
      if (img.error == "") img.error = "image needs rebasing but has no usable relocation table";
      JitNative.vfree(base, img.sizeOfImage);
      img.base = 0;
      return img;
    }

    if (verbose) Sys.println("[load] reloc done n=" + img.relocCount);
    if (!resolveImports(img)) {
      JitNative.vfree(base, img.sizeOfImage);
      img.base = 0;
      return img;
    }

    if (verbose) Sys.println("[load] imports done " + img.imports.join(","));
    registerUnwind(img);
    JitNative.flushIcache(base, img.sizeOfImage);
    setupTls(img);
    if (verbose) Sys.println("[load] tls idx=" + img.tlsIndex);
    parseExports(img);
    if (verbose) Sys.println("[load] exports=" + Lambda.count(img.exports) + " fwd=" + Lambda.count(img.forwarders));
    if (verbose) Sys.println("[load] calling entry 0x" + StringTools.hex(img.entry, 0));

    if (img.entry != 0 && !skipEntry) {
      if (img.entry < 0 || img.entry >= img.sizeOfImage) {
        img.ok = false;
        img.error = "entry point outside the image";
        teardownTls(img);
        JitNative.vfree(base, img.sizeOfImage);
        img.base = 0;
        return img;
      }
      lastEntryFault = 0;
      var rc = JitNative.callEntry(at(base, img.entry), base, 1, 0);
      if (verbose) Sys.println("[load] entry rc=" + rc + " fault=0x" + StringTools.hex(lastEntryFault, 8));
      if (rc == 0 && !allowEntryFail) {
        img.ok = false;
        img.error = "DllMain returned FALSE";
        teardownTls(img);
        JitNative.vfree(base, img.sizeOfImage);
        img.base = 0;
        return img;
      }
      if (rc == -1) img.error = "DllMain faulted 0x" + StringTools.hex(lastEntryFault, 8);
    }
    img.manual = true;
    images.set(Std.string(base), img);
    if (verbose) Sys.println("[load] " + img.summary());
    return img;
  }

  static function applyRelocs(img:JitImage, delta:Float):Bool {
    var d = img.dirs[5];
    if (d.rva == 0 || d.size == 0) return false;
    var base = img.base;
    var p = 0;
    var n = 0;
    while (p < d.size) {
      if (d.rva + p + 8 > img.sizeOfImage || d.rva + p + 8 > d.rva + d.size) {
        img.error = "relocation block outside the directory";
        return false;
      }
      var va = Std.int(JitNative.peek(at(base, d.rva + p), 4));
      var blockSize = Std.int(JitNative.peek(at(base, d.rva + p + 4), 4));
      if (blockSize < 8 || p + blockSize > d.size) {
        img.error = "malformed relocation block size " + blockSize;
        return false;
      }
      var cnt = Std.int((blockSize - 8) / 2);
      for (i in 0...cnt) {
        var e = Std.int(JitNative.peek(at(base, d.rva + p + 8 + i * 2), 2));
        var ty = e >> 12;
        var off = e & 0x0FFF;
        if (ty == 0) continue;
        if (va + off + 8 > img.sizeOfImage) {
          img.error = "relocation target outside the image";
          return false;
        }
        if (JitNative.addRel(at(base, va + off), delta, ty) == 0) {
          img.error = "unsupported base relocation type " + ty;
          return false;
        }
        n++;
      }
      p += blockSize;
    }
    img.relocCount = n;
    return n > 0;
  }

  static function resolveImports(img:JitImage):Bool {
    var d = img.dirs[1];
    if (d.rva == 0) return true;
    var base = img.base;
    var ps = img.pe32plus ? 8 : 4;
    var p = 0;
    var guard = 0;
    while (guard++ < 4096) {
      var off = d.rva + p;
      if (off < 0 || off + 20 > img.sizeOfImage || off + 20 > d.rva + d.size) break;
      var origThunk = Std.int(JitNative.peek(at(base, off), 4));
      var nameRva = Std.int(JitNative.peek(at(base, off + 12), 4));
      var firstThunk = Std.int(JitNative.peek(at(base, off + 16), 4));
      if (origThunk == 0 && nameRva == 0 && firstThunk == 0) break;
      if (nameRva == 0 || firstThunk == 0) {
        p += 20;
        continue;
      }
      if (nameRva < 0 || nameRva >= img.sizeOfImage || firstThunk < 0 || firstThunk >= img.sizeOfImage) {
        img.ok = false;
        img.error = "import descriptor points outside the image";
        releaseLibs(img);
        return false;
      }
      var dll = readStr(base, nameRva);
      if (dll == "") {
        img.ok = false;
        img.error = "import descriptor has no module name";
        releaseLibs(img);
        return false;
      }
      var h = JitNative.loadLibA(dll);
      if (h == 0) {
        img.ok = false;
        img.error = "import dll not loadable: " + dll;
        releaseLibs(img);
        return false;
      }
      img.imports.push(dll);
      img.handles.push(h);
      var thunkRva = origThunk != 0 ? origThunk : firstThunk;
      var i = 0;
      while (i < 65536 && thunkRva + i * ps + ps <= img.sizeOfImage && firstThunk + i * ps + ps <= img.sizeOfImage) {
        var slot = at(base, thunkRva + i * ps);
        var addr:cpp.SizeT = 0;
        if (img.pe32plus) {
          var v = JitNative.peek(slot, 8);
          if (v == 0) break;
          if (v >= 9223372036854775808.0) {
            addr = JitNative.getProcOrd(h, Std.int(v - 9223372036854775808.0));
          } else if (v >= img.sizeOfImage - 2) {
            img.ok = false;
            img.error = "import name points outside the image";
            releaseLibs(img);
            return false;
          } else {
            addr = JitNative.getProcAt(h, at(base, Std.int(v) + 2));
          }
        } else {
          var v = JitNative.peek(slot, 4);
          if (v == 0) break;
          if (v >= 2147483648.0) {
            addr = JitNative.getProcOrd(h, Std.int(v - 2147483648.0));
          } else if (v >= img.sizeOfImage - 2) {
            img.ok = false;
            img.error = "import name points outside the image";
            releaseLibs(img);
            return false;
          } else {
            addr = JitNative.getProcAt(h, at(base, Std.int(v) + 2));
          }
        }
        if (addr == 0) {
          img.ok = false;
          img.error = "unresolved import in " + dll + " slot " + i;
          releaseLibs(img);
          return false;
        }
        JitNative.poke(at(base, firstThunk + i * ps), ps, JitNative.toFloat(addr));
        i++;
      }
      p += 20;
    }
    return true;
  }

  static function releaseLibs(img:JitImage):Void {
    for (h in img.handles) JitNative.unloadDll(h);
    img.handles = [];
    img.imports = [];
  }

  static function setupTls(img:JitImage):Void {
    var d = img.dirs[9];
    if (d.rva == 0 || d.rva + d.size > img.sizeOfImage) return;
    if (d.size < (img.pe32plus ? 40 : 24)) return;
    var base = img.base;
    var idxVa = img.pe32plus
      ? JitNative.peek(at(base, d.rva + 16), 8)
      : JitNative.peek(at(base, d.rva + 8), 4);
    var cbVa = img.pe32plus
      ? JitNative.peek(at(base, d.rva + 24), 8)
      : JitNative.peek(at(base, d.rva + 12), 4);
    var startVa = img.pe32plus
      ? JitNative.peek(at(base, d.rva), 8)
      : JitNative.peek(at(base, d.rva), 4);
    var endVa = img.pe32plus
      ? JitNative.peek(at(base, d.rva + 8), 8)
      : JitNative.peek(at(base, d.rva + 4), 4);
    var zeroFill = Std.int(JitNative.peek(at(base, d.rva + (img.pe32plus ? 32 : 16)), 4));
    img.tlsStart = JitNative.toSizeT(startVa);
    img.tlsEnd = JitNative.toSizeT(endVa);
    img.tlsZero = zeroFill;
    if (idxVa != 0) {
      var idx = JitNative.setupTls(JitNative.toSizeT(idxVa), img.tlsStart, img.tlsEnd, zeroFill);
      img.tlsIndex = idx;
    }
    if (cbVa != 0) {
      var ps = img.pe32plus ? 8 : 4;
      var i = 0;
      while (i < 64) {
        var f = JitNative.peek(at(JitNative.toSizeT(cbVa), i * ps), ps);
        if (f == 0) break;
        JitNative.callEntry(JitNative.toSizeT(f), base, 1, 0);
        i++;
      }
    }
  }

  static function unregisterUnwind(img:JitImage):Void {
    if (img.fnTable == 0) return;
    JitNative.delFnTable(img.fnTable);
    img.fnTable = 0;
    img.fnCount = 0;
  }

  static function teardownTls(img:JitImage):Void {
    if (img.tlsIndex < 0) return;
    if (JitPlatform.win) JitNative.clearTls(img.tlsIndex) else JitNative.tlsUnregister(img.tlsIndex);
    img.tlsIndex = -1;
  }

  static function parseExports(img:JitImage):Void {
    var d = img.dirs[0];
    if (d.rva == 0 || d.size == 0 || d.size < 40) return;
    if (d.rva + d.size > img.sizeOfImage) return;
    var base = img.base;
    var nFuncs = Std.int(JitNative.peek(at(base, d.rva + 20), 4));
    var nNames = Std.int(JitNative.peek(at(base, d.rva + 24), 4));
    var addrFuncs = Std.int(JitNative.peek(at(base, d.rva + 28), 4));
    var addrNames = Std.int(JitNative.peek(at(base, d.rva + 32), 4));
    var addrOrds = Std.int(JitNative.peek(at(base, d.rva + 36), 4));
    if (nNames <= 0 || nNames > 65536 || nFuncs <= 0 || addrNames == 0 || addrFuncs == 0 || addrOrds == 0) return;
    for (i in 0...nNames) {
      var nameRva = Std.int(JitNative.peek(at(base, addrNames + i * 4), 4));
      var ord = Std.int(JitNative.peek(at(base, addrOrds + i * 2), 2));
      if (ord < 0 || ord >= nFuncs) continue;
      var fnRva = Std.int(JitNative.peek(at(base, addrFuncs + ord * 4), 4));
      if (nameRva == 0 || fnRva == 0) continue;
      var nm = readStr(base, nameRva, 256);
      if (nm == "") continue;
      if (fnRva >= d.rva && fnRva < d.rva + d.size) {
        var fwd = readStr(base, fnRva, 256);
        if (fwd != "") img.forwarders.set(nm, fwd);
      } else {
        img.exports.set(nm, JitNative.toFloat(base) + fnRva);
      }
    }
  }

  static function registerUnwind(img:JitImage):Void {
    var d = img.dirs[3];
    if (d.rva == 0 || d.size < 12) return;
    var first = Std.int(JitNative.peek(at(img.base, d.rva), 4));
    if (first == 0) return;
    var n = Std.int(d.size / 12);
    var t = at(img.base, d.rva);
    if (JitNative.addFnTable(t, n, img.base) == 0) return;
    img.fnTable = t;
    img.fnCount = n;
  }

  public static function proc(img:JitImage, name:String):cpp.SizeT {
    if (img == null) return 0;
    if (!img.manual) {
      if (img.handle == 0) return 0;
      return JitNative.getProc(img.handle, name);
    }
    var a = img.exports.get(name);
    if (a != null) return JitNative.toSizeT(a);
    var cached = img.fwdCache.get(name);
    if (cached != null) return JitNative.toSizeT(cached);
    var fwd = img.forwarders.get(name);
    if (fwd != null) {
      var dot = fwd.lastIndexOf(".");
      if (dot <= 0) return 0;
      var dll = fwd.substr(0, dot);
      var fn = fwd.substr(dot + 1);
      if (dll.indexOf(".") < 0) dll = dll + ".dll";
      var h = JitNative.loadLibA(dll);
      if (h == 0) return 0;
      var a = JitNative.getProc(h, fn);
      img.fwdCache.set(name, JitNative.toFloat(a));
      return a;
    }
    return 0;
  }

  public static function find(base:cpp.SizeT):JitImage {
    return images.get(Std.string(base));
  }

  public static function unload(img:JitImage):Bool {
    if (img == null || !img.ok) return false;
    if (!img.manual) {
      if (img.handle != 0) JitNative.unloadDll(img.handle);
      img.handle = 0;
      img.ok = false;
      return true;
    }
    if (img.entry != 0) {
      if (JitPlatform.win) JitNative.callEntry(at(img.base, img.entry), img.base, 0, 0);
    }
    if (!JitPlatform.win) JitElf.runFiniArray(img);
    teardownTls(img);
    unregisterUnwind(img);
    img.fwdCache = new Map();
    releaseLibs(img);
    images.remove(Std.string(img.base));
    if (img.alloc != 0) {
      JitNative.vfree(img.alloc, img.allocSize);
      img.alloc = 0;
    } else {
      JitNative.vfree(img.base, img.sizeOfImage);
    }
    img.base = 0;
    img.ok = false;
    return true;
  }

  public static function bindThread():Int {
    var n = 0;
    for (k in images.keys()) {
      var img = images.get(k);
      if (img == null || img.tlsIndex < 0) continue;
      if (JitNative.bindTlsBlock(img.tlsIndex, img.tlsStart, img.tlsEnd, img.tlsZero) != 0) n++;
    }
    return n;
  }

  public static function count():Int {
    return Lambda.count(images);
  }
}
