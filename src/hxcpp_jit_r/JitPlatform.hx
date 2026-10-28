package hxcpp_jit_r;

class JitPlatform {
  public static var win(default, null):Bool = Sys.systemName() == "Windows";
}
