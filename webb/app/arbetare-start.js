/* Webbversionens arbetstråd, första delen: WebAssembly-motorn och inläsning av modellen.
 * Byggskriptet (bygg.py) lägger in motorn (lmengine.wasm) som base64 här, och efter den här filen
 * kommer den del som är kompilerad från Dart (mobil/lennart_app/webbmotor/arbetare.dart): tokenizer,
 * generering och verktygssinne. Allt körs i webbläsaren – ingenting skickas någonstans. */
'use strict';
const WASM_BASE64 = '__WASM__';

let x = null;           // motorns exporter
let h = 0;              // inläst modell
let vocab = 0, ctx = 0;
let buf = 0, bufLen = 0, out = 0, outLen = 0;
const mem = () => x.memory.buffer;

const start = (async () => {
  const s = atob(WASM_BASE64);
  const bytes = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  x = instance.exports;
  x._initialize();
})();
start.catch((e) => postMessage({ type: 'startfel', message: String((e && e.message) || e) }));

function allokera(n) {
  const p = x.malloc(n);
  if (!p) throw new Error('Webbläsaren har inte tillräckligt med minne för modellen');
  return p;
}

function tokens(t) {
  if (t.length > bufLen) {
    if (buf) x.free(buf);
    bufLen = Math.max(64, t.length);
    buf = allokera(4 * bufLen);
  }
  new Int32Array(mem(), buf, t.length).set(t);
}

/* Det Dart-delen använder (se _WasmMotor i arbetare.dart). Vyerna skapas på nytt vid varje anrop,
 * eftersom minnet kan växa och då byts den underliggande bufferten. */
self.lm = {
  pos: () => x.lm_pos(h),
  context: () => ctx,
  vocab: () => vocab,
  reset: () => x.lm_reset(h),
  rewind: (p) => x.lm_rewind(h, p),
  logits: () => new Float32Array(mem(), x.lm_logits(h), vocab),
  eval: (t) => { tokens(t); return x.lm_eval(h, buf, t.length); },
  evalAll: (t) => {
    tokens(t);
    const n = t.length * vocab;
    if (n > outLen) {
      if (out) x.free(out);
      outLen = n;
      out = allokera(4 * n);
    }
    return x.lm_eval_all(h, buf, t.length, out) === 0 ? new Float32Array(mem(), out, n).slice() : new Float32Array(0);
  },
};

/* .lennart: "LENPKG01" | uint32 längd | JSON {entry, tokenizer} | utfyllnad till 4096 | .lmod-data */
async function ladda(m) {
  await start;
  let lmod, meta;
  if (m.paket) {
    const b = m.paket;
    const head = new Uint8Array(await b.slice(0, 12).arrayBuffer());
    if (head.length < 12 || String.fromCharCode(...head.slice(0, 8)) !== 'LENPKG01') {
      throw new Error('Filen är inte ett Lennart-modellpaket (.lennart)');
    }
    const len = new DataView(head.buffer).getUint32(8, true);
    meta = JSON.parse(new TextDecoder().decode(await b.slice(12, 12 + len).arrayBuffer()));
    lmod = b.slice(Math.ceil((12 + len) / 4096) * 4096);
  } else {
    meta = { entry: m.entry, tokenizer: JSON.parse(m.tokText) };
    lmod = m.lmod;
  }
  if (h) { x.lm_free(h); h = 0; }
  const size = lmod.size;
  const p = allokera(size);
  const BIT = 8 << 20;
  for (let off = 0; off < size; off += BIT) {
    const del = new Uint8Array(await lmod.slice(off, Math.min(size, off + BIT)).arrayBuffer());
    new Uint8Array(mem(), p + off, del.length).set(del);
    postMessage({ type: 'progress', id: m.id, done: off + del.length, total: size });
  }
  const err = allokera(256), info = allokera(32);
  h = x.lm_load_mem(p, size, err, 256); // motorn tar över minnesblocket
  if (!h) {
    const fel = new TextDecoder().decode(new Uint8Array(mem(), err, 256)).replace(/\0[\s\S]*$/, '');
    x.free(err); x.free(info);
    throw new Error('Modellen kunde inte läsas: ' + fel);
  }
  x.lm_info(h, info);
  const i = new Int32Array(mem(), info, 7);
  vocab = i[0]; ctx = i[4];
  const d = { vocab, dModel: i[1], layers: i[2], heads: i[3], context: i[4], int8: i[5] === 1 };
  x.free(err); x.free(info);
  self.lennartKommando({ cmd: 'tokenizer', text: JSON.stringify(meta.tokenizer), id: -1 });
  postMessage({ type: 'loaded', id: m.id, entry: meta.entry, info: d });
}

/* Kommandona körs ett i taget, i den ordning de kommer. */
let kedja = Promise.resolve();
self.onmessage = (e) => {
  const m = e.data;
  kedja = kedja.then(async () => {
    try {
      await start;
      if (m.cmd === 'ladda') await ladda(m);
      else self.lennartKommando(m);
    } catch (err) {
      postMessage({ type: m.cmd === 'ladda' ? 'loadError' : 'fel', id: m.id, message: String((err && err.message) || err) });
    }
  });
};
