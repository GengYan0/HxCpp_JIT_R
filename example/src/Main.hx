import hxcpp_jit_r.Jit;

class Main {
  static function main():Void {
    var m = Jit.compile("demo", '
struct Point { double x; double y; };
Point origin;
double mul(double a, double b) { return a * b; }
int len(const char* s) { int n = 0; while (s[n] != 0) n++; return n; }
int twice(int v) { return v * 2; }
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
  }
}
