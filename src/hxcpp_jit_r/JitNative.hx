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
#include <signal.h>
#include <setjmp.h>
#include <sys/mman.h>
#include <unistd.h>
#endif
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <chrono>

static double rjit_nan(void) {
  unsigned long long bits = 0x7FF8000000000000ULL;
  double d;
  memcpy(&d, &bits, sizeof(d));
  return d;
}

#ifdef _WIN32

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

#ifndef _WIN32
#define RJIT_GUARD_DEPTH 8

static thread_local sigjmp_buf rjit_jb[RJIT_GUARD_DEPTH];
static thread_local int rjit_guard_depth = 0;

static void rjit_sig_handler(int sig, siginfo_t* si, void* uc) {
  if (rjit_guard_depth > 0) {
    int d = rjit_guard_depth - 1;
    rjit_guard_depth = d;
    siglongjmp(rjit_jb[d], 1);
  }
  struct sigaction dfl;
  memset(&dfl, 0, sizeof(dfl));
  dfl.sa_handler = SIG_DFL;
  sigaction(sig, &dfl, 0);
  raise(sig);
}

static void rjit_hook(void) {
  static std::once_flag once;
  std::call_once(once, [] {
    static const int sigs[5] = {SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT};
    for (int i = 0; i < 5; i++) {
      struct sigaction sa;
      memset(&sa, 0, sizeof(sa));
      sa.sa_sigaction = rjit_sig_handler;
      sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
      sigemptyset(&sa.sa_mask);
      sigaction(sigs[i], &sa, 0);
    }
  });
}

static double rjit_guard2(double (*fn)(RJitCtx*, RJitArgs*), RJitCtx* c, RJitArgs* a) {
  rjit_hook();
  int saved = rjit_guard_depth;
  if (saved >= RJIT_GUARD_DEPTH) return rjit_nan();
  if (sigsetjmp(rjit_jb[saved], 1) != 0) {
    rjit_guard_depth = saved;
    return rjit_nan();
  }
  rjit_guard_depth = saved + 1;
  double r = fn(c, a);
  rjit_guard_depth = saved;
  return r;
}

static double rjit_guard3(double (*fn)(RJitCtx*, void*, RJitArgs*), RJitCtx* c, void* f, RJitArgs* a) {
  rjit_hook();
  int saved = rjit_guard_depth;
  if (saved >= RJIT_GUARD_DEPTH) return rjit_nan();
  if (sigsetjmp(rjit_jb[saved], 1) != 0) {
    rjit_guard_depth = saved;
    return rjit_nan();
  }
  rjit_guard_depth = saved + 1;
  double r = fn(c, f, a);
  rjit_guard_depth = saved;
  return r;
}
#endif

static RJitHost rjit_host_impl;
static std::once_flag rjit_host_once;
static std::atomic<RJitHost*> rjit_host_table(0);

static void rjit_host_init(void) {
  std::call_once(rjit_host_once, [] {
    rjit_host_impl.alloc = [](void* m, int n) -> void* { return malloc((size_t)n); };
    rjit_host_impl.dealloc = [](void* m, void* p) { free(p); };
    rjit_host_impl.log = [](void* m, const char* s, int len) { ::hxcpp_jit_r::JitNative_obj::onLog((int)(size_t)m, ::String::create(s, len)); };
    rjit_host_impl.call = [](void* m, const char* n, int len, double a0, double a1, double a2, double a3) -> double {
      return ::hxcpp_jit_r::JitNative_obj::onCall((int)(size_t)m, ::String::create(n, len), a0, a1, a2, a3);
    };
    rjit_host_impl.retstr = [](void* m, const char* s, int len) { ::hxcpp_jit_r::JitNative_obj::onRetStr((int)(size_t)m, ::String::create(s, len)); };
    rjit_host_impl.retstr2 = [](void* m, const char* s, int len) { ::hxcpp_jit_r::JitNative_obj::onRetStr2((int)(size_t)m, ::String::create(s, len)); };
    rjit_host_impl.get = [](void* m, const char* k, int len) -> double { return ::hxcpp_jit_r::JitNative_obj::onGet((int)(size_t)m, ::String::create(k, len)); };
    rjit_host_table.store(&rjit_host_impl, std::memory_order_release);
  });
}

struct RJitTlsDef {
  size_t size;
  size_t initSize;
  void* init;
  unsigned gen;
};

static std::mutex rjit_tls_mu;
static RJitTlsDef rjit_tls_defs[32];
static unsigned rjit_tls_gen = 0;

struct RJitTlsHolder {
  void* p[32];
  unsigned gen[32];
  RJitTlsHolder() { memset(p, 0, sizeof(p)); memset(gen, 0, sizeof(gen)); }
  ~RJitTlsHolder() { for (int i = 0; i < 32; i++) if (p[i] != 0) free(p[i]); }
};
static thread_local RJitTlsHolder rjit_tls_holder;

extern "C" void* rjit_tls_get(void* idx) {
  if (idx == 0) return 0;
  size_t* q = (size_t*)idx;
  size_t m = q[0];
  size_t off = q[1];
  if (m == 0) return 0;
  unsigned slot = (unsigned)(m & 0xffu);
  unsigned gen = (unsigned)(m >> 8);
  if (slot == 0 || slot > 32u) return 0;
  slot--;
  RJitTlsHolder& h = rjit_tls_holder;
  if (h.gen[slot] != gen) {
    if (h.p[slot] != 0) {
      free(h.p[slot]);
      h.p[slot] = 0;
    }
    h.gen[slot] = 0;
    size_t sz = 0;
    size_t isz = 0;
    const void* ini = 0;
    {
      std::lock_guard<std::mutex> lk(rjit_tls_mu);
      RJitTlsDef& d = rjit_tls_defs[slot];
      if (d.size == 0 || d.gen != gen) return 0;
      sz = d.size;
      isz = d.initSize;
      ini = d.init;
    }
    void* b = malloc(sz + 16);
    if (b == 0) return 0;
    memset(b, 0, sz + 16);
    if (ini != 0 && isz > 0) memcpy(b, ini, isz > sz ? sz : isz);
    h.p[slot] = b;
    h.gen[slot] = gen;
  }
  return (void*)((char*)h.p[slot] + off);
}

static int rjit_tls_register(size_t size, const void* init, size_t initSize) {
  if (size == 0) size = 1;
  if (initSize > size) initSize = size;
  void* copy = 0;
  if (init != 0 && initSize > 0) {
    copy = malloc(initSize);
    if (copy == 0) return 0;
    memcpy(copy, init, initSize);
  }
  std::lock_guard<std::mutex> lk(rjit_tls_mu);
  int slot = -1;
  for (int i = 0; i < 32; i++) {
    if (rjit_tls_defs[i].size == 0) {
      slot = i;
      break;
    }
  }
  if (slot < 0) {
    free(copy);
    return 0;
  }
  rjit_tls_gen++;
  if (rjit_tls_gen == 0 || rjit_tls_gen > 0xffffffu) rjit_tls_gen = 1;
  RJitTlsDef& d = rjit_tls_defs[slot];
  d.size = size;
  d.initSize = initSize;
  d.init = copy;
  d.gen = rjit_tls_gen;
  return (int)((rjit_tls_gen << 8) | (unsigned)(slot + 1));
}

static void rjit_tls_unregister(int id) {
  if (id <= 0) return;
  unsigned slot = ((unsigned)id & 0xffu);
  unsigned gen = (unsigned)id >> 8;
  if (slot == 0 || slot > 32u) return;
  std::lock_guard<std::mutex> lk(rjit_tls_mu);
  RJitTlsDef& d = rjit_tls_defs[slot - 1];
  if (d.gen != gen) return;
  free(d.init);
  d.init = 0;
  d.initSize = 0;
  d.size = 0;
  d.gen = 0;
}

#ifdef _WIN32
#define RJIT_WIN_TLS_MAX 1100

struct RJitWinTlsSlot {
  std::vector<void*> blocks;
};

static RJitWinTlsSlot rjit_win_tls[RJIT_WIN_TLS_MAX];
static std::mutex rjit_win_tls_mu;

static void rjit_win_tls_track(int idx, void* p) {
  if (idx < 0 || idx >= RJIT_WIN_TLS_MAX || p == 0) return;
  std::lock_guard<std::mutex> lk(rjit_win_tls_mu);
  rjit_win_tls[idx].blocks.push_back(p);
}

static void rjit_win_tls_release(int idx) {
  if (idx < 0 || idx >= RJIT_WIN_TLS_MAX) return;
  std::vector<void*> take;
  {
    std::lock_guard<std::mutex> lk(rjit_win_tls_mu);
    take.swap(rjit_win_tls[idx].blocks);
  }
  for (size_t i = 0; i < take.size(); i++) free(take[i]);
}
#endif

#ifdef _WIN32
#define RJIT_HOST_EXPORT __declspec(dllexport)
#else
#define RJIT_HOST_EXPORT __attribute__((visibility("default")))
#endif

#define RJIT_JOB_MAX 16

struct RJitJob {
  bool active;
  bool taken;
  bool done;
  bool isStr;
  void* m;
  char name[128];
  int len;
  double a0, a1, a2, a3;
  double result;
  char* text;
  int textLen;
  unsigned seq;
};

static RJitJob rjit_jobs[RJIT_JOB_MAX];
static unsigned rjit_job_seq = 0;
static std::mutex rjit_job_mu;
static std::condition_variable rjit_job_done;
static std::atomic<unsigned> rjit_job_timeouts(0);
static std::mutex rjit_timeout_mu;
static char rjit_timeout_name[128] = {0};
static std::thread::id rjit_host_tid;
static std::atomic<bool> rjit_host_set(false);
static std::atomic<int> rjit_wait_ms(2000);
static std::atomic<long long> rjit_job_drops(0);
static char rjit_drop_name[128];
static std::atomic<int> rjit_drop_len(0);

extern "C" RJIT_HOST_EXPORT void rjit_set_host_thread(void) {
  rjit_host_tid = std::this_thread::get_id();
  rjit_host_set.store(true);
}

extern "C" RJIT_HOST_EXPORT void rjit_set_wait(int ms) {
  rjit_wait_ms.store(ms < 1 ? 1 : ms);
}

extern "C" RJIT_HOST_EXPORT int rjit_job_timeouts_total(void) {
  return (int)rjit_job_timeouts.load();
}

extern "C" RJIT_HOST_EXPORT const char* rjit_job_timeout_last(void) {
  static thread_local std::string held;
  std::lock_guard<std::mutex> tl(rjit_timeout_mu);
  held.assign(rjit_timeout_name);
  return held.c_str();
}

static bool rjit_on_host(void) {
  return rjit_host_set.load() && std::this_thread::get_id() == rjit_host_tid;
}

static double rjit_queue(void* m, const char* n, int len, double a0, double a1, double a2, double a3, bool isStr, char** outText, int* outLen) {
  std::unique_lock<std::mutex> lk(rjit_job_mu);
  int idx = -1;
  for (int i = 0; i < RJIT_JOB_MAX; i++) {
    if (!rjit_jobs[i].active) {
      idx = i;
      break;
    }
  }
  if (idx < 0) {
    int dl = len > 127 ? 127 : (len < 0 ? 0 : len);
    if (dl > 0 && n != 0) memcpy(rjit_drop_name, n, (size_t)dl);
    rjit_drop_name[dl] = 0;
    rjit_drop_len.store(dl);
    rjit_job_drops.fetch_add(1);
    return 0.0;
  }
  RJitJob& j = rjit_jobs[idx];
  j.active = true;
  j.taken = false;
  j.done = false;
  j.isStr = isStr;
  j.m = m;
  j.result = 0.0;
  j.text = 0;
  j.textLen = 0;
  j.len = len > 127 ? 127 : len;
  if (j.len < 0) j.len = 0;
  if (n == 0) j.len = 0;
  if (j.len > 0) memcpy(j.name, n, (size_t)j.len);
  j.name[j.len] = 0;
  j.a0 = a0;
  j.a1 = a1;
  j.a2 = a2;
  j.a3 = a3;
  unsigned mine = ++rjit_job_seq;
  j.seq = mine;
  bool ok = rjit_job_done.wait_for(lk, std::chrono::milliseconds(rjit_wait_ms.load()), [&] { return j.done && j.seq == mine; });
  if (!ok) {
    rjit_job_timeouts.fetch_add(1);
    std::lock_guard<std::mutex> tl(rjit_timeout_mu);
    memcpy(rjit_timeout_name, j.name, (size_t)j.len + 1);
  }
  double r = 0.0;
  if (ok) {
    r = j.result;
    if (isStr && outText != 0 && j.text != 0) {
      *outText = j.text;
      *outLen = j.textLen;
      j.text = 0;
    }
  }
  if (j.text != 0) {
    free(j.text);
    j.text = 0;
  }
  j.active = false;
  j.done = false;
  lk.unlock();
  rjit_job_done.notify_all();
  return r;
}

extern "C" RJIT_HOST_EXPORT void rjit_pump(void) {
  rjit_host_tid = std::this_thread::get_id();
  rjit_host_set.store(true);
  if (rjit_host_table.load(std::memory_order_acquire) == 0) return;
  for (int round = 0; round < RJIT_JOB_MAX; round++) {
    int idx = -1;
    unsigned seq = 0;
    bool isStr = false;
    void* m = 0;
    char name[128];
    int len = 0;
    double a0 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0;
    {
      std::lock_guard<std::mutex> lk(rjit_job_mu);
      for (int i = 0; i < RJIT_JOB_MAX; i++) {
        if (rjit_jobs[i].active && !rjit_jobs[i].taken) {
          idx = i;
          RJitJob& s = rjit_jobs[i];
          s.taken = true;
          seq = s.seq;
          isStr = s.isStr;
          m = s.m;
          len = s.len;
          if (len > 0) memcpy(name, s.name, (size_t)len);
          name[len] = 0;
          a0 = s.a0;
          a1 = s.a1;
          a2 = s.a2;
          a3 = s.a3;
          break;
        }
      }
    }
    if (idx < 0) return;
    RJitJob& j = rjit_jobs[idx];
    double r = 0.0;
    char* text = 0;
    int textLen = 0;
    if (isStr) {
      ::String s = ::hxcpp_jit_r::JitNative_obj::onCallStr((int)(size_t)m, ::String::create(name, len), a0, a1, a2, a3);
      const char* u = s.utf8_str();
      size_t ul = u == 0 ? 0 : strlen(u);
      textLen = (int)ul;
      text = (char*)malloc(ul + 1);
      if (text != 0) {
        if (ul > 0) memcpy(text, u, ul);
        text[ul] = 0;
      }
    } else {
      r = ::hxcpp_jit_r::JitNative_obj::onCall((int)(size_t)m, ::String::create(name, len), a0, a1, a2, a3);
    }
    {
      std::lock_guard<std::mutex> lk(rjit_job_mu);
      if (j.active && j.seq == seq) {
        j.result = r;
        j.text = text;
        j.textLen = textLen;
        j.done = true;
        text = 0;
      }
    }
    if (text != 0) free(text);
    rjit_job_done.notify_all();
  }
}

extern "C" RJIT_HOST_EXPORT double rjit_host_call(void* m, const char* n, int len, double a0, double a1, double a2, double a3) {
  RJitHost* t = rjit_host_table.load(std::memory_order_acquire);
  if (t == 0) return 0.0;
  if (rjit_on_host()) return t->call(m, n, len, a0, a1, a2, a3);
  return rjit_queue(m, n, len, a0, a1, a2, a3, false, 0, 0);
}

extern "C" RJIT_HOST_EXPORT const char* rjit_host_str(void* m, const char* n, int len, double a0, double a1, double a2, double a3) {
  static thread_local std::string held;
  held.clear();
  RJitHost* t = rjit_host_table.load(std::memory_order_acquire);
  if (t == 0) return held.c_str();
  if (rjit_on_host()) {
    ::String s = ::hxcpp_jit_r::JitNative_obj::onCallStr((int)(size_t)m, ::String::create(n, len), a0, a1, a2, a3);
    const char* u = s.utf8_str();
    if (u != 0) held.assign(u);
    return held.c_str();
  }
  char* text = 0;
  int textLen = 0;
  rjit_queue(m, n, len, a0, a1, a2, a3, true, &text, &textLen);
  if (text != 0) {
    if (textLen > 0) held.assign(text, (size_t)textLen);
    free(text);
  }
  return held.c_str();
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

  public static function onCallStr(id:Int, name:String, a0:Float, a1:Float, a2:Float, a3:Float):String {
    return JitHost.onCallStr(id, name, a0, a1, a2, a3);
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
    rjit_host_init();
    RJitCtx* c = (RJitCtx*)malloc(sizeof(RJitCtx));
    if (c == 0) return (size_t)0;
    c->abi = abi;
    c->pad = 0;
    c->h = &rjit_host_impl;
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
    return rjit_guard2(reinterpret_cast<double(*)(RJitCtx*,RJitArgs*)>(fn), reinterpret_cast<RJitCtx*>(ctx), &a);
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
    if (q0 != 0) { a.s[0] = (const char*)q0; a.sl[0] = b0->length > 0 ? b0->length - 1 : 0; a.sn = 1; }
    if (q1 != 0) { a.s[1] = (const char*)q1; a.sl[1] = b1->length > 0 ? b1->length - 1 : 0; a.sn = 2; }
    if (q2 != 0) { a.s[2] = (const char*)q2; a.sl[2] = b2->length > 0 ? b2->length - 1 : 0; a.sn = 3; }
    if (q3 != 0) { a.s[3] = (const char*)q3; a.sl[3] = b3->length > 0 ? b3->length - 1 : 0; a.sn = 4; }
    return rjit_guard2(reinterpret_cast<double(*)(RJitCtx*,RJitArgs*)>(fn), reinterpret_cast<RJitCtx*>(ctx), &a);
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
    addr = rjit_guard2(reinterpret_cast<double(*)(RJitCtx*,RJitArgs*)>(ptrFn), reinterpret_cast<RJitCtx*>(ctx), &a);
    if (addr != addr) return addr;
    return rjit_guard3(reinterpret_cast<double(*)(RJitCtx*,void*,RJitArgs*)>(disp), reinterpret_cast<RJitCtx*>(ctx), (void*)(size_t)addr, &a);
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
    if (q0 != 0) { a.s[0] = (const char*)q0; a.sl[0] = b0->length > 0 ? b0->length - 1 : 0; a.sn = 1; }
    if (q1 != 0) { a.s[1] = (const char*)q1; a.sl[1] = b1->length > 0 ? b1->length - 1 : 0; a.sn = 2; }
    if (q2 != 0) { a.s[2] = (const char*)q2; a.sl[2] = b2->length > 0 ? b2->length - 1 : 0; a.sn = 3; }
    if (q3 != 0) { a.s[3] = (const char*)q3; a.sl[3] = b3->length > 0 ? b3->length - 1 : 0; a.sn = 4; }
    double addr = 0.0;
    addr = rjit_guard2(reinterpret_cast<double(*)(RJitCtx*,RJitArgs*)>(ptrFn), reinterpret_cast<RJitCtx*>(ctx), &a);
    if (addr != addr) return addr;
    return rjit_guard3(reinterpret_cast<double(*)(RJitCtx*,void*,RJitArgs*)>(disp), reinterpret_cast<RJitCtx*>(ctx), (void*)(size_t)addr, &a);
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
    return 1;
  }
  if (ty == 3) {
    unsigned int cur = *(volatile unsigned int*)(size_t)p;
    *(volatile unsigned int*)(size_t)p = cur + (unsigned int)d;
    return 1;
  }
  if (ty == 2) {
    unsigned short cur = *(volatile unsigned short*)(size_t)p;
    *(volatile unsigned short*)(size_t)p = (unsigned short)(cur + (unsigned short)((unsigned long long)d & 0xFFFF));
    return 1;
  }
  if (ty == 1) {
    unsigned short cur = *(volatile unsigned short*)(size_t)p;
    *(volatile unsigned short*)(size_t)p = (unsigned short)(cur + (unsigned short)(((unsigned long long)d >> 16) & 0xFFFF));
    return 1;
  }
  return 0;
  ')
  public static function addRel(p:cpp.SizeT, delta:Float, ty:Int):Int return 0;

  @:functionCode('
#ifdef _WIN32
    DWORD idx = TlsAlloc();
    if (idx == 0xFFFFFFFF) return -1;
    size_t dataSize = (size_t)endVa > (size_t)startVa ? (size_t)endVa - (size_t)startVa : 0;
    size_t total = dataSize + (size_t)zeroFill;
    if (total == 0) total = 1;
    void* block = calloc(1, total);
    if (block == 0) { TlsFree(idx); return -1; }
    if (dataSize > 0) memcpy(block, (const void*)(size_t)startVa, dataSize);
    if (!TlsSetValue(idx, block)) { free(block); TlsFree(idx); return -1; }
    if (indexVa != 0) *(volatile unsigned int*)(size_t)indexVa = (unsigned int)idx;
    rjit_win_tls_track((int)idx, block);
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
    rjit_win_tls_track(idx, block);
    return 1;
#else
    return 0;
#endif
  ')
  public static function bindTlsBlock(idx:Int, startVa:cpp.SizeT, endVa:cpp.SizeT, zeroFill:Int):Int return 0;

  @:functionCode('
#ifdef _WIN32
    TlsSetValue((DWORD)idx, 0);
    rjit_win_tls_release(idx);
    TlsFree((DWORD)idx);
#endif
  ')
  public static function clearTls(idx:Int):Void {}

  @:functionCode('
    int n = bytes->length;
    if (n <= 0) return ::String("");
#ifndef _WIN32
    return bytes->toString();
#else
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
#endif
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
    int q = ((prot & (0x02 | 0x04 | 0x20 | 0x40)) != 0 ? PROT_READ : 0)
          | ((prot & (0x04 | 0x40)) != 0 ? PROT_WRITE : 0)
          | ((prot & (0x10 | 0x20 | 0x40)) != 0 ? PROT_EXEC : 0);
    if (q == 0) q = PROT_NONE;
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

  @:functionCode('return (size_t)((void*(*)())(size_t)f)();')
  public static function callPtr0(f:cpp.SizeT):cpp.SizeT return 0;

  @:functionCode('rjit_host_init(); return (size_t)&rjit_host_call;')
  public static function hostCall():cpp.SizeT return 0;

  @:functionCode('rjit_host_init(); return (size_t)&rjit_host_str;')
  public static function hostStr():cpp.SizeT return 0;

  @:functionCode('((void(*)(void*,void*))(size_t)fn)((void*)(size_t)a, (void*)(size_t)b); return 0.0;')
  public static function callVoid2(fn:cpp.SizeT, a:cpp.SizeT, b:cpp.SizeT):Float return 0;

  @:functionCode('return ((int(*)(void*))(size_t)f)((void*)(size_t)a0);')
  public static function callInt1(f:cpp.SizeT, a0:cpp.SizeT):Int return 0;

  @:functionCode('rjit_set_host_thread(); return 0.0;')
  public static function setHostThread():Float return 0;

  @:functionCode('rjit_set_wait(ms); return 0.0;')
  public static function setWait(ms:Int):Float return 0;

  @:functionCode('rjit_pump(); return 0.0;')
  public static function pump():Float return 0;

  @:functionCode('return rjit_job_timeouts_total();')
  public static function jobTimeouts():Int return 0;

  @:functionCode('const char* s = rjit_job_timeout_last(); return s == 0 ? ::String("") : ::String(s);')
  public static function jobTimeoutName():String return "";

  @:functionCode('return (size_t)&rjit_tls_get;')
  public static function tlsAddr():cpp.SizeT return 0;

  @:functionCode('
    long long v = ((long long)(unsigned long long)(unsigned int)hi << 32) | (unsigned long long)(unsigned int)lo;
    double d = 0.0;
    memcpy(&d, &v, 8);
    return d;
  ')
  public static function bitsOf64(lo:Int, hi:Int):Float return 0;

  @:functionCode('
    long long v = 0;
    memcpy(&v, &v0, 8);
    return (int)(unsigned int)((unsigned long long)v >> 32);
  ')
  public static function hiOf64(v0:Float):Int return 0;

  @:functionCode('
    long long v = 0;
    memcpy(&v, &v0, 8);
    return (int)(unsigned int)v;
  ')
  public static function loOf64(v0:Float):Int return 0;

  @:functionCode('return (double)rjit_job_drops.load();')
  public static function jobDrops():Float return 0;

  @:functionCode('int n = rjit_drop_len.load(); return n > 0 ? ::String::create(rjit_drop_name, n) : ::String("");')
  public static function jobDropName():String return "";

  @:functionCode('return (int)rjit_tls_register((size_t)size, (const void*)(size_t)init, (size_t)initSize);')
  public static function tlsRegister(size:Int, init:cpp.SizeT, initSize:Int):Int return 0;

  @:functionCode('rjit_tls_unregister(id); return 0.0;')
  public static function tlsUnregister(id:Int):Float return 0;

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
    if (p == 0 || size <= 0) return;
#ifdef _WIN32
    FlushInstructionCache(GetCurrentProcess(), (const void*)(size_t)p, (SIZE_T)size);
#elif defined(__GNUC__) || defined(__clang__)
    __builtin___clear_cache((char*)(size_t)p, (char*)((size_t)p + (size_t)size));
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
    if ((mbi.Protect & 0x100) != 0) return 0;
    DWORD prot = mbi.Protect & 0xFF;
    if (prot == 0x01 || prot == 0x00) return 0;
    return 1;
#else
    if (p == 0) return 0;
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) return 0;
    void* page = (void*)((size_t)p & ~((size_t)ps - 1));
    if (msync(page, (size_t)ps, MS_ASYNC) != 0) return 0;
    return 1;
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
