// Lennarts räknare i webbläsaren – samma regler som verktyget "raknare" i appen
// (mobil/lennart_app/lib/agent/verktyg.dart): + − × ÷, ^ (högerassociativ), parenteser, procent,
// decimalkomma och funktionerna sqrt, abs och round samt pi. Egen tolkare – kör aldrig kod.
function rakna(text) {
  const s = String(text)
    .replace(/×/g, "*").replace(/÷/g, "/").replace(/−/g, "-").replace(/,/g, ".").replace(/\s/g, "");
  if (s.length > 200) throw new Error("Uttrycket är för långt");
  if (s.length === 0) throw new Error("Skriv ett uttryck, t.ex. 12*7");
  let i = 0;
  const ta = (c) => (s[i] === c ? (i++, true) : false);

  function summa() {
    let v = produkt();
    for (;;) {
      if (ta("+")) v += produkt();
      else if (ta("-")) v -= produkt();
      else return v;
    }
  }
  function produkt() {
    let v = potens();
    for (;;) {
      if (ta("*")) v *= potens();
      else if (ta("/")) {
        const d = potens();
        if (d === 0) throw new Error("Division med noll");
        v /= d;
      } else return v;
    }
  }
  function potens() {
    const b = unar();
    if (ta("^")) return Math.pow(b, potens());
    return b;
  }
  function unar() {
    if (ta("-")) return -unar();
    if (ta("+")) return unar();
    let v = atom();
    if (ta("%")) v /= 100;
    return v;
  }
  function atom() {
    if (ta("(")) {
      const v = summa();
      if (!ta(")")) throw new Error("En parentes stängs inte");
      return v;
    }
    for (const f of ["sqrt", "abs", "round"]) {
      if (s.startsWith(f + "(", i)) {
        i += f.length + 1;
        const v = summa();
        if (!ta(")")) throw new Error("En parentes stängs inte");
        if (f === "sqrt") {
          if (v < 0) throw new Error("Roten ur ett negativt tal");
          return Math.sqrt(v);
        }
        return f === "abs" ? Math.abs(v) : Math.round(v);
      }
    }
    if (s.startsWith("pi", i)) {
      i += 2;
      return Math.PI;
    }
    const m = /^(\d+(\.\d+)?|\.\d+)/.exec(s.slice(i));
    if (!m) throw new Error(i < s.length ? `Förstår inte "${s.slice(i)}"` : "Uttrycket tar slut för tidigt");
    i += m[0].length;
    return parseFloat(m[0]);
  }

  const v = summa();
  if (i !== s.length) throw new Error(`Förstår inte "${s.slice(i)}"`);
  if (!Number.isFinite(v)) throw new Error("Uttrycket har inget ändligt värde");
  if (Number.isInteger(v) && Math.abs(v) < 1e15) return String(v === 0 ? 0 : v);
  return String(parseFloat(v.toPrecision(12))).replace(".", ",");
}

if (typeof module !== "undefined") module.exports = { rakna };
