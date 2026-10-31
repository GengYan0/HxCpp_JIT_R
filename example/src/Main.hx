import hxcpp_jit_r.Jit;

class Main {
  static function main():Void {
    var m = Jit.compile("demo", '
struct Point { double x; double y; };
Point origin;
double mul(double a, double b) { return a * b; }
int len(const char* s) { int n = 0; while (s[n] != 0) n++; return n; }
int twice(int v) { return v * 2; }
std::string greet(std::string who) { return "hello, " + who; }
long long big(long long v) { return v * 1000000000LL; }
double apply(double (*f)(double), double v) { return f(v); }
');
    if (!m.ok) {
      Sys.println(m.report());
      return;
    }

    Sys.println("mul: " + m.callAuto("mul", [3, 4]));
    Sys.println("len: " + m.callAuto("len", [], ["hello"]));
    Sys.println("twice: " + m.callAuto("twice", [21]));
    m.set("origin.x", 2);
    Sys.println("origin.x: " + m.get("origin.x"));
    Sys.println("expr: " + m.expr("origin.x * 10"));
    Sys.println("signature of twice: " + m.signature("twice"));

    Sys.println("greet: " + m.callStr("greet", [], ["world"]));
    Sys.println("big: " + m.callWide("big", [haxe.Int64.ofInt(7)]));

    Jit.bind("triple", function(a0:Float, a1:Float, a2:Float, a3:Float):Float return a0 * 3);
    var fnPtr = Jit.callback("triple", "d(d)");
    Sys.println("apply(triple, 14): " + m.callAuto("apply", [fnPtr, 14]));
  }
}
