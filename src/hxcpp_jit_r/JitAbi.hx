package hxcpp_jit_r;

class JitAbi {
  public static inline var VERSION:Int = 9;

  public static var HEADER:String = '#ifndef RJIT_ABI_H
#define RJIT_ABI_H

#include <string.h>
#include <stdlib.h>

#define RJIT_ABI_VERSION 9

#ifdef __cplusplus
#include <limits>
#include <exception>
static inline double rjit_nan_val() {
#if defined(_MSC_VER)
  return std::numeric_limits<double>::quiet_NaN();
#else
  return __builtin_nan("");
#endif
}
#endif

#if defined(_WIN32)
#define RJIT_API __declspec(dllexport)
#else
#define RJIT_API __attribute__((visibility("default")))
#endif

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

#define RJIT(name) extern "C" RJIT_API double rjit_##name(RJitCtx* ctx, RJitArgs* args)
#define RJIT_INIT extern "C" RJIT_API int rjit_init(RJitCtx* ctx)
#define RJIT_DEINIT extern "C" RJIT_API void rjit_deinit(RJitCtx* ctx)

#define RJIT_N (args->n)
#define RJIT_SN (args->sn)
#define RJIT_ARG(i) ((i) < (args->n) ? (args->a[(i)]) : 0.0)
#define RJIT_A0 (args->a[0])
#define RJIT_A1 (args->a[1])
#define RJIT_A2 (args->a[2])
#define RJIT_A3 (args->a[3])
#define RJIT_A4 (args->a[4])
#define RJIT_A5 (args->a[5])

#define RJIT_SARG(i) ((i) < (args->sn) && args->s[(i)] != 0 ? args->s[(i)] : "")
#define RJIT_S0 RJIT_SARG(0)
#define RJIT_S1 RJIT_SARG(1)
#define RJIT_S2 RJIT_SARG(2)
#define RJIT_S3 RJIT_SARG(3)
#define RJIT_SLEN(i) ((i) < (args->sn) ? args->sl[(i)] : 0)

#define RJIT_LOG(s) (ctx->h->log(ctx->m, (s), (int)strlen(s)))
#define RJIT_LOGN(s, n) (ctx->h->log(ctx->m, (s), (int)(n)))
#define RJIT_RETSTR(s) (ctx->h->retstr(ctx->m, (s), (int)strlen(s)), 0.0)
#define RJIT_RETSTRN(s, n) (ctx->h->retstr(ctx->m, (s), (int)(n)), 0.0)
#define RJIT_RETSTR2N(s, n) (ctx->h->retstr2(ctx->m, (s), (int)(n)), 0.0)
#define RJIT_ERRN(s, n) (ctx->h->log(ctx->m, (s), (int)(n)), 0.0)
#define RJIT_CALL0(n) (ctx->h->call(ctx->m, (n), (int)strlen(n), 0.0, 0.0, 0.0, 0.0))
#define RJIT_CALL1(n,x) (ctx->h->call(ctx->m, (n), (int)strlen(n), (x), 0.0, 0.0, 0.0))
#define RJIT_CALL2(n,x,y) (ctx->h->call(ctx->m, (n), (int)strlen(n), (x), (y), 0.0, 0.0))
#define RJIT_CALL3(n,x,y,z) (ctx->h->call(ctx->m, (n), (int)strlen(n), (x), (y), (z), 0.0))
#define RJIT_GET(k) (ctx->h->get(ctx->m, (k), (int)strlen(k)))

#ifdef RJIT_DEFINE_ABI_EXPORT
extern "C" RJIT_API double rjit_abi(void) { return (double)RJIT_ABI_VERSION; }
#endif

#endif
';
}
