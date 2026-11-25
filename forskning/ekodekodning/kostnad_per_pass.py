"""Hur mycket kostar ett pass med k tokens jämfört med ett pass med 1 token?

Om vikterna dominerar (minnesbandbredd, typiskt för telefoner) kostar k tokens nästan som 1.
Om beräkningen dominerar växer kostnaden med k. Svaret avgör hur mycket ekodekodningen vinner.

Kör: python forskning/ekodekodning/kostnad_per_pass.py <lib> <modell.lmod>
"""
import sys
import time

from ekodekodning import Engine


def main():
    eng = Engine(sys.argv[1], sys.argv[2])
    base = list(range(100, 160))
    res = {}
    for k in (1, 2, 4, 8):
        times = []
        for rep in range(12):
            eng.reset()
            eng.eval(base)
            t0 = time.perf_counter()
            if k == 1:
                eng.eval([7])
            else:
                eng.eval_all([7] * k)
            times.append(time.perf_counter() - t0)
        times.sort()
        res[k] = sum(times[2:10]) / 8
        print(f"k={k}: {res[k] * 1000:.1f} ms per pass  ({res[k] / res[1]:.2f}× ett pass med 1 token)", flush=True)


if __name__ == "__main__":
    main()
