# Arkitekturpilot för Lennart 4

`pilot.py` tränar tre små modeller (13 M parametrar, 6 lager × 256) med samma data och ordning på
~10 M tokens svensk Wikipedia på CPU:

- **A `lennart3`**: inlärda positioner, LayerNorm, GELU-MLP, som Lennart 3
- **B `modern`**: RoPE, RMSNorm, SwiGLU, QK-normering
- **C `modern+skiss`**: B plus en extra förlust (vikt 0,3) på mittlagret genom samma utmatning, så att
  första halvan lär sig gissa nästa token (självskiss för snabbare avkodning)

Resultat (`resultat_*.json`) och slutsatser i `../RAPPORT.md`, avsnitt 7.
