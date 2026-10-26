package hxcpp_jit_r;

class JitPtr {
  public var address:Float;

  public function new(address:Float = 0.0) {
    this.address = address;
  }

  public function isNull():Bool {
    return address == 0.0;
  }

  public function offset(delta:Float):JitPtr {
    return new JitPtr(address + delta);
  }

  public function valid():Bool {
    return address != 0.0 && JitNative.isReadable(JitNative.toSizeT(address)) != 0;
  }

  public function readStr(max:Int = 4096):String {
    if (address == 0.0) return "";
    return JitNative.readCStr(JitNative.toSizeT(address), max);
  }

  public function readF64(at:Float = 0.0):Float {
    return address == 0.0 ? 0.0 : JitNative.readF64(JitNative.toSizeT(address + at));
  }

  public function readDouble(at:Float = 0.0):Float {
    return readF64(at);
  }

  public function readF32(at:Float = 0.0):Float {
    return address == 0.0 ? 0.0 : JitNative.readF32(JitNative.toSizeT(address + at));
  }

  public function readI32(at:Float = 0.0):Int {
    return address == 0.0 ? 0 : Std.int(JitNative.peek(JitNative.toSizeT(address + at), 4));
  }

  public function readU16(at:Float = 0.0):Int {
    return address == 0.0 ? 0 : Std.int(JitNative.peek(JitNative.toSizeT(address + at), 2));
  }

  public function readU8(at:Float = 0.0):Int {
    return address == 0.0 ? 0 : Std.int(JitNative.peek(JitNative.toSizeT(address + at), 1));
  }

  public function writeF64(v:Float, at:Float = 0.0):Bool {
    if (address == 0.0) return false;
    JitNative.writeF64(JitNative.toSizeT(address + at), v);
    return true;
  }

  public function writeF32(v:Float, at:Float = 0.0):Bool {
    if (address == 0.0) return false;
    JitNative.writeF32(JitNative.toSizeT(address + at), v);
    return true;
  }

  public function writeI32(v:Int, at:Float = 0.0):Bool {
    if (address == 0.0) return false;
    JitNative.poke(JitNative.toSizeT(address + at), 4, v * 1.0);
    return true;
  }

  public function readBytes(len:Int, at:Float = 0.0):haxe.io.Bytes {
    if (address == 0.0 || len <= 0) return null;
    var b = haxe.io.Bytes.alloc(len);
    JitNative.copyOut(JitNative.toSizeT(address + at), b, len);
    return b;
  }

  public function writeBytes(b:haxe.io.Bytes, at:Float = 0.0):Bool {
    if (address == 0.0 || b == null) return false;
    JitNative.copyIn(JitNative.toSizeT(address + at), b, b.length);
    return true;
  }

  public function toString():String {
    return "JitPtr(0x" + StringTools.hex(Std.int(address), 12) + ")";
  }

  public static function of(v:Float):JitPtr {
    return new JitPtr(v);
  }
}
