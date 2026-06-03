# Módulo early-read do PIB — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Construir `nowcast_early_read.R`, um módulo separado que projeta PIB QoQ (e YoY) com banda de incerteza para o trimestre corrente usando indicadores de divulgação rápida (SGS + Ipeadata), semanas antes do nowcast oficial ter dados.

**Architecture:** Script R autônomo com funções puras (transformação YoY, agregação ragged-edge, conversão YoY→QoQ, fator PCA, mapeamento, OOS por vintage) + um `main()` de orquestração. Funções puras testadas com fixtures sintéticas sem rede; coleta e run completo verificados com smoke tests ao vivo. Alvo do modelo é `pib_yoy`, convertido para QoQ via índices encadeados já publicados.

**Tech Stack:** R 4.4.1; `rbcb` (SGS), `ipeadatar` (Ipeadata), `dplyr`/`tidyr`/`lubridate`/`purrr`/`tibble`, `stats::prcomp`/`lm`. Testes via `base::stopifnot` (sem framework externo).

**Spec:** `docs/superpowers/specs/2026-06-03-nowcast-early-read-design.md`

---

## File Structure

| Arquivo | Responsabilidade | Versionado? |
|---|---|---|
| `nowcast_early_read.R` (criar) | Módulo completo: setup, coleta, funções puras, `main()` | sim |
| `tests/test_early_read.R` (criar) | Testes unitários network-free das funções puras (fixtures sintéticas) | sim |
| `CHANGELOG.md` (modificar) | Entrada em `[Não lançado] → Adicionado` | sim |
| `CLAUDE.md` (modificar) | Registrar o módulo na seção Architecture | sim |
| `diag_backtest_q1.R` (criar, throwaway) | Gate de aceitação: early-read 2026T1 vs +1,10% realizado | não (gitignored `diag_*.R`) |

**Guard de sourcing:** o final de `nowcast_early_read.R` chama `main()` apenas se a env var `EARLY_READ_TEST` não for `"1"`. Assim os testes podem `source()` o arquivo para carregar funções sem disparar downloads.

**Convenção de commits (do CLAUDE.md):** Conventional Commits, tipo em inglês, descrição em português, imperativo. Rodapé `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## Task 1: Scaffold do script + guard de sourcing

**Files:**
- Create: `nowcast_early_read.R`
- Create: `tests/test_early_read.R`

- [ ] **Step 1: Criar o scaffold com setup de pacotes, placeholder de `main()` e guard**

Conteúdo inicial de `nowcast_early_read.R`:

```r
# ============================================================
# PIB Brasil - Early-read trimestral via indicadores rapidos
# Modulo separado (nao altera nowcast_pib_bridge_v2_1.R).
# Alvo: pib_yoy -> convertido para QoQ. Banda por vintage.
# ============================================================

# ---- 0. Setup ----------------------------------------------
pacotes <- c("rbcb", "ipeadatar", "sidrar", "dplyr", "tidyr",
             "lubridate", "purrr", "tibble")
novos <- setdiff(pacotes, rownames(installed.packages()))
if (length(novos) > 0) install.packages(novos, repos = "https://cloud.r-project.org")
invisible(lapply(pacotes, library, character.only = TRUE))

options(scipen = 999)

# ---- 1. Parametros -----------------------------------------
DATA_INICIO  <- as.Date("2000-01-01")
MIN_OBS_OOS  <- 24
N_PC_DEFAULT <- 1L

# (funcoes definidas nas Tasks 2-8)

# ---- 9. Orquestracao ---------------------------------------
main <- function() {
  cat("[early-read] main() ainda nao implementado\n")
}

if (Sys.getenv("EARLY_READ_TEST") != "1") {
  main()
}
```

Conteúdo inicial de `tests/test_early_read.R`:

```r
# Testes unitarios network-free do modulo early-read.
# Rodar: Rscript tests/test_early_read.R
Sys.setenv(EARLY_READ_TEST = "1")
suppressMessages(source("nowcast_early_read.R"))

cat("== test_early_read ==\n")

# (asserts adicionados nas Tasks 2-8)

cat("OK: todos os testes passaram\n")
```

- [ ] **Step 2: Rodar o arquivo de teste para confirmar que carrega sem erro**

Run: `Rscript tests/test_early_read.R`
Expected: termina com `OK: todos os testes passaram` (sem disparar `main()`, pois `EARLY_READ_TEST=1`).

- [ ] **Step 3: Commit**

```bash
git add nowcast_early_read.R tests/test_early_read.R
git commit -m "feat(early-read): scaffold do modulo e guard de sourcing"
```

---

## Task 2: `to_yoy()` — variação YoY 12 meses

**Files:**
- Modify: `nowcast_early_read.R` (adicionar função na seção de funções)
- Modify: `tests/test_early_read.R`

- [ ] **Step 1: Escrever o teste que falha**

Adicionar em `tests/test_early_read.R` antes da linha `cat("OK: ...`:

```r
# to_yoy: valor sobe de 100 para 110 doze meses depois => YoY = 10
df_t2 <- data.frame(
  date = seq(as.Date("2020-01-01"), by = "month", length.out = 24),
  x    = c(rep(100, 12), rep(110, 12))
)
r2 <- to_yoy(df_t2, "x")
stopifnot(is.na(r2$x[1]))                       # sem base 12m no inicio
stopifnot(abs(r2$x[13] - 10) < 1e-9)            # 110/100 - 1 = 10%
cat("OK: to_yoy\n")
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `Rscript tests/test_early_read.R`
Expected: FAIL com `could not find function "to_yoy"`.

- [ ] **Step 3: Implementar `to_yoy()`**

Adicionar em `nowcast_early_read.R` após a seção 1:

```r
# ---- 2. Funcoes puras --------------------------------------

# Converte colunas de nivel para variacao YoY (12 meses).
# Assume painel mensal contiguo e ordenado por data. Mantem 'date'.
to_yoy <- function(df, cols) {
  df <- df[order(df$date), , drop = FALSE]
  for (c in cols) df[[c]] <- (df[[c]] / dplyr::lag(df[[c]], 12) - 1) * 100
  df
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `Rscript tests/test_early_read.R`
Expected: imprime `OK: to_yoy` e `OK: todos os testes passaram`.

- [ ] **Step 5: Commit**

```bash
git add nowcast_early_read.R tests/test_early_read.R
git commit -m "feat(early-read): adiciona transformacao YoY (to_yoy)"
```

---

## Task 3: `agregar_trim_yoy()` — agregação ragged-edge por vintage

**Files:**
- Modify: `nowcast_early_read.R`
- Modify: `tests/test_early_read.R`

- [ ] **Step 1: Escrever o teste que falha**

Adicionar em `tests/test_early_read.R`:

```r
# agregar_trim_yoy: um trimestre com YoY mensais 1,2,3
df_t3 <- data.frame(
  date = as.Date(c("2021-01-01","2021-02-01","2021-03-01")),
  x    = c(1, 2, 3)
)
a_k1 <- agregar_trim_yoy(df_t3, "x", k = 1)
a_k3 <- agregar_trim_yoy(df_t3, "x", k = 3)
stopifnot(abs(a_k1$x - 1) < 1e-9)        # so' janeiro
stopifnot(abs(a_k3$x - 2) < 1e-9)        # media de 1,2,3
stopifnot(a_k1$meses == 1, a_k3$meses == 3)
cat("OK: agregar_trim_yoy\n")
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `Rscript tests/test_early_read.R`
Expected: FAIL com `could not find function "agregar_trim_yoy"`.

- [ ] **Step 3: Implementar `agregar_trim_yoy()`**

Adicionar em `nowcast_early_read.R` (seção 2):

```r
# Agrega YoY mensal -> trimestral usando os primeiros k meses do trimestre.
# Ragged edge: media dos meses disponiveis (YoY e' comparavel mes a mes).
agregar_trim_yoy <- function(df_yoy, cols, k = 3) {
  df_yoy %>%
    dplyr::mutate(
      trim = as.Date(lubridate::floor_date(date, "quarter")),
      mes  = (lubridate::month(date) - 1) %% 3 + 1
    ) %>%
    dplyr::filter(mes <= k) %>%
    dplyr::group_by(trim) %>%
    dplyr::summarise(
      dplyr::across(dplyr::all_of(cols), ~ mean(.x, na.rm = TRUE)),
      meses = sum(!is.na(.data[[cols[1]]])),
      .groups = "drop"
    )
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `Rscript tests/test_early_read.R`
Expected: imprime `OK: agregar_trim_yoy`.

- [ ] **Step 5: Commit**

```bash
git add nowcast_early_read.R tests/test_early_read.R
git commit -m "feat(early-read): agrega YoY trimestral com ragged edge (agregar_trim_yoy)"
```

---

## Task 4: `yoy_para_qoq()` — conversão usando índices publicados

**Files:**
- Modify: `nowcast_early_read.R`
- Modify: `tests/test_early_read.R`

- [ ] **Step 1: Escrever o teste que falha**

Adicionar em `tests/test_early_read.R`:

```r
# yoy_para_qoq: idx_lag4=100, yoy=4 => idx_t=104; idx_lag1=103 => qoq ~ 0.9709
q4 <- yoy_para_qoq(yoy_prev = 4, idx_lag1 = 103, idx_lag4 = 100)
stopifnot(abs(q4 - ((104/103 - 1) * 100)) < 1e-9)
cat("OK: yoy_para_qoq\n")
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `Rscript tests/test_early_read.R`
Expected: FAIL com `could not find function "yoy_para_qoq"`.

- [ ] **Step 3: Implementar `yoy_para_qoq()`**

Adicionar em `nowcast_early_read.R` (seção 2):

```r
# Converte um YoY previsto do trimestre-alvo em QoQ, usando os indices
# encadeados ja' publicados de t-1 (trimestre anterior) e t-4 (ano antes).
yoy_para_qoq <- function(yoy_prev, idx_lag1, idx_lag4) {
  idx_t <- idx_lag4 * (1 + yoy_prev / 100)
  (idx_t / idx_lag1 - 1) * 100
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `Rscript tests/test_early_read.R`
Expected: imprime `OK: yoy_para_qoq`.

- [ ] **Step 5: Commit**

```bash
git add nowcast_early_read.R tests/test_early_read.R
git commit -m "feat(early-read): converte YoY previsto em QoQ (yoy_para_qoq)"
```

---

## Task 5: `fatores_pca()`, `ajustar_mapa()` e `prever_mapa()` — fator + mapeamento

**Files:**
- Modify: `nowcast_early_read.R`
- Modify: `tests/test_early_read.R`

- [ ] **Step 1: Escrever o teste que falha**

Adicionar em `tests/test_early_read.R`:

```r
# Mapeamento: gera cesta sintetica onde pib_yoy depende de um fator comum.
set.seed(1)
n <- 60
f <- rnorm(n)
dados_t5 <- data.frame(
  trim    = seq(as.Date("2005-01-01"), by = "quarter", length.out = n),
  pib_yoy = 2 + 1.5 * f + rnorm(n, sd = 0.2),
  a = f + rnorm(n, sd = 0.3),
  b = f + rnorm(n, sd = 0.3),
  c = f + rnorm(n, sd = 0.3)
)
cols_t5 <- c("a", "b", "c")
mapa <- ajustar_mapa(dados_t5, cols_t5, n_pc = 1)
stopifnot(inherits(mapa$mod, "lm"))
# previsao em uma linha conhecida deve ser finita e razoavelmente perto do obs
linha <- dados_t5[10, cols_t5, drop = FALSE]
ph <- prever_mapa(mapa, linha)
stopifnot(is.finite(ph))
stopifnot(abs(ph - dados_t5$pib_yoy[10]) < 1.5)   # erro << escala do sinal
cat("OK: ajustar_mapa/prever_mapa\n")
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `Rscript tests/test_early_read.R`
Expected: FAIL com `could not find function "ajustar_mapa"`.

- [ ] **Step 3: Implementar as três funções**

Adicionar em `nowcast_early_read.R` (seção 2):

```r
# Extrai n_pc componentes principais de uma matriz (cesta padronizada).
fatores_pca <- function(mat, n_pc = 1) {
  pr <- prcomp(mat, center = TRUE, scale. = TRUE)
  list(scores = pr$x[, seq_len(n_pc), drop = FALSE], pca = pr)
}

# Ajusta pib_yoy ~ PCs sobre os casos completos da cesta.
# Devolve o lm, o objeto prcomp (para projetar novas linhas), cols e n_pc.
ajustar_mapa <- function(dados_trim, cols, n_pc = N_PC_DEFAULT) {
  cc <- dados_trim %>% tidyr::drop_na(dplyr::all_of(c("pib_yoy", cols)))
  fp <- fatores_pca(as.matrix(cc[cols]), n_pc)
  df <- data.frame(pib_yoy = cc$pib_yoy, fp$scores)
  names(df)[-1] <- paste0("PC", seq_len(n_pc))
  form <- as.formula(paste("pib_yoy ~", paste(paste0("PC", seq_len(n_pc)), collapse = " + ")))
  mod <- lm(form, data = df)
  list(mod = mod, pca = fp$pca, cols = cols, n_pc = n_pc)
}

# Projeta uma linha (data.frame com as colunas da cesta) nos PCs e preve pib_yoy.
prever_mapa <- function(mapa, linha_cols) {
  sc <- predict(mapa$pca, newdata = as.matrix(linha_cols[mapa$cols]))[, seq_len(mapa$n_pc), drop = FALSE]
  nd <- as.data.frame(sc)
  names(nd) <- paste0("PC", seq_len(mapa$n_pc))
  as.numeric(predict(mapa$mod, newdata = nd))
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `Rscript tests/test_early_read.R`
Expected: imprime `OK: ajustar_mapa/prever_mapa`.

- [ ] **Step 5: Commit**

```bash
git add nowcast_early_read.R tests/test_early_read.R
git commit -m "feat(early-read): fator PCA e mapeamento pib_yoy (ajustar_mapa/prever_mapa)"
```

---

## Task 6: `oos_vintage()` — banda por vintage (pseudo-OOS)

**Files:**
- Modify: `nowcast_early_read.R`
- Modify: `tests/test_early_read.R`

- [ ] **Step 1: Escrever o teste que falha**

Adicionar em `tests/test_early_read.R`:

```r
# oos_vintage: painel YoY trimestral sintetico ja' agregado (1 ponto/trim).
# Reusa dados_t5 (cesta a,b,c) como se ja' fossem YoY trimestrais.
pib_t6 <- dados_t5[, c("trim", "pib_yoy")]
painel_t6 <- dados_t5[, c("trim", cols_t5)]
oos <- oos_vintage_pronto(painel_t6, pib_t6, cols_t5, n_pc = 1, min_obs = 24)
stopifnot(all(c("trim", "obs", "pred", "erro") %in% names(oos)))
stopifnot(nrow(oos) > 0)
rmse <- sqrt(mean(oos$erro^2, na.rm = TRUE))
stopifnot(is.finite(rmse))
cat("OK: oos_vintage_pronto\n")
```

> Nota: testamos `oos_vintage_pronto()` (recebe trimestral já agregado, sem
> rede). A `oos_vintage()` da seção 9 apenas agrega por k e chama esta — testada
> no smoke da Task 8.

- [ ] **Step 2: Rodar e ver falhar**

Run: `Rscript tests/test_early_read.R`
Expected: FAIL com `could not find function "oos_vintage_pronto"`.

- [ ] **Step 3: Implementar `oos_vintage_pronto()` e `oos_vintage()`**

Adicionar em `nowcast_early_read.R` (seção 2):

```r
# Rolling pseudo-OOS sobre um data frame trimestral ja' montado
# (trim, pib_yoy + colunas da cesta). Devolve erros por trimestre.
oos_vintage_pronto <- function(painel_trim, pib_trim, cols, n_pc = N_PC_DEFAULT,
                               min_obs = MIN_OBS_OOS) {
  dd <- pib_trim %>%
    dplyr::inner_join(painel_trim, by = "trim") %>%
    tidyr::drop_na(dplyr::all_of(c("pib_yoy", cols))) %>%
    dplyr::arrange(trim)
  out <- list()
  if (nrow(dd) <= min_obs) return(tibble::tibble(trim = as.Date(character()),
                                                 obs = numeric(), pred = numeric(),
                                                 erro = numeric()))
  for (i in (min_obs + 1):nrow(dd)) {
    tr <- dd[1:(i - 1), ]
    te <- dd[i, ]
    mp <- tryCatch(ajustar_mapa(tr, cols, n_pc), error = function(e) NULL)
    if (is.null(mp)) next
    ph <- tryCatch(prever_mapa(mp, te[, cols, drop = FALSE]), error = function(e) NA_real_)
    out[[length(out) + 1]] <- tibble::tibble(trim = te$trim, obs = te$pib_yoy, pred = ph)
  }
  dplyr::bind_rows(out) %>% dplyr::mutate(erro = obs - pred)
}

# Para cada vintage k, agrega a cesta com k meses e roda o OOS.
# Devolve RMSE por k (base da banda).
oos_vintage <- function(painel_yoy_mensal, pib_trim, cols, ks = 1:3,
                        n_pc = N_PC_DEFAULT, min_obs = MIN_OBS_OOS) {
  purrr::map_dfr(ks, function(k) {
    tk <- agregar_trim_yoy(painel_yoy_mensal, cols, k)
    oos_vintage_pronto(tk, pib_trim, cols, n_pc, min_obs) %>%
      dplyr::mutate(k = k)
  }) %>%
    dplyr::group_by(k) %>%
    dplyr::summarise(rmse = sqrt(mean(erro^2, na.rm = TRUE)),
                     n = sum(!is.na(erro)), .groups = "drop")
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `Rscript tests/test_early_read.R`
Expected: imprime `OK: oos_vintage_pronto`.

- [ ] **Step 5: Commit**

```bash
git add nowcast_early_read.R tests/test_early_read.R
git commit -m "feat(early-read): pseudo-OOS por vintage para a banda (oos_vintage)"
```

---

## Task 7: `baixar_rapidos()` — coleta SGS + Ipeadata (integração ao vivo)

**Files:**
- Modify: `nowcast_early_read.R`

> Esta função usa rede; verificação é smoke ao vivo, não teste unitário.

- [ ] **Step 1: Implementar `baixar_rapidos()`**

Adicionar em `nowcast_early_read.R` (seção 2). A cesta é o conjunto curado do spec; séries sem dessaz. são tratadas via YoY a jusante.

```r
# Cesta de indicadores rapidos. SGS via rbcb; Ipeadata via ipeadatar.
# Devolve painel mensal contiguo (grade completa de meses) com uma coluna
# por indicador, em nivel.
SGS_RAPIDOS <- c(veic_prod = 1373, veic_lic = 7384, energia = 1406,
                 comex_exp = 22707, comex_imp = 22708, icc = 4393)
IPEA_RAPIDOS <- c(icei = "CNI12_ICEIGER12", abpo = "ABPO12_PAPEL12")

baixar_rapidos <- function(start_date = DATA_INICIO, end_date = Sys.Date(),
                           usar_ipeadata = TRUE) {
  # SGS
  sgs <- rbcb::get_series(SGS_RAPIDOS, start_date = start_date, end_date = end_date)
  pan <- purrr::reduce(sgs, dplyr::full_join, by = "date") %>%
    dplyr::mutate(date = as.Date(date))
  # comex em volume aproximado: usamos exp+imp (fluxo) como uma coluna
  pan <- pan %>% dplyr::mutate(comex = .data$comex_exp + .data$comex_imp) %>%
    dplyr::select(-comex_exp, -comex_imp)

  # Ipeadata
  if (usar_ipeadata && requireNamespace("ipeadatar", quietly = TRUE)) {
    ip <- tryCatch(
      ipeadatar::ipeadata(unname(IPEA_RAPIDOS)),
      error = function(e) { message("[early-read] ipeadata falhou: ", conditionMessage(e)); NULL }
    )
    if (!is.null(ip)) {
      ipw <- ip %>%
        dplyr::transmute(date = as.Date(date), code, value) %>%
        dplyr::filter(date >= start_date, date <= end_date) %>%
        tidyr::pivot_wider(names_from = code, values_from = value)
      # renomeia codigos -> rotulos amigaveis (IPEA_RAPIDOS ja' e' novo=antigo).
      # rename(!!!pares) faz o splice; so' renomeia os codigos presentes.
      presentes <- IPEA_RAPIDOS[IPEA_RAPIDOS %in% names(ipw)]
      if (length(presentes) > 0) ipw <- dplyr::rename(ipw, !!!presentes)
      pan <- dplyr::full_join(pan, ipw, by = "date")
    }
  }

  # Grade mensal contigua (garante lag(12) = 12 meses calendario)
  grade <- data.frame(date = seq(min(pan$date, na.rm = TRUE),
                                 max(pan$date, na.rm = TRUE), by = "month"))
  dplyr::left_join(grade, pan, by = "date") %>% dplyr::arrange(date)
}

# Colunas-indicador efetivamente disponiveis no painel coletado.
cols_cesta <- function(painel) setdiff(names(painel), "date")
```

- [ ] **Step 2: Smoke test ao vivo**

Run: `Rscript -e 'Sys.setenv(EARLY_READ_TEST="1"); source("nowcast_early_read.R"); p <- baixar_rapidos(); cat("cols:", paste(cols_cesta(p), collapse=","), "\n"); cat("ultimo:", format(max(p$date),"%Y-%m"), "\n"); print(tail(p,3))'`
Expected: imprime as colunas da cesta (inclui `veic_prod`, `energia`, `icc`, etc.), com `ultimo` ≥ `2026-04`, e linhas recentes com valores de abril/2026 (e `icc` até maio).

- [ ] **Step 3: Commit**

```bash
git add nowcast_early_read.R
git commit -m "feat(early-read): coleta cesta rapida via SGS + Ipeadata (baixar_rapidos)"
```

---

## Task 8: `main()` — orquestração e output (integração ao vivo)

**Files:**
- Modify: `nowcast_early_read.R`

- [ ] **Step 1: Implementar `main()` substituindo o placeholder**

Substituir o corpo de `main()` na seção 9 por:

```r
main <- function() {
  # PIB trimestral (indice encadeado dessaz.) + YoY
  pib_raw <- sidrar::get_sidra(x = 1621, variable = 584, period = "all",
                               classific = "c11255", category = list(90707), format = 4)
  pib <- pib_raw %>%
    dplyr::transmute(trim = lubridate::yq(`Trimestre (Código)`),
                     pib_idx = as.numeric(Valor)) %>%
    dplyr::arrange(trim) %>%
    dplyr::mutate(pib_yoy = (pib_idx / dplyr::lag(pib_idx, 4) - 1) * 100)

  # Cesta rapida -> YoY mensal
  painel  <- baixar_rapidos()
  cols    <- cols_cesta(painel)
  pan_yoy <- to_yoy(painel, cols)

  # Trimestre-alvo: primeiro apos o ultimo PIB com >=1 indicador rapido
  ult_trim <- pib %>% dplyr::filter(!is.na(pib_yoy)) %>% dplyr::pull(trim) %>% max()
  alvo_trim <- as.Date(lubridate::floor_date(ult_trim %m+% months(3), "quarter"))
  cesta_alvo <- agregar_trim_yoy(pan_yoy, cols, k = 3) %>% dplyr::filter(trim == alvo_trim)
  k_disp <- if (nrow(cesta_alvo) == 0) 0L else as.integer(cesta_alvo$meses)

  if (k_disp == 0L) {
    cat(sprintf("[early-read] Sem indicadores rapidos para %dT%d ainda.\n",
                lubridate::year(alvo_trim), lubridate::quarter(alvo_trim)))
    return(invisible(NULL))
  }
  k_vint <- min(3L, k_disp)

  # Ajuste no vintage correspondente + banda por vintage
  cesta_k   <- agregar_trim_yoy(pan_yoy, cols, k = k_vint)
  mapa      <- ajustar_mapa(pib %>% dplyr::select(trim, pib_yoy) %>%
                              dplyr::inner_join(cesta_k, by = "trim"), cols)
  linha_alvo <- cesta_k %>% dplyr::filter(trim == alvo_trim)
  yoy_prev   <- prever_mapa(mapa, linha_alvo[, cols, drop = FALSE])

  banda <- oos_vintage(pan_yoy, pib %>% dplyr::select(trim, pib_yoy), cols)
  rmse_k <- banda$rmse[banda$k == k_vint]

  # Conversao YoY -> QoQ via indices publicados
  idx_lag1 <- pib %>% dplyr::filter(trim == alvo_trim %m-% months(3)) %>% dplyr::pull(pib_idx)
  idx_lag4 <- pib %>% dplyr::filter(trim == alvo_trim %m-% months(12)) %>% dplyr::pull(pib_idx)
  qoq_prev <- yoy_para_qoq(yoy_prev, idx_lag1, idx_lag4)
  qoq_band <- function(z) yoy_para_qoq(c(yoy_prev - z*rmse_k, yoy_prev + z*rmse_k), idx_lag1, idx_lag4)

  cat(sprintf("\n===== EARLY-READ %dT%d (ultimo PIB: %dT%d) =====\n",
              lubridate::year(alvo_trim), lubridate::quarter(alvo_trim),
              lubridate::year(ult_trim), lubridate::quarter(ult_trim)))
  cat(sprintf("Indicadores (vintage k=%d): %s\n", k_vint, paste(cols, collapse = ", ")))
  cat(sprintf("RMSE OOS (k=%d) = %.2f p.p. (YoY)\n\n", k_vint, rmse_k))
  cat(sprintf("  %-10s %10s %10s\n", "", "QoQ", "YoY"))
  cat(sprintf("  %-10s %+9.2f%% %+9.2f%%\n", "ponto", qoq_prev, yoy_prev))
  b80q <- qoq_band(1.28); b90q <- qoq_band(1.64)
  cat(sprintf("  %-10s [%+.2f, %+.2f] [%+.2f, %+.2f]\n", "banda 80%",
              b80q[1], b80q[2], yoy_prev - 1.28*rmse_k, yoy_prev + 1.28*rmse_k))
  cat(sprintf("  %-10s [%+.2f, %+.2f] [%+.2f, %+.2f]\n", "banda 90%",
              b90q[1], b90q[2], yoy_prev - 1.64*rmse_k, yoy_prev + 1.64*rmse_k))
  if (k_vint < 3L)
    cat(sprintf("\n  [aviso] k=%d mes(es) -> leitura preliminar, banda larga.\n", k_vint))
  cat("  Bridge oficial: rode nowcast_pib_bridge_v2_1.R (n/d enquanto IBC/PIM de abril nao sairem).\n")
  invisible(list(trim = alvo_trim, qoq = qoq_prev, yoy = yoy_prev, rmse_k = rmse_k, k = k_vint))
}
```

- [ ] **Step 2: Smoke test ao vivo do run completo**

Run: `Rscript nowcast_early_read.R`
Expected: imprime um bloco `===== EARLY-READ 2026T2 ...` com `ponto` QoQ e YoY numéricos e bandas 80%/90%. Não deve haver erro de execução.

- [ ] **Step 3: Confirmar que os testes unitários ainda passam**

Run: `Rscript tests/test_early_read.R`
Expected: `OK: todos os testes passaram`.

- [ ] **Step 4: Commit**

```bash
git add nowcast_early_read.R
git commit -m "feat(early-read): orquestracao main() com QoQ, YoY e banda por vintage"
```

---

## Task 9: Backtest 2026T1 — gate de aceitação

**Files:**
- Create: `diag_backtest_q1.R` (throwaway, gitignored)

> Objetivo: confirmar o critério de sucesso #2 do spec — no vintage k=1, o
> early-read erra MENOS que o bridge (que errou ~+0,9 p.p. no 2026T1).

- [ ] **Step 1: Escrever o backtest**

Criar `diag_backtest_q1.R`:

```r
# Backtest: early-read do 2026T1 com k=1 e k=2 vs PIB realizado (+1,10% QoQ).
Sys.setenv(EARLY_READ_TEST = "1")
suppressMessages(source("nowcast_early_read.R"))

pib_raw <- sidrar::get_sidra(x=1621, variable=584, period="all",
                             classific="c11255", category=list(90707), format=4)
pib <- pib_raw %>%
  dplyr::transmute(trim=lubridate::yq(`Trimestre (Código)`), pib_idx=as.numeric(Valor)) %>%
  dplyr::arrange(trim) %>%
  dplyr::mutate(pib_qoq=(pib_idx/dplyr::lag(pib_idx)-1)*100,
                pib_yoy=(pib_idx/dplyr::lag(pib_idx,4)-1)*100)

painel  <- baixar_rapidos()
cols    <- cols_cesta(painel)
pan_yoy <- to_yoy(painel, cols)

ALVO <- as.Date("2026-01-01")
obs_qoq <- pib$pib_qoq[pib$trim == ALVO]
idx_lag1 <- pib$pib_idx[pib$trim == ALVO %m-% months(3)]
idx_lag4 <- pib$pib_idx[pib$trim == ALVO %m-% months(12)]

cat(sprintf("2026T1 realizado: %+.2f%% QoQ\n", obs_qoq))
for (k in 1:2) {
  ck <- agregar_trim_yoy(pan_yoy, cols, k)
  treino <- pib %>% dplyr::select(trim, pib_yoy) %>% dplyr::inner_join(ck, by="trim") %>%
            dplyr::filter(trim < ALVO)
  mapa <- ajustar_mapa(treino, cols)
  linha <- ck %>% dplyr::filter(trim == ALVO)
  yoy_p <- prever_mapa(mapa, linha[, cols, drop=FALSE])
  qoq_p <- yoy_para_qoq(yoy_p, idx_lag1, idx_lag4)
  cat(sprintf("  early-read k=%d: QoQ=%+.2f%%  erro=%+.2f p.p.\n", k, qoq_p, obs_qoq - qoq_p))
}
cat("Referencia bridge (k=1) erro ~ +0,91 p.p.; (k=2) ~ +0,64 p.p.\n")
```

- [ ] **Step 2: Rodar e avaliar o gate**

Run: `Rscript diag_backtest_q1.R`
Expected: imprime os erros do early-read para k=1 e k=2.
**Critério de aceite:** `|erro early-read k=1|` < `0,91` (erro do bridge no mesmo vintage). Se falhar, voltar à seção 7 (revisar composição da cesta) antes de prosseguir — não ajustar parâmetros às cegas.

- [ ] **Step 3: Registrar o resultado do gate**

Anotar o resultado observado (números reais) na seção "Notas" do CHANGELOG na Task 10. Se o gate falhar, parar e reportar ao usuário para decisão sobre a cesta.

---

## Task 10: Documentação e fechamento

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Atualizar `CHANGELOG.md`**

Em `## [Não lançado]`, dentro de (ou criando) `### Adicionado`, acrescentar:

```markdown
- Módulo early-read (`nowcast_early_read.R`): projeção precoce de PIB QoQ/YoY
  com banda por vintage, a partir de indicadores rápidos (SGS + Ipeadata).
  Backtest 2026T1 (k=1): erro de <RESULTADO> p.p. vs +0,91 do bridge.
```

Substituir `<RESULTADO>` pelo número real medido na Task 9.

- [ ] **Step 2: Atualizar `CLAUDE.md`**

Na tabela/seção de versionamento de arquivos (final do arquivo), adicionar linha:

```markdown
| `nowcast_early_read.R` | **módulo paralelo** — early-read precoce via indicadores rápidos (SGS+Ipeadata); QoQ/YoY com banda por vintage. Não substitui o oficial. |
```

- [ ] **Step 3: Rodar a suíte de testes uma última vez**

Run: `Rscript tests/test_early_read.R`
Expected: `OK: todos os testes passaram`.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md CLAUDE.md
git commit -m "docs(early-read): registra modulo no CHANGELOG e CLAUDE.md"
```

---

## Self-review notes (preenchido pelo autor do plano)

- **Cobertura do spec:** seção 4 (estrutura) → Tasks 1,7,8; seção 5.1 YoY → Task 2; 5.2 PCA → Task 5; 5.3 ragged edge → Task 3; 5.4 banda vintage → Task 6; seção 6 fluxo → Task 8; seção 7 cesta → Task 7 (`SGS_RAPIDOS`/`IPEA_RAPIDOS`); seção 8 output → Task 8; seção 10 validação → Tasks 6 e 9; seção 9 docs → Task 10.
- **Consistência de nomes:** `to_yoy`, `agregar_trim_yoy(df_yoy, cols, k)`, `yoy_para_qoq(yoy_prev, idx_lag1, idx_lag4)`, `fatores_pca(mat, n_pc)`, `ajustar_mapa(dados_trim, cols, n_pc)`, `prever_mapa(mapa, linha_cols)`, `oos_vintage_pronto(...)`, `oos_vintage(...)`, `baixar_rapidos(...)`, `cols_cesta(painel)` — usados de forma idêntica entre tasks.
- **Risco aberto conhecido:** `comex_exp/comex_imp` (SGS 22707/22708) e o código Ipeadata `CNI12_ICEIGER12`/`ABPO12_PAPEL12` devem ser confirmados no primeiro run da Task 7; se algum não retornar, removê-lo de `SGS_RAPIDOS`/`IPEA_RAPIDOS` (mínimo viável de 4 séries, conforme spec).
