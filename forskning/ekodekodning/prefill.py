"""Hur snabbt läses en prompt in (n tokens i ett pass)? Jämför två byggen av motorn.

Kör: python forskning/ekodekodning/prefill.py <lib> <modell.lmod>
"""
import ctypes as C
import sys
import time


def main():
    L = C.CDLL(sys.argv[1])
    L.lm_load.restype = C.c_void_p
    L.lm_load.argtypes = [C.c_char_p, C.c_int, C.c_char_p, C.c_int]
    L.lm_reset.argtypes = [C.c_void_p]
    L.lm_eval.argtypes = [C.c_void_p, C.POINTER(C.c_int32), C.c_int]
    err = C.create_string_buffer(256)
    h = L.lm_load(sys.argv[2].encode(), 4, err, 256)
    for n in (32, 128, 384):
        toks = (C.c_int32 * n)(*[(100 + i * 7) % 30000 for i in range(n)])
        best = 1e9
        for _ in range(3):
            L.lm_reset(h)
            t0 = time.perf_counter()
            L.lm_eval(h, toks, n)
            best = min(best, time.perf_counter() - t0)
        print(f"prompt {n:3d} tokens: {best * 1000:7.0f} ms  ({n / best:6.0f} tokens/s)", flush=True)


if __name__ == "__main__":
    main()
