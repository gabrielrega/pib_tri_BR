# Registro de rodadas

Histórico das rodadas de nowcast, com números e comentários. Entrada mais
recente no topo. Convenções:

- **k** = meses do trimestre disponíveis no vintage (early-read usa a cesta
  rápida; bridge usa IBC/PIM/PMC/PMS).
- Números em **QoQ dessaz.** salvo indicação; YoY entre parênteses quando útil.
- **Realizado** fica `—` até o IBGE publicar o trimestre; preencher depois e
  comentar o erro.

---

## Rodada 3 — 2026-07-06 · alvo: 2026T2 (novo combo com AR(1))

Mesma base de dados da rodada 2; muda só a metodologia do combo (AR(1) entra
no pool com pesos ex-COVID — ver CHANGELOG e `diag_combo_ar1.R`).

| Modelo | k | QoQ | YoY |
|---|---|---|---|
| **Bridge combo (novo)** | 1 | **+0,95%** | +2,42% |
| full v1 / v2 | 1 | +1,10% / +1,10% | +2,57% / +2,58% |
| AR(1) | — | +0,61% | +2,08% |
| Early-read | 2 | +0,62% | +2,09% |

- Pesos do combo em k=1: AR(1) 0,31 / full v1 0,34 / full v2 0,35.
- **Realizado:** —

**Comentário:** o combo desce de +1,10% para +0,95% ao dar ~30% de peso ao
AR(1) no vintage curto — exatamente o comportamento desejado da mudança:
menos fé em proxies de 1 mês, mais âncora no prior. A leitura conjunta com o
early-read segue em +0,6% a +1,0%. Validação OOS: RMSE ex-COVID do combo cai
em todos os vintages (v1 0,80→0,76; v2 0,76→0,72; v3 0,62→0,59); em rupturas
tipo 2020 o combo piora — trade-off aceito conscientemente.

---

## Rodada 2 — 2026-07-06 · alvo: 2026T2

| Modelo | k | QoQ | YoY |
|---|---|---|---|
| Early-read | 2 | **+0,62%** | +2,09% |
| Bridge combo | 1 | **+1,10%** | +2,57% |
| full v1 / v2 | 1 | +1,10% / +1,10% | +2,57% / +2,58% |
| AR(1) | — | +0,61% | +2,08% |
| MIDAS / UMIDAS | 1 | −0,15% / +1,62% | +1,31% / +3,10% |

- Banda 80% do early-read (k=2): [−1,92; +3,17] QoQ.
- **Realizado:** —

**Comentário:** primeira rodada em que o bridge produz número para o 2026T2
(IBC com 1/3 meses — abril). Early-read (k=2) e AR(1) apontam ~+0,6%; o combo
do bridge aponta +1,10%, mas com 1 mês de dado duro este é exatamente o cenário
do erro do 2026T1 (RMSE de vintage 1 ≈ 0,93 p.p.). Leitura conjunta: +0,6% a
+1,1%. Re-rodar em meados de julho, quando o IBC-Br de maio deixar o bridge
em k=2.

---

## Rodada 1 — 2026-06-03 · alvo: 2026T1 (retrospectiva)

Entrada retroativa, registrada em 2026-07-06 a partir do CHANGELOG (v0.2.0).

| Modelo | k | QoQ |
|---|---|---|
| Bridge (tempo real) | 1–2 | +0,2% a +0,6% |
| Early-read (backtest) | 1 | erro de 0,34 p.p. |
| Bridge (trimestre cheio) | 3 | erro de 0,05 p.p. |

- **Realizado:** **+1,10%** QoQ.

**Comentário:** o bridge subestimou fortemente o trimestre em tempo real por
ragged edge — aceleração intratrimestral (IBC-Br saltou ~10% em março) e ruído
de proxies de 1 mês (PIM com só janeiro sinalizava −15,8% QoQ). Investigação
concluiu que não houve bug nem erro de especificação; limitação estrutural
documentada no CLAUDE.md. O episódio motivou a criação do módulo early-read.
