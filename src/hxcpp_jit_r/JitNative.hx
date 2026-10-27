package hxcpp_jit_r;

@:cppFileCode('
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#include <sys/mman.h>
#endif
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
static double rjit_nan(void) {
  unsigned long long bits = 0x7FF8000000000000ULL;
  double d;
  memcpy(&d, &bits, sizeof(d));
  return d;
}

static double rjit_guard2(double (*fn)(RJitCtx*, RJitArgs*), RJitCtx* c, RJitArgs* a) {
  __try {
    return fn(c, a);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return rjit_nan();
  }
}

static double rjit_guard3(double (*fn)(RJitCtx*, void*, RJitArgs*), RJitCtx* c, void* f, RJitArgs* a) {
  __try {
    return fn(c, f, a);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return rjit_nan();
  }
}

static int rjit_entry_fault = 0;

static int rjit_guard_entry(void* entry, void* hinst, unsigned long reason, void* reserved) {
  typedef int (__stdcall *RJitEntry)(void*, unsigned long, void*);
  RJitEntry e = (RJitEntry)entry;
  rjit_entry_fault = 0;
  __try {
    return e(hinst, reason, reserved);
  } __except (rjit_entry_fault = (int)GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) {
    return -1;
  }
}
#endif

struct RJitTlsDef { size_t size; const void* init; size_t initSize; };
static RJitTlsDef rjit_tls_defs[32];
static int rjit_tls_n = 0;
struct RJitTlsHolder {
  void* p[32];
  RJitTlsHolder() { memset(p, 0, sizeof(p)); }
  ~RJitTlsHolder() { for (int i = 0; i < 32; i++) if (p[i] != 0) free(p[i]); }
};
static thread_local RJitTlsHolder rjit_tls_holder;

extern "C" void* rjit_tls_get(void* idx) {
  size_t* p = (size_t*)idx;
  size_t m = p[0];
  size_t off = p[1];
  if (m == 0 || m > (size_t)rjit_tls_n) return 0;
  size_t k = m - 1;
  void* b = rjit_tls_holder.p[k];
  if (b == 0) {
    size_t sz = rjit_tls_defs[k].size;
    if (sz == 0) sz = 1;
    b = malloc(sz + 16);
    if (b == 0) return 0;
    memset(b, 0, sz + 16);
    if (rjit_tls_defs[k].init != 0 && rjit_tls_defs[k].initSize > 0) memcpy(b, rjit_tls_defs[k].init, rjit_tls_defs[k].initSize);
    rjit_tls_holder.p[k] = b;
  }
  return (void*)((char*)b + off);
}

static int rjit_tls_register(size_t size, const void* init, size_t initSize) {
  if (rjit_tls_n >= 32) return 0;
  int k = rjit_tls_n++;
  rjit_tls_defs[k].size = size;
  rjit_tls_defs[k].init = init;
  rjit_tls_defs[k].initSize = initSize;
  return k + 1;
}
')
@:headerCode('
#ifndef RJIT_ABI_HOST
#define RJIT_ABI_HOST

struct RJitCtx;

struct RJitHost {
  void*  (*alloc)(void* m, int n);
  void   (*dealloc)(void* m, void* p);
  void   (*log)(void* m, const char* s, int len);
  double (*call)(void* m, const char* name, int len, double a0, double a1, double a2, double a3);
  void   (*retstr)(void* m, const char* s, int len);
  void   (*retstr2)(void* m, const char* s, int len);
  double (*get)(void* m, const char* key, int len);
};

struct RJitCtx {
  int abi;
  int pad;
  RJitHost* h;
  void* m;
};

struct RJitArgs {
  int n;
  int sn;
  double a[6];
  const char* s[4];
  int sl[4];
};

typedef double (*RJitFn)(RJitCtx*, RJitArgs*);

#endif
')
class JitNative {
  public static function onLog(id:Int, s:String):Void {
    JitHost.onLog(id, s);
  }

  public static function onCall(id:Int, name:String, a0:Float, a1:Float, a2:Float, a3:Float):Float {
    return JitHost.onCall(id, name, a0, a1, a2, a3);
  }

  public static function onRetStr(id:Int, s:String):Void {
    JitHost.onRetStr(id, s);
  }

  public static function onRetStr2(id:Int, s:String):Void {
    JitHost.onRetStr2(id, s);
  }

  public static function onGet(id:Int, key:String):Float {
    return JitHost.onGet(id, key);
  }

  @:functionCode('
    static RJitHost table;
    static bool tableInit = false;
    if (!tableInit) {
      tableInit = true;
      table.alloc = [](void* m, int n) -> void* { return malloc((size_t)n); };
      table.dealloc = [](void* m, void* p) { free(p); };
      table.log = [](void* m, const char* s, int len) { ::hxcpp_jit_r::JitNative_obj::onLog((int)(size_t)m, ::String::create(s, len)); };
      table.call = [](void* m, const char* n, int len, double a0, double a1, double a2, double a3) -> double {
        return ::hxcpp_jit_r::JitNative_obj::onCall((int)(size_t)m, ::String::create(n, len), a0, a1, a2, a3);
      };
      table.retstr = [](void* m, const char* s, int len) { ::hxcpp_jit_r::JitNative_obj::onRetStr((int)(size_t)m, ::String::create(s, len)); };
      table.retstr2 = [](void* m, const char* s, int len) { ::hxcpp_jit_r::JitNative_obj::onRetStr2((int)(size_t)m, ::String::create(s, len)); };
      table.get = [](void* m, const char* k, int len) -> double { return ::hxcpp_jit_r::JitNative_obj::onGet((int)(size_t)m, ::String::create(k, len)); };
    }
    RJitCtx* c = (RJitCtx*)malloc(sizeof(RJitCtx));
    if (c == 0) return (size_t)0;
    c->abi = abi;
    c->pad = 0;
    c->h = &table;
    c->m = (void*)(size_t)modId;
    return (size_t)c;
  ')
  public static function mkctx(modId:Int, abi:Int = 5):cpp.SizeT return 0;

  @:functionCode('free((void*)ctx);')
  public static function freeCtx(ctx:cpp.SizeT):Void {}

  @:functionCode('
#ifdef _WIN32
    return (size_t)LoadLibraryW(path.wchar_str());
#else
    return (size_t)dlopen(path.utf8_str(), 0x00002 | 0x00100);
#endif
  ')
  public static function loadDll(path:String):cpp.SizeT return 0;

  @:functionCode('\n#ifdef _WIN32\n    return (size_t)LoadLibraryA(path.utf8_str());\n#else\n    return (size_t)dlopen(path.utf8_str(), 0x00002 | 0x00100);\n#endif\n  ')
  public static function loadLibA(path:String):cpp.SizeT return 0;

  @:functionCode('
#ifdef _WIN32
    return FreeLibrary((HMODULE)h) ? 1 : 0;
#else
    return dlclose((void*)h) == 0 ? 1 : 0;
#endif
  ')
  public static function unloadDll(h:cpp.SizeT):Int return 0;

  @:functionCode('
#ifdef _WIN32
    return (size_t)GetProcAddress((HMODULE)h, name.utf8_str());
#else
    return (size_t)dlsym((void*)h, name.utf8_str());
#endif
  ')
  public static function getProc(h:cpp.SizeT, name:String):cpp.SizeT return 0;

  @:functionCode('
#ifdef _WIN32
    return (size_t)GetProcAddress((HMODULE)h, name);
#else
    return (size_t)dlsym((void*)h, name);
#endif
  ')
  public static function getProcA(h:cpp.SizeT, name:cpp.ConstCharStar):cpp.SizeT return 0;

  @:functionCode('
#ifdef _WIN32
    HMODULE m = GetModuleHandleW(name.wchar_str());
    if (m == 0) m = LoadLibraryW(name.wchar_str());
    return (size_t)m;
#else
    return (size_t)dlopen(name.utf8_str(), 0x00002 | 0x00100);
#endif
  ')
  public static function moduleOf(name:String):cpp.SizeT return 0;

  @:functionCode('
    RJitArgs a;
    memset(&a, 0, sizeof(a));
    a.n = n;
    a.a[0] = a0;
    a.a[1] = a1;
    a.a[2] = a2;
    a.a[3] = a3;
    a.a[4] = a4;
    a.a[5] = a5;
#ifdef _WIN32
    return rjit_guard2(reinterpret_cast<double(*)(RJitCtx*,RJitArgs*)>(fn), reinterpret_cast<RJitCtx*>(ctx), &a);
#else
    return reinterpret_cast<RJitFn>(fn)(reinterpret_cast<RJitCtx*>(ctx), &a);
#endif
  ')
  public static function invoke(fn:cpp.SizeT, ctx:cpp.SizeT, n:Int, a0:Float, a1:Float, a2:Float, a3:Float, a4:Float, a5:Float):Float return 0;

  @:functionCode('
    RJitArgs a;
    memset(&a, 0, sizeof(a));
    a.n = n;
    a.a[0] = a0;
    a.a[1] = a1;
    a.a[2] = a2;
    a.a[3] = a3;
    a.a[4] = a4;
    a.a[5] = a5;
    const unsigned char* q0 = (b0.mPtr != 0) ? b0->b->Pointer() : 0;
    const unsigned char* q1 = (b1.mPtr != 0) ? b1->b->Pointer() : 0;
    const unsigned char* q2 = (b2.mPtr != 0) ? b2->b->Pointer() : 0;
    const unsigned char* q3 = (b3.mPtr != 0) ? b3->b->Pointer() : 0;
    a.sn = 0;
    if (q0 != 0) { a.s[0] = (const char*)q0; a.sl[0] = b0->length; a.sn = 1; }
    if (q1 != 0) { a.s[1] = (const char*)q1; a.sl[1] = b1->length; a.sn = 2; }
    if (q2 != 0) { a.s[2] = (const char*)q2; a.sl[2] = b2->length; a.sn = 3; }
    if (q3 != 0) { a.s[3] = (const char*)q3; a.sl[3] = b3->length; a.sn = 4; }
#ifdef _WIN32
    return rjit_guard2(reinterpret_cast<double(*)(RJitCtx*,RJitArgs*)>(fn), reinterpret_cast<RJitCtx*>(ctx), &a);
#else
    return reinterpret_cast<RJitFn>(fn)(reinterpret_cast<RJitCtx*>(ctx), &a);
#endif
  ')
  public static function invokeB(fn:cpp.SizeT, ctx:cpp.SizeT, n:Int, a0:Float, a1:Float, a2:Float, a3:Float, a4:Float, a5:Float,
    b0:haxe.io.Bytes, b1:haxe.io.Bytes, b2:haxe.io.Bytes, b3:haxe.io.Bytes):Float return 0;

  @:functionCode('
#ifdef _WIN32
    return (int)GetLastError();
#else
    return 0;
#endif
  ')
  public static function lastError():Int return 0;

  @:functionCode('
#ifdef _WIN32
    wchar_t buf[512];
    DWORD n = FormatMessageW(0x00001000 | 0x00000800, 0, (DWORD)code, 0, buf, 512, 0);
    if (n == 0) return ::String("");
    while (n > 0 && (buf[n - 1] == 10 || buf[n - 1] == 13 || buf[n - 1] == 32)) n--;
    buf[n] = 0;
    return ::String(buf);
#else
    const char* e = dlerror();
    return e == 0 ? ::String("") : ::String(e);
#endif
  ')
  public static function errorText(code:Int):String return "";

  @:functionCode('
    RJitArgs a;
    memset(&a, 0, sizeof(a));
    a.n = n;
    a.a[0] = a0;
    a.a[1] = a1;
    a.a[2] = a2;
    a.a[3] = a3;
    a.a[4] = a4;
    a.a[5] = a5;
    double addr = 0.0;
#ifdef _WIN32
    addr = rjit_guard2(reinterpret_cast<double(*)(RJitCtx*,RJitArgs*)>(ptrFn), reinterpret_cast<RJitCtx*>(ctx), &a);
    if (addr != addr) return addr;
    return rjit_guard3(reinterpret_cast<double(*)(RJitCtx*,void*,RJitArgs*)>(disp), reinterpret_cast<RJitCtx*>(ctx), (void*)(size_t)addr, &a);
#else
    addr = reinterpret_cast<double(*)(RJitCtx*,RJitArgs*)>(ptrFn)(reinterpret_cast<RJitCtx*>(ctx), &a);
    return reinterpret_cast<double(*)(RJitCtx*,void*,RJitArgs*)>(disp)(reinterpret_cast<RJitCtx*>(ctx), (void*)(size_t)addr, &a);
#endif
  ')
  public static function callVia(disp:cpp.SizeT, ptrFn:cpp.SizeT, ctx:cpp.SizeT, n:Int, a0:Float, a1:Float, a2:Float, a3:Float, a4:Float, a5:Float):Float return 0;

  @:functionCode('
    RJitArgs a;
    memset(&a, 0, sizeof(a));
    a.n = n;
    a.a[0] = a0;
    a.a[1] = a1;
    a.a[2] = a2;
    a.a[3] = a3;
    a.a[4] = a4;
    a.a[5] = a5;
    const unsigned char* q0 = (b0.mPtr != 0) ? b0->b->Pointer() : 0;
    const unsigned char* q1 = (b1.mPtr != 0) ? b1->b->Pointer() : 0;
    const unsigned char* q2 = (b2.mPtr != 0) ? b2->b->Pointer() : 0;
    const unsigned char* q3 = (b3.mPtr != 0) ? b3->b->Pointer() : 0;
    a.sn = 0;
    if (q0 != 0) { a.s[0] = (const char*)q0; a.sl[0] = b0->length; a.sn = 1; }
    if (q1 != 0) { a.s[1] = (const char*)q1; a.sl[1] = b1->length; a.sn = 2; }
    if (q2 != 0) { a.s[2] = (const char*)q2; a.sl[2] = b2->length; a.sn = 3; }
    if (q3 != 0) { a.s[3] = (const char*)q3; a.sl[3] = b3->length; a.sn = 4; }
    double addr = 0.0;
#ifdef _WIN32
    addr = rjit_guard2(reinterpret_cast<double(*)(RJitCtx*,RJitArgs*)>(ptrFn), reinterpret_cast<RJitCtx*>(ctx), &a);
    if (addr != addr) return addr;
    return rjit_guard3(reinterpret_cast<double(*)(RJitCtx*,void*,RJitArgs*)>(disp), reinterpret_cast<RJitCtx*>(ctx), (void*)(size_t)addr, &a);
#else
    addr = reinterpret_cast<double(*)(RJitCtx*,RJitArgs*)>(ptrFn)(reinterpret_cast<RJitCtx*>(ctx), &a);
    return reinterpret_cast<double(*)(RJitCtx*,void*,RJitArgs*)>(disp)(reinterpret_cast<RJitCtx*>(ctx), (void*)(size_t)addr, &a);
#endif
  ')
  public static function callViaB(disp:cpp.SizeT, ptrFn:cpp.SizeT, ctx:cpp.SizeT, n:Int, a0:Float, a1:Float, a2:Float, a3:Float, a4:Float, a5:Float,
    b0:haxe.io.Bytes, b1:haxe.io.Bytes, b2:haxe.io.Bytes, b3:haxe.io.Bytes):Float return 0;

  @:functionCode('
#ifdef _WIN32
    return (int)GetACP();
#else
    return 65001;
#endif
  ')
  public static function getACP():Int return 936;

  @:functionCode('
    if (len <= 0 || src == 0) return;
    int cap = bytes->length;
    int n = len > cap ? cap : len;
    memcpy(bytes->b->Pointer(), (const void*)(size_t)src, (size_t)n);
  ')
  public static function copyOut(src:cpp.SizeT, bytes:haxe.io.Bytes, len:Int):Void {}

  @:functionCode('
    if (len <= 0 || dst == 0) return;
    int cap = bytes->length;
    int n = len > cap ? cap : len;
    memcpy((void*)(size_t)dst, bytes->b->Pointer(), (size_t)n);
  ')
  public static function copyIn(dst:cpp.SizeT, bytes:haxe.io.Bytes, len:Int):Void {}

  @:functionCode('
    RJitArgs a;
    memset(&a, 0, sizeof(a));
    a.n = n;
    a.a[0] = a0;
    a.a[1] = a1;
    a.a[2] = a2;
    a.a[3] = a3;
    a.a[4] = a4;
    a.a[5] = a5;
    return reinterpret_cast<RJitFn>(fn)(reinterpret_cast<RJitCtx*>(ctx), &a);
  ')
  public static function invokeFast(fn:cpp.SizeT, ctx:cpp.SizeT, n:Int, a0:Float, a1:Float, a2:Float, a3:Float, a4:Float, a5:Float):Float return 0;

  @:functionCode('return (double)(size_t)v;')
  public static function toFloat(v:cpp.SizeT):Float return 0;

  @:functionCode('return (size_t)v;')
  public static function toSizeT(v:Float):cpp.SizeT return 0;

  @:functionCode('
#ifdef _WIN32
    return (size_t)GetProcAddress((HMODULE)h, (LPCSTR)(size_t)ord);
#else
    return 0;
#endif
  ')
  public static function getProcOrd(h:cpp.SizeT, ord:Int):cpp.SizeT return 0;

  @:functionCode('
#ifdef _WIN32
    return (size_t)GetProcAddress((HMODULE)h, (LPCSTR)(size_t)namePtr);
#else
    return (size_t)dlsym((void*)h, (const char*)(size_t)namePtr);
#endif
  ')
  public static function getProcAt(h:cpp.SizeT, namePtr:cpp.SizeT):cpp.SizeT return 0;

  @:functionCode('
  long long d = (long long)delta;
  if (ty == 10) {
    unsigned long long cur = *(volatile unsigned long long*)(size_t)p;
    *(volatile unsigned long long*)(size_t)p = cur + (unsigned long long)d;
  } else if (ty == 3) {
    unsigned int cur = *(volatile unsigned int*)(size_t)p;
    *(volatile unsigned int*)(size_t)p = cur + (unsigned int)d;
  } else if (ty == 2) {
    unsigned short cur = *(volatile unsigned short*)(size_t)p;
    *(volatile unsigned short*)(size_t)p = (unsigned short)(cur + (unsigned short)((unsigned long long)d & 0xFFFF));
  } else if (ty == 1) {
    unsigned short cur = *(volatile unsigned short*)(size_t)p;
    *(volatile unsigned short*)(size_t)p = (unsigned short)(cur + (unsigned short)(((unsigned long long)d >> 16) & 0xFFFF));
  }
  ')
  public static function addRel(p:cpp.SizeT, delta:Float, ty:Int):Void {}

  @:functionCode('
#ifdef _WIN32
    DWORD idx = TlsAlloc();
    if (idx == 0xFFFFFFFF) return -1;
    *(volatile unsigned int*)(size_t)indexVa = (unsigned int)idx;
    size_t dataSize = (size_t)endVa > (size_t)startVa ? (size_t)endVa - (size_t)startVa : 0;
    size_t total = dataSize + (size_t)zeroFill;
    if (total == 0) total = 1;
    void* block = calloc(1, total);
    if (block == 0) { TlsFree(idx); return -1; }
    if (dataSize > 0) memcpy(block, (const void*)(size_t)startVa, dataSize);
    if (!TlsSetValue(idx, block)) { free(block); TlsFree(idx); return -1; }
    return (int)idx;
#else
    return -1;
#endif
  ')
  public static function setupTls(indexVa:cpp.SizeT, startVa:cpp.SizeT, endVa:cpp.SizeT, zeroFill:Int):Int return -1;

  @:functionCode('
#ifdef _WIN32
    size_t dataSize = (size_t)endVa > (size_t)startVa ? (size_t)endVa - (size_t)startVa : 0;
    size_t total = dataSize + (size_t)zeroFill;
    if (total == 0) total = 1;
    void* block = calloc(1, total);
    if (block == 0) return 0;
    if (dataSize > 0) memcpy(block, (const void*)(size_t)startVa, dataSize);
    if (!TlsSetValue((DWORD)idx, block)) { free(block); return 0; }
    return 1;
#else
    return 0;
#endif
  ')
  public static function bindTlsBlock(idx:Int, startVa:cpp.SizeT, endVa:cpp.SizeT, zeroFill:Int):Int return 0;

  @:functionCode('
#ifdef _WIN32
    void* block = TlsGetValue((DWORD)idx);
    if (block != 0) free(block);
    TlsSetValue((DWORD)idx, 0);
    TlsFree((DWORD)idx);
#endif
  ')
  public static function clearTls(idx:Int):Void {}

  @:functionCode('
    int n = bytes->length;
    if (n <= 0) return ::String("");
#ifndef _WIN32
    return bytes->toString();
#endif
    if (n < 0) return ::String("");
    const char* src = (const char*)bytes->b->Pointer();
    if (src == 0) return ::String("");
    int wl = MultiByteToWideChar((UINT)cp, 0, src, n, 0, 0);
    if (wl <= 0) return ::String("");
    wchar_t* wb = (wchar_t*)malloc(((size_t)wl + 1) * sizeof(wchar_t));
    if (wb == 0) return ::String("");
    MultiByteToWideChar((UINT)cp, 0, src, n, wb, wl);
    wb[wl] = 0;
    int ul = WideCharToMultiByte(65001, 0, wb, wl, 0, 0, 0, 0);
    if (ul <= 0) { free(wb); return ::String(""); }
    char* ub = (char*)malloc((size_t)ul + 1);
    if (ub == 0) { free(wb); return ::String(""); }
    WideCharToMultiByte(65001, 0, wb, wl, ub, ul, 0, 0);
    ub[ul] = 0;
    ::String r = ::String::create(ub, ul);
    free(wb);
    free(ub);
    return r;
  ')
  public static function decode(bytes:haxe.io.Bytes, cp:Int):String return "";

  @:functionCode('
#ifdef _WIN32
    return (size_t)VirtualAlloc((void*)(size_t)want, (SIZE_T)size, 0x00003000, 0x40);
#else
    void* p = mmap((void*)(size_t)want, (size_t)size, 7, 0x22, -1, 0);
    return p == (void*)-1 ? (size_t)0 : (size_t)p;
#endif
  ')
  public static function valloc(want:cpp.SizeT, size:Int):cpp.SizeT return 0;

  @:functionCode('
#ifdef _WIN32
    return VirtualFree((void*)(size_t)p, 0, 0x00008000) ? 1 : 0;
#else
    return munmap((void*)(size_t)p, (size_t)size) == 0 ? 1 : 0;
#endif
  ')
  public static function vfree(p:cpp.SizeT, size:Int):Int return 0;

  @:functionCode('
#ifdef _WIN32
    DWORD old = 0;
    if (!VirtualProtect((void*)(size_t)p, (SIZE_T)size, (DWORD)prot, &old)) return -1;
    return (int)old;
#else
    int q = 0;
    if ((prot & 0x04) != 0) q = 7; else if ((prot & 0x02) != 0) q = 5; else q = 1;
    if (mprotect((void*)(size_t)p, (size_t)size, q) != 0) return -1;
    return 0;
#endif
  ')
  public static function vprotect(p:cpp.SizeT, size:Int, prot:Int):Int return 0;

  @:functionCode('memcpy((void*)(size_t)dst, (const void*)(size_t)src, (size_t)len);')
  public static function memcpyRaw(dst:cpp.SizeT, src:cpp.SizeT, len:Int):Void {}

  @:functionCode('
    if (p == 0) return ::String("");
    const char* s = (const char*)(size_t)p;
    int n = 0;
    while (n < max && s[n] != 0) n++;
    return ::String::create(s, n);
  ')
  public static function readCStr(p:cpp.SizeT, max:Int = 4096):String return null;

  @:functionCode('if (p != 0 && len > 0) memset((void*)(size_t)p, 0, (size_t)len);')
  public static function memzero(p:cpp.SizeT, len:Int):Void {}

  @:functionCode('((void(*)(int,void*,void*))(size_t)f)(0, 0, 0); return 0.0;')
  public static function callInit(f:cpp.SizeT):Float return 0;

  @:functionCode('return (size_t)&rjit_tls_get;')
  public static function tlsAddr():cpp.SizeT return 0;

  @:functionCode('return (int)rjit_tls_register((size_t)size, (const void*)(size_t)init, (size_t)initSize);')
  public static function tlsRegister(size:Int, init:cpp.SizeT, initSize:Int):Int return 0;

  @:functionCode('
    size_t idx[2];
    idx[0] = (size_t)id;
    idx[1] = 0;
    return (size_t)rjit_tls_get(idx);
  ')
  public static function tlsBlock(id:Int):cpp.SizeT return 0;

  @:functionCode('
#ifdef _WIN32
    return 0;
#else
    return (size_t)dlsym((void*)0, name.utf8_str());
#endif
  ')
  public static function getProcGlobal(name:String):cpp.SizeT return 0;

  @:functionCode('
#ifdef _WIN32
    FlushInstructionCache(GetCurrentProcess(), (const void*)(size_t)p, (SIZE_T)size);
#endif
  ')
  public static function flushIcache(p:cpp.SizeT, size:Int):Void {}

  @:functionCode('
    if (w <= 1) return (double)*(volatile unsigned char*)(size_t)p;
    if (w == 2) return (double)*(volatile unsigned short*)(size_t)p;
    if (w == 4) return (double)*(volatile unsigned int*)(size_t)p;
    return (double)*(volatile unsigned long long*)(size_t)p;
  ')
  public static function peek(p:cpp.SizeT, w:Int):Float return 0;

  @:functionCode('return *(volatile double*)(size_t)p;')
  public static function readF64(p:cpp.SizeT):Float return 0;

  @:functionCode('*(volatile double*)(size_t)p = v;')
  public static function writeF64(p:cpp.SizeT, v:Float):Void {}

  @:functionCode('return *(volatile float*)(size_t)p;')
  public static function readF32(p:cpp.SizeT):Float return 0;

  @:functionCode('*(volatile float*)(size_t)p = (float)v;')
  public static function writeF32(p:cpp.SizeT, v:Float):Void {}

  @:functionCode('
    if (w <= 1) { *(volatile unsigned char*)(size_t)p = (unsigned char)v; return; }
    if (w == 2) { *(volatile unsigned short*)(size_t)p = (unsigned short)v; return; }
    if (w == 4) { *(volatile unsigned int*)(size_t)p = (unsigned int)v; return; }
    *(volatile unsigned long long*)(size_t)p = (unsigned long long)v;
  ')
  public static function poke(p:cpp.SizeT, w:Int, v:Float):Void {}

  @:functionCode('
    unsigned long long cur = *(volatile unsigned long long*)(size_t)p;
    *(volatile unsigned long long*)(size_t)p = cur + (unsigned long long)delta;
  ')
  public static function add64(p:cpp.SizeT, delta:Float):Void {}

  @:functionCode('
    unsigned int cur = *(volatile unsigned int*)(size_t)p;
    *(volatile unsigned int*)(size_t)p = cur + (unsigned int)delta;
  ')
  public static function add32(p:cpp.SizeT, delta:Int):Void {}

  @:functionCode('
    unsigned short cur = *(volatile unsigned short*)(size_t)p;
    *(volatile unsigned short*)(size_t)p = (unsigned short)(cur + (unsigned short)(((unsigned int)delta) >> 16));
  ')
  public static function addHigh16(p:cpp.SizeT, delta:Int):Void {}

  @:functionCode('
#ifdef _WIN32
    typedef unsigned char (WINAPI *RJitAddFn)(void*, unsigned long, unsigned long long);
    static RJitAddFn cached = 0;
    static bool looked = false;
    if (!looked) {
      looked = true;
      HMODULE m = GetModuleHandleA("kernel32.dll");
      if (m == 0) m = LoadLibraryA("kernel32.dll");
      if (m != 0) cached = (RJitAddFn)GetProcAddress(m, "RtlAddFunctionTable");
      if (cached == 0) {
        HMODULE n = GetModuleHandleA("ntdll.dll");
        if (n != 0) cached = (RJitAddFn)GetProcAddress(n, "RtlAddFunctionTable");
      }
    }
    if (cached == 0) return 0;
    return cached((void*)(size_t)table, (unsigned long)count, (unsigned long long)(size_t)base) ? 1 : 0;
#else
    return 0;
#endif
  ')
  public static function addFnTable(table:cpp.SizeT, count:Int, base:cpp.SizeT):Int return 0;

  @:functionCode('
#ifdef _WIN32
    typedef unsigned char (WINAPI *RJitDelFn)(void*);
    static RJitDelFn cached = 0;
    static bool looked = false;
    if (!looked) {
      looked = true;
      HMODULE m = GetModuleHandleA("kernel32.dll");
      if (m == 0) m = LoadLibraryA("kernel32.dll");
      if (m != 0) cached = (RJitDelFn)GetProcAddress(m, "RtlDeleteFunctionTable");
      if (cached == 0) {
        HMODULE n = GetModuleHandleA("ntdll.dll");
        if (n != 0) cached = (RJitDelFn)GetProcAddress(n, "RtlDeleteFunctionTable");
      }
    }
    if (cached == 0) return 0;
    return cached((void*)(size_t)table) ? 1 : 0;
#else
    return 0;
#endif
  ')
  public static function delFnTable(table:cpp.SizeT):Int return 0;

  @:functionCode('
#ifdef _WIN32
    int rc = rjit_guard_entry((void*)(size_t)entry, (void*)(size_t)hinst, (unsigned long)reason, (void*)(size_t)reserved);
    if (rc == -1 && rjit_entry_fault != 0) ::hxcpp_jit_r::JitNative_obj::onEntryFault(rjit_entry_fault);
    return rc;
#else
    typedef int (*RJitEntry)(void*, unsigned long, void*);
    RJitEntry e = (RJitEntry)(size_t)entry;
    return (int)e((void*)(size_t)hinst, (unsigned long)reason, (void*)(size_t)reserved);
#endif
  ')
  public static function callEntry(entry:cpp.SizeT, hinst:cpp.SizeT, reason:Int, reserved:cpp.SizeT):Int return 0;

  public static function onEntryFault(code:Int):Void {
    JitLoader.lastEntryFault = code;
  }

  @:functionCode('
#ifdef _WIN32
    MEMORY_BASIC_INFORMATION mbi;
    if (VirtualQuery((const void*)(size_t)p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != 0x1000) return 0;
    DWORD prot = mbi.Protect & 0xFF;
    if (prot == 0x01 || prot == 0x00) return 0;
    return 1;
#else
    return p != 0 ? 1 : 0;
#endif
  ')
  public static function isReadable(p:cpp.SizeT):Int return 0;

  @:functionCode('
#ifdef _WIN32
    return (size_t)GetModuleHandleA("ntdll.dll");
#else
    return 0;
#endif
  ')
  public static function ntdll():cpp.SizeT return 0;
}
