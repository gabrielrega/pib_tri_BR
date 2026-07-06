# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running the model

```powershell
Rscript nowcast_pib_bridge_v2_1.R
```

The script is self-contained: it installs missing packages on first run, downloads all data live from IBGE/SIDRA and BCB/SGS, and prints results to stdout. Runtime is ~3–5 minutes due to the MIDAS rolling OOS loop. Diagnostic scripts (`diag_*.R`) in the root are throwaway test files and can be ignored or deleted.

**Registro de rodadas**: após cada rodada de nowcast que produza uma leitura nova (novo vintage ou novo trimestre), anexar uma entrada numerada em `RODADAS.md` (mais recente no topo) com data, alvo, k, números por modelo e comentário. Quando o IBGE publicar o trimestre, preencher o campo **Realizado** da(s) rodada(s) correspondente(s) e comentar o erro.

## Architecture

The active file is **`nowcast_pib_bridge_v2_1.R`**. All logic lives in one script, structured in numbered sections:

| Section | Purpose |
|---------|---------|
| 0 | Package setup (auto-installs) |
| 1 | Global parameters (`DATA_INICIO`, `MIN_OBS_OOS`, COVID dummy dates) |
| 2 | Data download: quarterly PIB from IBGE/SIDRA (table 1621, variable 584, category 90707); monthly IBC-Br (SGS 24363), PIM (21859), PMC (1455), PMS (25405) from BCB |
| 3 | Aggregate monthly → quarterly (mean with `na.rm=TRUE`), compute QoQ growth rates |
| 4 | Model formulas + in-sample OLS fits (AR1, full v1, full v2 bridge equations) |
| 5 | Rolling pseudo-OOS via `roll_eval()` |
| 5b | Ragged-edge vintage analysis (1/2/3 months available) via `make_dados_vintage()` |
| 5c | Forecast combination (inverse-RMSE weights, full v1 + full v2 only) |
| 5d | MIDAS models: nealmon (restricted) and UMIDAS (OLS, `start=NULL`) on monthly series from Q1 2003 |
| 6 | OOS decomposition by sub-period (pre-COVID / COVID / pos-COVID) |
| 7 | Nowcast: iterates over quarters after last published PIB that have ≥1 indicator; uses `nowcast_parcial()` to re-estimate with available predictors only; MIDAS uses LOCF for missing months |
| 8 | ggplot2 visualisation of OOS absolute errors |

## Key design decisions

**Ragged edge**: the script never errors on incomplete quarters. `indic_trim` uses `mean(..., na.rm=TRUE)`, so a quarter with 1 or 2 months still produces an indicator value. Section 7 iterates over all post-PIB quarters with any indicator, rather than only the current calendar quarter.

**MIDAS period**: MIDAS series start at Q1 2003 (first quarter where all four monthly indicators overlap). The bridge equations use data from Q1 1996 onwards. Comparisons between MIDAS and bridge OOS are therefore restricted to the post-2003 common window.

**MIDAS forecasting with partial data**: missing months in the forecast quarter are filled via LOCF (`fill_locf()`) before calling `forecast.midas_r()`. Without this, NA propagates through the lag matrix and the prediction is NA.

**UMIDAS requires `start = NULL`**: calling `midas_r()` without a `start` argument raises an error. Always pass `start = NULL` explicitly for UMIDAS.

**Combo includes AR(1), weight pool excludes COVID**: `combo_pesos` is inverse-RMSE over AR(1) + full v1 + full v2, with the RMSE pool excluding the COVID window (`CORTE_COVID_INI`..`CORTE_COVID_FIM`). With the full pool, COVID inflates the AR(1) RMSE and kills its weight exactly where it helps (short vintages) — that was the old reason for excluding AR(1). Validated in `diag_combo_ar1.R` (2026-07-06): ex-COVID combo RMSE improves at every vintage (v1 0.80→0.76, v2 0.76→0.72, v3 0.62→0.59); COVID-inclusive RMSE worsens — accepted trade-off, ruptures are identifiable in real time. Note: `prev_qoq["AR(1)"]` requires the unnamed `as.numeric(predict(...))` in section 7, otherwise the name becomes `AR(1).1` and the combo silently drops it.

## Limitações conhecidas

**Ragged edge em tempo real (avaliação 2026T1).** A agregação mensal→trimestral
usa `mean(..., na.rm=TRUE)` sobre os meses disponíveis, o que assume implicitamente
que os meses já observados representam o trimestre inteiro. Quando há forte
aceleração (ou desaceleração) intratrimestral, vintages de 1–2 meses erram muito:
no 2026T1 (PIB realizado +1,10% QoQ) as previsões com 1–2 meses ficaram em +0,2% a
+0,6%, porque janeiro veio fraco e março saltou ~10% no IBC-Br. Com os 3 meses o
erro cai para ~0,05 p.p. Além disso, proxies de 1 mês são muito ruidosas (o sinal
QoQ de PIM com apenas janeiro foi −15,8%). Não é bug nem erro de especificação — é
um limite estrutural do método com dados parciais. Mitigação implementada
(2026-07-06): o combo agora inclui o AR(1) com pesos ex-COVID, que estabiliza
os vintages curtos (ver "Combo includes AR(1)" acima). Melhoria possível (não
implementada): prever os meses faltantes antes de agregar.

## Data sources

| Series | Source | Code |
|--------|--------|------|
| PIB trimestral (índice encadeado dessaz.) | IBGE/SIDRA tabela 1621 | `get_sidra(x=1621, variable=584, classific="c11255", category=list(90707))` |
| IBC-Br (dessaz.) | BCB/SGS | 24363 |
| PIM-PF (dessaz.) | BCB/SGS | 21859 |
| PMC (dessaz.) | BCB/SGS | 1455 |
| PMS volume (dessaz.) | BCB/SGS | 25405 |

SIDRA column name is `"Trimestre (Código)"` (with accent) — not `"Trimestre (Codigo)"`.

## Versioning

| File | Status |
|------|--------|
| `nowcast_pib_bridge.R` | v1 — bridge equations only, archived |
| `nowcast_pib_bridge_v2.R` | v2 — added AR(1), COVID dummies, archived |
| `nowcast_pib_bridge_v2_1.R` | **active** — added PMS, MIDAS, vintage OOS, combo |
| `nowcast_early_read.R` | **módulo paralelo** — early-read precoce via indicadores rápidos (SGS+Ipeadata); QoQ/YoY com banda por vintage. Não substitui o oficial. Testes em `tests/test_early_read.R`. |
