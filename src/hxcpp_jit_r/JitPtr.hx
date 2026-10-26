package hxcpp_jit_r;

class JitPtr {
  public var address:Float;

  public function new(address:Float = 0.0) {
    this.address = address;
  }

  public function isNull():Bool {
    return address == 0.0;
  }

  public function toString():String {
    return "JitPtr(0x" + StringTools.hex(Std.int(address), 12) + ")";
  }

  public static function of(v:Float):JitPtr {
    return new JitPtr(v);
  }
}
