package hxcpp_jit_r;

import sys.FileSystem;
import sys.io.File;
import hxcpp_jit_r.JitLoader.JitImage;

typedef ElfPhdr = {
  var type:Int;
  var flags:Int;
  var offset:Float;
  var vaddr:Float;
  var filesz:Float;
  var memsz:Float;
  var align:Float;
}

typedef ElfInfo = {
  var ok:Bool;
  var error:String;
  var type:Int;
  var machine:Int;
  var entry:Float;
  var phoff:Float;
  var phentsize:Int;
  var phnum:Int;
  var phdrs:Array<ElfPhdr>;
}

class JitElf {
  public static inline var PT_LOAD = 1;
  public static inline var PT_DYNAMIC = 2;
  public static inline var PT_INTERP = 3;
  public static inline var PT_PHDR = 6;

  public static inline var ET_DYN = 3;

  public static inline var EM_X86_64 = 0x3E;
  public static inline var EM_AARCH64 = 0xB7;

  public static inline var DT_NULL = 0;
  public static inline var DT_NEEDED = 1;
  public static inline var DT_PLTRELSZ = 2;
  public static inline var DT_HASH = 4;
  public static inline var DT_STRTAB = 5;
  public static inline var DT_SYMTAB = 6;
  public static inline var DT_RELA = 7;
  public static inline var DT_RELASZ = 8;
  public static inline var DT_STRSZ = 10;
  public static inline var DT_SYMENT = 11;
  public static inline var DT_INIT = 12;
  public static inline var DT_FINI = 13;
  public static inline var DT_REL = 17;
  public static inline var DT_RELSZ = 18;
  public static inline var DT_JMPREL = 23;
  public static inline var DT_INIT_ARRAY = 25;
  public static inline var DT_FINI_ARRAY = 26;
  public static inline var DT_INIT_ARRAYSZ = 27;
  public static inline var DT_FINI_ARRAYSZ = 28;
  public static inline var DT_GNU_HASH = 0x6ffffef5;

  public static inline var R_X86_64_64 = 1;
  public static inline var R_X86_64_COPY = 5;
  public static inline var R_X86_64_GLOB_DAT = 6;
  public static inline var R_X86_64_JUMP_SLOT = 7;
  public static inline var R_X86_64_RELATIVE = 8;
  public static inline var R_AARCH64_ABS64 = 257;
  public static inline var R_AARCH64_GLOB_DAT = 1025;
  public static inline var R_AARCH64_JUMP_SLOT = 1026;
  public static inline var R_AARCH64_RELATIVE = 1027;

  static inline function u32(b:haxe.io.Bytes, o:Int):Float {
    var v = b.getInt32(o);
    return v >= 0 ? v : v + 4294967296.0;
  }

  static inline function u64(b:haxe.io.Bytes, o:Int):Float {
    return u32(b, o) + u32(b, o + 4) * 4294967296.0;
  }

  public static function isElf(b:haxe.io.Bytes):Bool {
    if (b == null || b.length < 64) return false;
    return b.get(0) == 0x7F && b.get(1) == 0x45 && b.get(2) == 0x4C && b.get(3) == 0x46;
  }

  public static function parse(b:haxe.io.Bytes):ElfInfo {
    var info:ElfInfo = {
      ok: false,
      error: "",
      type: 0,
      machine: 0,
      entry: 0,
      phoff: 0,
      phentsize: 0,
      phnum: 0,
      phdrs: []
    };
    if (!isElf(b)) {
      info.error = "not an ELF file";
      return info;
    }
    if (b.get(4) != 2) {
      info.error = "ELF32 is not supported";
      return info;
    }
    if (b.get(5) != 1) {
      info.error = "big endian ELF is not supported";
      return info;
    }
    info.type = b.getUInt16(16);
    info.machine = b.getUInt16(18);
    info.entry = u64(b, 24);
    info.phoff = u64(b, 32);
    info.phentsize = b.getUInt16(54);
    info.phnum = b.getUInt16(56);
    if (info.phnum == 0 || info.phentsize < 56) {
      info.error = "missing program headers";
      return info;
    }
    if (info.phoff + info.phnum * info.phentsize > b.length) {
      info.error = "truncated program headers";
      return info;
    }
    var off = Std.int(info.phoff);
    for (i in 0...info.phnum) {
      var o = off + i * info.phentsize;
      info.phdrs.push({
        type: b.getInt32(o),
        flags: b.getInt32(o + 4),
        offset: u64(b, o + 8),
        vaddr: u64(b, o + 16),
        filesz: u64(b, o + 32),
        memsz: u64(b, o + 40),
        align: u64(b, o + 48)
      });
    }
    info.ok = true;
    return info;
  }

  static function roundUp(v:Float, to:Int):Float {
    var r = v % to;
    return r == 0 ? v : v + (to - r);
  }

  #if linux
  static function mpeek(p:cpp.SizeT, w:Int):Float {
    return JitNative.peek(p, w);
  }

  static function memAt(baseF:Float, off:Float):cpp.SizeT {
    return JitNative.toSizeT(baseF + off);
  }

  static function readMemStr(p:cpp.SizeT, max:Int = 256):String {
    var b = new StringBuf();
    var i = 0;
    var pv = JitNative.toFloat(p);
    while (i < max) {
      var c = Std.int(mpeek(JitNative.toSizeT(pv + i), 1));
      if (c == 0) break;
      b.addChar(c);
      i++;
    }
    return b.toString();
  }

  public static function load(path:String):JitImage {
    var img = new JitImage();
    img.path = JitCache.normalize(path);
    if (!FileSystem.exists(path)) {
      img.error = "file not found";
      return img;
    }
    var bytes = File.getBytes(path);
    var info = parse(bytes);
    if (!info.ok) {
      img.error = info.error;
      return img;
    }
    if (info.type != ET_DYN) {
      img.error = "only shared objects can be mapped";
      return img;
    }
    if (info.machine != EM_X86_64 && info.machine != EM_AARCH64) {
      img.error = "unsupported machine " + info.machine;
      return img;
    }
    var loads:Array<ElfPhdr> = [];
    var dynPh:ElfPhdr = null;
    var minVa = 0.0;
    var maxVa = 0.0;
    var first = true;
    for (ph in info.phdrs) {
      if (ph.type == PT_LOAD) {
        loads.push(ph);
        var s = ph.vaddr - (ph.vaddr % 4096);
        if (first || s < minVa) minVa = s;
        var e = ph.vaddr + ph.memsz;
        if (e > maxVa) maxVa = e;
        first = false;
      } else if (ph.type == PT_DYNAMIC) {
        dynPh = ph;
      }
    }
    if (loads.length == 0) {
      img.error = "no PT_LOAD segments";
      return img;
    }
    var total = Std.int(roundUp(maxVa - minVa, 4096));
    if (total <= 0 || total > 0x40000000) {
      img.error = "bad image size " + total;
      return img;
    }
    var alloc = JitNative.valloc(0, total);
    if (alloc == 0) {
      img.error = "mapping " + total + " bytes failed";
      return img;
    }
    var baseF = JitNative.toFloat(alloc) - minVa;
    var src = JitLoader.ptrOf(bytes);
    for (ph in loads) {
      var dst = JitNative.toSizeT(baseF + ph.vaddr);
      var len = Std.int(ph.filesz);
      if (len > 0) {
        if (ph.offset + len > bytes.length) len = bytes.length - Std.int(ph.offset);
        if (len > 0) JitNative.memcpyRaw(dst, JitNative.toSizeT(JitNative.toFloat(src) + ph.offset), len);
      }
      var z = Std.int(ph.memsz - ph.filesz);
      if (z > 0) JitNative.memzero(JitNative.toSizeT(baseF + ph.vaddr + ph.filesz), z);
    }
    img.base = JitNative.toSizeT(baseF);
    img.alloc = alloc;
    img.allocSize = total;
    img.sizeOfImage = total;
    img.pe32plus = true;
    img.entry = Std.int(info.entry);
    img.manual = true;
    img.ok = true;

    if (dynPh == null) {
      JitNative.flushIcache(alloc, total);
      JitLoader.track(img);
      return img;
    }

    var d = Std.int(dynPh.offset);
    var dynEnd = d + Std.int(dynPh.filesz);
    var neededOff:Array<Float> = [];
    var strtabVa = 0.0;
    var symtabVa = 0.0;
    var relaVa = 0.0;
    var relaSz = 0.0;
    var relVa = 0.0;
    var relSz = 0.0;
    var jmpVa = 0.0;
    var jmpSz = 0.0;
    var hashVa = 0.0;
    var gnuHashVa = 0.0;
    var initVa = 0.0;
    var finiVa = 0.0;
    var initArrVa = 0.0;
    var initArrSz = 0.0;
    var finiArrVa = 0.0;
    var finiArrSz = 0.0;
    while (d + 16 <= dynEnd) {
      var tag = Std.int(u64(bytes, d));
      var val = u64(bytes, d + 8);
      if (tag == DT_NULL) break;
      if (tag == DT_NEEDED) neededOff.push(val);
      else if (tag == DT_STRTAB) strtabVa = val;
      else if (tag == DT_SYMTAB) symtabVa = val;
      else if (tag == DT_RELA) relaVa = val;
      else if (tag == DT_RELASZ) relaSz = val;
      else if (tag == DT_REL) relVa = val;
      else if (tag == DT_RELSZ) relSz = val;
      else if (tag == DT_JMPREL) jmpVa = val;
      else if (tag == DT_PLTRELSZ) jmpSz = val;
      else if (tag == DT_HASH) hashVa = val;
      else if (tag == DT_GNU_HASH) gnuHashVa = val;
      else if (tag == DT_INIT) initVa = val;
      else if (tag == DT_FINI) finiVa = val;
      else if (tag == DT_INIT_ARRAY) initArrVa = val;
      else if (tag == DT_INIT_ARRAYSZ) initArrSz = val;
      else if (tag == DT_FINI_ARRAY) finiArrVa = val;
      else if (tag == DT_FINI_ARRAYSZ) finiArrSz = val;
      d += 16;
    }

    if (strtabVa != 0) {
      for (o in neededOff) {
        var n = readMemStr(memAt(baseF, strtabVa + o));
        if (n == "") continue;
        var h = JitNative.loadLibA(n);
        if (h == 0) {
          img.error = "dependency not loadable: " + n;
          JitLoader.releaseImage(img);
          return img;
        }
        img.imports.push(n);
        img.handles.push(h);
      }
    }

    var symCount = symbolCount(baseF, hashVa, gnuHashVa);

    if (!applyRela(img, baseF, symtabVa, strtabVa, symCount, relaVa, relaSz, false)) {
      JitLoader.releaseImage(img);
      return img;
    }
    if (!applyRela(img, baseF, symtabVa, strtabVa, symCount, relVa, relSz, true)) {
      JitLoader.releaseImage(img);
      return img;
    }
    if (!applyRela(img, baseF, symtabVa, strtabVa, symCount, jmpVa, jmpSz, false)) {
      JitLoader.releaseImage(img);
      return img;
    }

    collectExports(img, baseF, symtabVa, strtabVa, symCount);
    img.initVa = JitNative.toSizeT(baseF + initVa);
    img.finiVa = JitNative.toSizeT(baseF + finiVa);
    img.initArr = JitNative.toSizeT(baseF + initArrVa);
    img.initArrSize = Std.int(initArrSz);
    img.finiArr = JitNative.toSizeT(baseF + finiArrVa);
    img.finiArrSize = Std.int(finiArrSz);

    runInitArray(img.initArr, img.initArrSize);
    if (img.initVa != 0) JitNative.callInit(img.initVa);
    JitNative.flushIcache(alloc, total);
    JitLoader.track(img);
    return img;
  }

  static function symbolCount(baseF:Float, hash:Float, gnuHash:Float):Int {
    if (hash != 0) {
      var n = Std.int(mpeek(memAt(baseF, hash + 4), 4));
      if (n > 0 && n < 1000000) return n;
    }
    if (gnuHash != 0) {
      var g = memAt(baseF, gnuHash);
      var nbuckets = Std.int(mpeek(g, 4));
      var symoffset = Std.int(mpeek(JitNative.toSizeT(JitNative.toFloat(g) + 4), 4));
      var bloomSize = Std.int(mpeek(JitNative.toSizeT(JitNative.toFloat(g) + 8), 4));
      if (nbuckets > 0 && nbuckets < 1000000 && bloomSize > 0 && bloomSize < 1000000) {
        var buckets = JitNative.toSizeT(JitNative.toFloat(g) + 16 + bloomSize * 8);
        var last = 0;
        for (i in 0...nbuckets) {
          var b = Std.int(mpeek(JitNative.toSizeT(JitNative.toFloat(buckets) + i * 4), 4));
          if (b > last) last = b;
        }
        if (last >= symoffset) {
          var chain = JitNative.toSizeT(JitNative.toFloat(buckets) + nbuckets * 4);
          var idx = last;
          while (idx < 1000000) {
            var v = Std.int(mpeek(JitNative.toSizeT(JitNative.toFloat(chain) + (idx - symoffset) * 4), 4));
            idx++;
            if ((v & 1) != 0) break;
          }
          if (idx > 0) return idx;
        }
        return symoffset;
      }
    }
    return 0;
  }

  static function applyRela(img:JitImage, baseF:Float, symtab:Float, strtab:Float, symCount:Int, va:Float, size:Float, relStyle:Bool):Bool {
    if (va == 0 || size <= 0) return true;
    var ent = relStyle ? 16 : 24;
    var n = Std.int(size / ent);
    if (n <= 0) return true;
    var p = memAt(baseF, va);
    for (i in 0...n) {
      var e = JitNative.toSizeT(JitNative.toFloat(p) + i * ent);
      var off = mpeek(e, 8);
      var info0 = mpeek(JitNative.toSizeT(JitNative.toFloat(e) + 8), 8);
      var symIdx = Std.int(info0 / 4294967296.0);
      var ty = Std.int(info0 - symIdx * 4294967296.0) & 0xFFFF;
      var addend = relStyle
        ? mpeek(memAt(baseF, off), 8)
        : mpeek(JitNative.toSizeT(JitNative.toFloat(e) + 16), 8);
      var target = memAt(baseF, off);
      if (ty == 0) continue;
      if (ty == R_X86_64_RELATIVE || ty == R_AARCH64_RELATIVE) {
        JitNative.poke(target, 8, baseF + addend);
        img.relocCount++;
        continue;
      }
      if (symIdx <= 0) {
        img.error = "relocation without symbol at offset " + Std.int(off);
        return false;
      }
      if (symCount > 0 && symIdx >= symCount) {
        img.error = "symbol index " + symIdx + " out of range";
        return false;
      }
      var symE = memAt(baseF, symtab + symIdx * 24);
      var nameOff = Std.int(mpeek(symE, 4));
      var shndx = Std.int(mpeek(JitNative.toSizeT(JitNative.toFloat(symE) + 6), 2));
      var value = mpeek(JitNative.toSizeT(JitNative.toFloat(symE) + 8), 8);
      var name = nameOff == 0 ? "" : readMemStr(memAt(baseF, strtab + nameOff));
      var sVal = 0.0;
      if (shndx != 0 && value != 0) {
        sVal = baseF + value;
      } else if (name != "") {
        sVal = JitNative.toFloat(JitNative.getProcGlobal(name));
      }
      if (sVal == 0.0) {
        img.error = "unresolved symbol " + (name == "" ? "#" + symIdx : name);
        return false;
      }
      if (ty == R_X86_64_64 || ty == R_AARCH64_ABS64) {
        JitNative.poke(target, 8, sVal + addend);
      } else if (ty == R_X86_64_GLOB_DAT || ty == R_X86_64_JUMP_SLOT || ty == R_AARCH64_GLOB_DAT || ty == R_AARCH64_JUMP_SLOT) {
        JitNative.poke(target, 8, sVal);
      } else if (ty == R_X86_64_COPY) {
        var sz = Std.int(mpeek(JitNative.toSizeT(JitNative.toFloat(symE) + 16), 8));
        if (sz > 0) JitNative.memcpyRaw(target, JitNative.toSizeT(sVal), sz);
      } else {
        img.error = "unsupported relocation type " + ty;
        return false;
      }
      img.relocCount++;
    }
    return true;
  }

  static function collectExports(img:JitImage, baseF:Float, symtab:Float, strtab:Float, symCount:Int):Void {
    if (symtab == 0 || symCount <= 0) return;
    for (i in 1...symCount) {
      var symE = memAt(baseF, symtab + i * 24);
      var nameOff = Std.int(mpeek(symE, 4));
      if (nameOff == 0) continue;
      var shndx = Std.int(mpeek(JitNative.toSizeT(JitNative.toFloat(symE) + 6), 2));
      if (shndx == 0) continue;
      var value = mpeek(JitNative.toSizeT(JitNative.toFloat(symE) + 8), 8);
      if (value == 0) continue;
      var name = readMemStr(memAt(baseF, strtab + nameOff));
      if (name == "" || img.exports.exists(name)) continue;
      img.exports.set(name, Std.int(value));
    }
  }

  static function runInitArray(arr:cpp.SizeT, size:Int):Void {
    if (arr == 0 || size <= 0) return;
    var n = Std.int(size / 8);
    for (i in 0...n) {
      var f = JitNative.toSizeT(mpeek(JitNative.toSizeT(JitNative.toFloat(arr) + i * 8), 8));
      if (f != 0) JitNative.callInit(f);
    }
  }

  public static function runFiniArray(img:JitImage):Void {
    if (img.finiArr != 0 && img.finiArrSize > 0) {
      var n = Std.int(img.finiArrSize / 8);
      var i = n - 1;
      while (i >= 0) {
        var f = JitNative.toSizeT(mpeek(JitNative.toSizeT(JitNative.toFloat(img.finiArr) + i * 8), 8));
        if (f != 0) JitNative.callInit(f);
        i--;
      }
    }
    if (img.finiVa != 0) JitNative.callInit(img.finiVa);
  }
  #else
  public static function load(path:String):JitImage {
    var img = new JitImage();
    img.path = path;
    img.error = "manual mapping of ELF images is available on Linux only";
    return img;
  }

  public static function runFiniArray(img:JitImage):Void {}
  #end
}
