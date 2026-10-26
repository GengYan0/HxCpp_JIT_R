package hxcpp_jit_r;

#if macro
import haxe.macro.Expr;

class JitMacro {
  public static function auto():Expr {
    haxe.macro.Compiler.include("hxcpp_jit_r");
    return macro null;
  }

  public static function probe():Expr {
    haxe.macro.Compiler.define("jit_selftest");
    haxe.macro.Compiler.include("hxcpp_jit_r");
    return macro null;
  }
}
#end
