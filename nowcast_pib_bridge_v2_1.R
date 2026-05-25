# ============================================================
# PIB Brasil - Nowcasting trimestral via Bridge Equations
# v2: + AR(1) benchmark
#     + PIB defasado no full
#     + dummies COVID
#     + decomposicao do erro por subperiodo
# ============================================================

# ---- 0. Setup ----------------------------------------------
pacotes <- c("rbcb", "sidrar", "dplyr", "tidyr", "lubridate",
             "purrr", "tibble", "ggplot2", "midasr")
novos <- setdiff(pacotes, rownames(installed.packages()))
if (length(novos) > 0) install.packages(novos)
invisible(lapply(pacotes, library, character.only = TRUE))

options(scipen = 999)

# ---- 1. Parametros -----------------------------------------
DATA_INICIO <- as.Date("2003-01-01")
DATA_FIM    <- Sys.Date()
ALVO        <- "pib_qoq"
MIN_OBS_OOS <- 24

# Trimestres marcados com dummy COVID (1 em t, 0 c.c.).
# Default: maior queda (2020T2) e maior rebote (2020T3).
COVID_TRIMESTRES <- as.Date(c("2020-04-01", "2020-07-01"))

# Cortes para decomposicao do erro por subperiodo
CORTE_COVID_INI <- as.Date("2020-01-01")
CORTE_COVID_FIM <- as.Date("2021-12-31")

# ---- 2. Coleta de dados ------------------------------------

message("[1/3] Baixando PIB trimestral (IBGE/SIDRA)...")
pib_raw <- get_sidra(
  x         = 1621,
  variable  = 584,
  period    = "all",
  classific = "c11255",
  category  = list(90707),
  format    = 4
)
pib <- pib_raw %>%
  transmute(
    trim    = yq(`Trimestre (Código)`),
    pib_idx = as.numeric(Valor)
  ) %>%
  arrange(trim) %>%
  mutate(
    pib_qoq      = (pib_idx / lag(pib_idx)    - 1) * 100,
    pib_yoy      = (pib_idx / lag(pib_idx, 4) - 1) * 100,
    pib_qoq_lag1 = lag(pib_qoq)
  )

message("[2/3] Baixando indicadores mensais (BCB/SGS)...")
codigos <- c(ibc = 24363, pim = 21859, pmc = 1455, pms = 25405)
indic_raw <- rbcb::get_series(codigos,
                              start_date = DATA_INICIO,
                              end_date   = DATA_FIM)
indic <- reduce(indic_raw, full_join, by = "date") %>%
  arrange(date) %>%
  mutate(date = as.Date(date))

message("[3/3] Agregando mensal -> trimestral...")
indic_trim <- indic %>%
  mutate(trim = as.Date(floor_date(date, "quarter"))) %>%
  group_by(trim) %>%
  summarise(
    ibc        = mean(ibc, na.rm = TRUE),
    pim        = mean(pim, na.rm = TRUE),
    pmc        = mean(pmc, na.rm = TRUE),
    pms        = mean(pms, na.rm = TRUE),
    meses_disp = sum(!is.na(ibc)),
    .groups    = "drop"
  ) %>%
  mutate(across(c(ibc, pim, pmc, pms),
                ~ (.x / lag(.x) - 1) * 100,
                .names = "{.col}_qoq"))

# ---- 3. Dummies COVID --------------------------------------

dados <- pib %>%
  inner_join(indic_trim, by = "trim") %>%
  filter(!is.na(.data[[ALVO]]))

nomes_dummies <- paste0("d_covid_", format(COVID_TRIMESTRES, "%Y%m"))
for (i in seq_along(COVID_TRIMESTRES)) {
  dados[[nomes_dummies[i]]] <- as.integer(dados$trim == COVID_TRIMESTRES[i])
}

# ---- 4. Especificacoes -------------------------------------

form_ar1   <- as.formula(paste(ALVO, "~ pib_qoq_lag1"))

form_full1 <- as.formula(paste(ALVO, "~ ibc_qoq + pim_qoq + pmc_qoq + pms_qoq"))

form_full2 <- as.formula(paste(
  ALVO, "~ pib_qoq_lag1 + ibc_qoq + pim_qoq + pmc_qoq + pms_qoq +",
  paste(nomes_dummies, collapse = " + ")
))

# Estimacao in-sample (referencia)
m_ar1   <- lm(form_ar1,   data = dados %>% drop_na(pib_qoq_lag1))
m_full1 <- lm(form_full1, data = dados %>% drop_na(ibc_qoq, pim_qoq, pmc_qoq, pms_qoq))
m_full2 <- lm(form_full2, data = dados %>%
                drop_na(pib_qoq_lag1, ibc_qoq, pim_qoq, pmc_qoq, pms_qoq))

cat("\n========== AR(1) puro ==========\n");        print(summary(m_ar1))
cat("\n========== Bridge full v1 ==========\n");    print(summary(m_full1))
cat("\n========== Bridge full v2 ==========\n");    print(summary(m_full2))

# ---- 5. Pseudo-OOS rolling ---------------------------------

# Pega vars de uma formula como string
vars_da_form <- function(form) all.vars(form)

roll_eval <- function(form, df, min_obs = MIN_OBS_OOS) {
  vars_need <- vars_da_form(form)
  out <- list()
  for (i in (min_obs + 1):nrow(df)) {
    treino <- df[1:(i - 1), ] %>% drop_na(any_of(vars_need))
    teste  <- df[i, ]
    if (nrow(treino) < 10) next
    if (any(is.na(teste[, setdiff(vars_need, as.character(form)[2])]))) next
    # Drop preditores com variancia zero no treino (ex: dummies covid
    # ainda nao observadas em janelas curtas)
    preds <- setdiff(vars_need, as.character(form)[2])
    sd_tr <- sapply(treino[preds], function(x) sd(x, na.rm = TRUE))
    preds_vivos <- preds[!is.na(sd_tr) & sd_tr > 0]
    form_ef <- as.formula(paste(as.character(form)[2], "~",
                                paste(preds_vivos, collapse = " + ")))
    mod <- tryCatch(lm(form_ef, data = treino), error = function(e) NULL)
    if (is.null(mod)) next
    pred <- tryCatch(predict(mod, newdata = teste),
                     error = function(e) NA_real_)
    out[[i]] <- tibble(trim = teste$trim,
                       obs  = teste[[as.character(form)[2]]],
                       pred = as.numeric(pred))
  }
  bind_rows(out) %>%
    mutate(erro = obs - pred, erro_abs = abs(erro))
}

# Base comum para garantir comparabilidade dos modelos
dados_eval <- dados %>%
  drop_na(pib_qoq_lag1, ibc_qoq, pim_qoq, pmc_qoq, pms_qoq, !!sym(ALVO))

eval_ar1   <- roll_eval(form_ar1,   dados_eval) %>% mutate(modelo = "AR(1)")
eval_full1 <- roll_eval(form_full1, dados_eval) %>% mutate(modelo = "full v1")
eval_full2 <- roll_eval(form_full2, dados_eval) %>% mutate(modelo = "full v2")

eval_all <- bind_rows(eval_ar1, eval_full1, eval_full2)

# ---- 5b. Ragged edge: avaliacao por vintage ----------------
# Reconstroi os indicadores trimestrais usando apenas os primeiros k meses
# de cada trimestre, simulando o que estava disponivel em tempo real.

make_dados_vintage <- function(k_meses) {
  vint <- indic %>%
    mutate(
      trim        = as.Date(floor_date(date, "quarter")),
      mes_no_trim = (month(date) - 1) %% 3 + 1
    ) %>%
    filter(mes_no_trim <= k_meses) %>%
    group_by(trim) %>%
    summarise(
      ibc = mean(ibc, na.rm = TRUE),
      pim = mean(pim, na.rm = TRUE),
      pmc = mean(pmc, na.rm = TRUE),
      pms = mean(pms, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(across(c(ibc, pim, pmc, pms),
                  ~ (.x / lag(.x) - 1) * 100,
                  .names = "{.col}_qoq"))

  d <- pib %>%
    inner_join(vint, by = "trim") %>%
    filter(!is.na(.data[[ALVO]]))
  for (i in seq_along(COVID_TRIMESTRES))
    d[[nomes_dummies[i]]] <- as.integer(d$trim == COVID_TRIMESTRES[i])
  d %>% drop_na(pib_qoq_lag1, ibc_qoq, pim_qoq, pmc_qoq, pms_qoq, !!sym(ALVO))
}

eval_vintage <- map_dfr(1:3, function(k) {
  dv <- make_dados_vintage(k)
  bind_rows(
    roll_eval(form_ar1,   dv) %>% mutate(modelo = "AR(1)"),
    roll_eval(form_full1, dv) %>% mutate(modelo = "full v1"),
    roll_eval(form_full2, dv) %>% mutate(modelo = "full v2")
  ) %>% mutate(vintage = k)
})

cat("\n========== RMSE por vintage (meses disponiveis no trimestre) ==========\n")
print(
  eval_vintage %>%
    group_by(modelo, vintage) %>%
    summarise(RMSE = sqrt(mean(erro^2, na.rm = TRUE)), n = sum(!is.na(erro)),
              .groups = "drop") %>%
    pivot_wider(names_from = vintage, values_from = RMSE, names_prefix = "v") %>%
    arrange(modelo)
)

# ---- 5c. Combinacao de modelos -----------------------------
# Pesos inversamente proporcionais ao RMSE OOS, calculados por vintage.

combo_pesos <- eval_vintage %>%
  filter(modelo != "AR(1)") %>%
  group_by(vintage, modelo) %>%
  summarise(rmse = sqrt(mean(erro^2, na.rm = TRUE)), .groups = "drop") %>%
  group_by(vintage) %>%
  mutate(peso = (1 / rmse) / sum(1 / rmse)) %>%
  ungroup()

eval_combo <- eval_vintage %>%
  left_join(combo_pesos %>% select(vintage, modelo, peso),
            by = c("vintage", "modelo")) %>%
  group_by(vintage, trim) %>%
  summarise(
    obs  = first(obs),
    pred = sum(pred * peso, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(erro = obs - pred, erro_abs = abs(erro), modelo = "combo")

cat("\n========== RMSE: individuais + combo por vintage ==========\n")
print(
  bind_rows(
    eval_vintage %>%
      group_by(vintage, modelo) %>%
      summarise(RMSE = sqrt(mean(erro^2, na.rm = TRUE)), .groups = "drop"),
    eval_combo %>%
      group_by(vintage, modelo) %>%
      summarise(RMSE = sqrt(mean(erro^2, na.rm = TRUE)), .groups = "drop")
  ) %>%
    pivot_wider(names_from = modelo, values_from = RMSE) %>%
    arrange(vintage)
)

# ---- 5d. MIDAS (Mixed Data Sampling) ----------------------
# Usa os indicadores na frequencia mensal diretamente, sem agregar
# para trimestral. Pesos nealmon (exponential Almon) por indicador.
# Periodo: Q1 2003 em diante (quando todos os 4 indicadores arrancam).

T0_MIDAS <- as.Date("2003-01-01")

pib_midas <- pib %>%
  filter(trim >= T0_MIDAS, !is.na(pib_qoq)) %>%
  arrange(trim)

ind_midas <- indic %>%
  filter(date >= T0_MIDAS) %>%
  arrange(date) %>%
  slice(1:(nrow(pib_midas) * 3))

y_m   <- ts(pib_midas$pib_qoq, start = c(2003, 1), frequency = 4)
ibc_m <- ts(ind_midas$ibc,     start = c(2003, 1), frequency = 12)
pim_m <- ts(ind_midas$pim,     start = c(2003, 1), frequency = 12)
pmc_m <- ts(ind_midas$pmc,     start = c(2003, 1), frequency = 12)
pms_m <- ts(ind_midas$pms,     start = c(2003, 1), frequency = 12)

# Ajuste in-sample (usados tambem no nowcast)
message("[MIDAS] Ajustando modelos in-sample...")

m_midas <- tryCatch(
  midas_r(
    y_m ~ mls(ibc_m, 0:5, 3, nealmon) + mls(pim_m, 0:5, 3, nealmon) +
          mls(pmc_m, 0:5, 3, nealmon) + mls(pms_m, 0:5, 3, nealmon),
    start = list(ibc_m = c(0, 0), pim_m = c(0, 0),
                 pmc_m = c(0, 0), pms_m = c(0, 0))
  ),
  error = function(e) { cat("[!] MIDAS nealmon IS:", conditionMessage(e), "\n"); NULL }
)

m_umidas <- tryCatch(
  midas_r(
    y_m ~ mls(ibc_m, 0:5, 3) + mls(pim_m, 0:5, 3) +
          mls(pmc_m, 0:5, 3) + mls(pms_m, 0:5, 3),
    start = NULL
  ),
  error = function(e) { cat("[!] UMIDAS IS:", conditionMessage(e), "\n"); NULL }
)

r2 <- function(mod) round(1 - sum(residuals(mod)^2) / sum((fitted(mod) + residuals(mod) - mean(fitted(mod) + residuals(mod)))^2), 3)

cat(sprintf("\n========== MIDAS in-sample ==========\n"))
if (!is.null(m_midas))  cat(sprintf("  nealmon : R2 = %.3f\n", r2(m_midas)))
if (!is.null(m_umidas)) cat(sprintf("  UMIDAS  : R2 = %.3f\n", r2(m_umidas)))

# Rolling OOS: nealmon e UMIDAS no mesmo loop
message("[MIDAS] Rolling OOS (nealmon + UMIDAS)...")

mk_tr <- function(x_full, n_q)
  ts(as.numeric(x_full)[1:(3 * n_q)], start = c(2003, 1), frequency = 12)

mk_ext <- function(x_tr, x_full, i)
  ts(c(as.numeric(x_tr), as.numeric(x_full)[(3*(i-1)+1):(3*i)]),
     start = c(2003, 1), frequency = 12)

pred_midas_step <- function(mod, ibc_tr, pim_tr, pmc_tr, pms_tr, i) {
  tryCatch(
    as.numeric(tail(
      forecast(mod,
               newdata = list(ibc_tr = mk_ext(ibc_tr, ibc_m, i),
                              pim_tr = mk_ext(pim_tr, pim_m, i),
                              pmc_tr = mk_ext(pmc_tr, pmc_m, i),
                              pms_tr = mk_ext(pms_tr, pms_m, i)),
               horizon = 1)$mean, 1)),
    error = function(e) NA_real_
  )
}

T_m <- length(y_m)

eval_midas_oos <- map_dfr((MIN_OBS_OOS + 1):T_m, function(i) {
  y_tr   <- ts(as.numeric(y_m)[1:(i-1)], start = c(2003,1), frequency = 4)
  ibc_tr <- mk_tr(ibc_m, i-1)
  pim_tr <- mk_tr(pim_m, i-1)
  pmc_tr <- mk_tr(pmc_m, i-1)
  pms_tr <- mk_tr(pms_m, i-1)

  obs_i <- as.numeric(y_m)[i]
  trim_i <- pib_midas$trim[i]

  # nealmon
  mod_n <- tryCatch(
    midas_r(
      y_tr ~ mls(ibc_tr,0:5,3,nealmon) + mls(pim_tr,0:5,3,nealmon) +
             mls(pmc_tr,0:5,3,nealmon) + mls(pms_tr,0:5,3,nealmon),
      start = list(ibc_tr=c(0,0), pim_tr=c(0,0), pmc_tr=c(0,0), pms_tr=c(0,0))
    ),
    error = function(e) NULL
  )

  # UMIDAS (OLS - sempre converge)
  mod_u <- tryCatch(
    midas_r(y_tr ~ mls(ibc_tr,0:5,3) + mls(pim_tr,0:5,3) +
                   mls(pmc_tr,0:5,3) + mls(pms_tr,0:5,3),
            start = NULL),
    error = function(e) NULL
  )

  bind_rows(
    if (!is.null(mod_n)) tibble(trim=trim_i, obs=obs_i,
      pred=pred_midas_step(mod_n,ibc_tr,pim_tr,pmc_tr,pms_tr,i), modelo="MIDAS"),
    if (!is.null(mod_u)) tibble(trim=trim_i, obs=obs_i,
      pred=pred_midas_step(mod_u,ibc_tr,pim_tr,pmc_tr,pms_tr,i), modelo="UMIDAS")
  )
}) %>%
  mutate(erro = obs - pred, erro_abs = abs(erro))

# Comparacao no periodo comum (pos-2003)
periodo_m <- range(eval_midas_oos$trim, na.rm = TRUE)
comp_midas <- bind_rows(
  eval_all %>%
    filter(trim >= periodo_m[1], trim <= periodo_m[2]) %>%
    group_by(modelo) %>%
    summarise(RMSE = sqrt(mean(erro^2, na.rm=TRUE)),
              MAE  = mean(erro_abs, na.rm=TRUE),
              n    = sum(!is.na(erro)), .groups="drop"),
  eval_midas_oos %>%
    group_by(modelo) %>%
    summarise(RMSE = sqrt(mean(erro^2, na.rm=TRUE)),
              MAE  = mean(erro_abs, na.rm=TRUE),
              n    = sum(!is.na(erro)), .groups="drop")
) %>% arrange(RMSE)

cat("\n========== RMSE OOS: MIDAS/UMIDAS vs Bridge (periodo pos-2003) ==========\n")
print(comp_midas)

# ---- 6. Decomposicao por subperiodo ------------------------

classificar_periodo <- function(d) {
  case_when(
    d <  CORTE_COVID_INI ~ "1) pre-COVID",
    d <= CORTE_COVID_FIM ~ "2) COVID",
    TRUE                 ~ "3) pos-COVID"
  )
}

# Metricas gerais
metricas_geral <- eval_all %>%
  group_by(modelo) %>%
  summarise(
    RMSE = sqrt(mean(erro^2,  na.rm = TRUE)),
    MAE  = mean(erro_abs,     na.rm = TRUE),
    bias = mean(erro,         na.rm = TRUE),
    n    = sum(!is.na(erro)),
    .groups = "drop"
  )

# Metricas por subperiodo
metricas_periodo <- eval_all %>%
  mutate(periodo = classificar_periodo(trim)) %>%
  group_by(modelo, periodo) %>%
  summarise(
    RMSE = sqrt(mean(erro^2,  na.rm = TRUE)),
    MAE  = mean(erro_abs,     na.rm = TRUE),
    bias = mean(erro,         na.rm = TRUE),
    n    = sum(!is.na(erro)),
    .groups = "drop"
  ) %>%
  arrange(periodo, modelo)

cat("\n========== Performance pseudo-OOS - geral ==========\n")
print(metricas_geral)

cat("\n========== Performance pseudo-OOS - por subperiodo ==========\n")
print(metricas_periodo, n = Inf)

# Tabela wide para leitura rapida
cat("\n========== RMSE por subperiodo (wide) ==========\n")
print(
  metricas_periodo %>%
    select(modelo, periodo, RMSE) %>%
    pivot_wider(names_from = periodo, values_from = RMSE)
)

# ---- 7. Nowcast do trimestre corrente ----------------------

ultimo_trim_pib <- pib %>% filter(!is.na(pib_qoq)) %>% pull(trim) %>% max()
ultimo_pib_qoq  <- pib %>% filter(trim == ultimo_trim_pib) %>% pull(pib_qoq)

# Todos os trimestres apos o ultimo PIB publicado que tenham
# pelo menos um indicador disponivel
trims_fc <- indic_trim %>%
  filter(trim > ultimo_trim_pib) %>%
  filter(!is.na(ibc_qoq) | !is.na(pim_qoq) | !is.na(pmc_qoq) | !is.na(pms_qoq)) %>%
  mutate(pib_qoq_lag1 = ultimo_pib_qoq)

for (nm in nomes_dummies) trims_fc[[nm]] <- 0L

# Re-estima cada modelo usando apenas os preditores disponiveis em df_novo
nowcast_parcial <- function(form, df_treino, df_novo) {
  alvo     <- as.character(form)[2]
  preds    <- setdiff(all.vars(form), alvo)
  preds_ok <- preds[sapply(preds, function(p)
    p %in% names(df_novo) && !is.na(df_novo[[p]]))]
  if (length(preds_ok) == 0) return(NA_real_)
  form_ef <- as.formula(paste(alvo, "~", paste(preds_ok, collapse = " + ")))
  mod <- tryCatch(
    lm(form_ef, data = df_treino %>% drop_na(any_of(c(alvo, preds_ok)))),
    error = function(e) NULL
  )
  if (is.null(mod)) return(NA_real_)
  as.numeric(tryCatch(predict(mod, newdata = df_novo), error = function(e) NA_real_))
}

cat(sprintf("\n========== Nowcast (ultimo PIB: %dT%d = %+.2f%%) ==========\n",
            year(ultimo_trim_pib), quarter(ultimo_trim_pib), ultimo_pib_qoq))

# Indice e base YoY do ultimo trimestre publicado
ultimo_pib_idx <- pib %>% filter(trim == ultimo_trim_pib) %>% pull(pib_idx)

if (nrow(trims_fc) == 0) {
  cat("[!] Sem indicadores disponiveis apos o ultimo PIB publicado.\n")
} else {
  indic_vars <- c("ibc_qoq", "pim_qoq", "pmc_qoq", "pms_qoq")
  pib_idx_ref <- ultimo_pib_idx  # indice acumulado; atualizado entre trimestres

  for (i in seq_len(nrow(trims_fc))) {
    linha <- trims_fc[i, ]
    cat(sprintf("\n--- %dT%d ---\n", year(linha$trim), quarter(linha$trim)))

    disp <- sapply(indic_vars, function(v) !is.na(linha[[v]]))
    cat(sprintf("  Indicadores: %-30s  IBC: %d/3 meses\n",
                paste(sub("_qoq", "", indic_vars[disp]), collapse = ", "),
                linha$meses_disp))

    # Base YoY: indice do mesmo trimestre 4 periodos antes
    trim_base_yoy <- linha$trim - months(12)
    pib_idx_base_yoy <- pib %>%
      filter(trim == trim_base_yoy) %>%
      pull(pib_idx)

    # Previsao MIDAS para este trimestre (com dados parciais)
    # NAs de meses nao divulgados sao preenchidos com o ultimo valor disponivel
    # (LOCF), para que a estrutura de lags do MIDAS seja valida.
    pred_midas_fc <- tryCatch({
      meses_fc <- indic %>%
        filter(date >= linha$trim, date < linha$trim + months(3)) %>%
        arrange(date)
      pad <- 3L - nrow(meses_fc)
      fill_locf <- function(base_ts, new_vals, n_pad) {
        vals <- c(new_vals, rep(NA, n_pad))
        last_known <- tail(na.omit(c(as.numeric(base_ts), new_vals)), 1)
        vals[is.na(vals)] <- last_known
        ts(c(as.numeric(base_ts), vals), start = c(2003,1), frequency = 12)
      }
      as.numeric(tail(
        forecast(m_midas,
                 newdata = list(ibc_m = fill_locf(ibc_m, meses_fc$ibc, pad),
                                pim_m = fill_locf(pim_m, meses_fc$pim, pad),
                                pmc_m = fill_locf(pmc_m, meses_fc$pmc, pad),
                                pms_m = fill_locf(pms_m, meses_fc$pms, pad)),
                 horizon = 1)$mean, 1))
    }, error = function(e) NA_real_)

    prev_qoq <- c(
      "AR(1)"   = predict(m_ar1, newdata = linha),
      "full v1" = nowcast_parcial(form_full1, dados, linha),
      "full v2" = nowcast_parcial(form_full2, dados, linha),
      "MIDAS"   = if (!is.null(m_midas))  pred_midas_fc else NA_real_,
      "UMIDAS"  = if (!is.null(m_umidas)) tryCatch({
        as.numeric(tail(
          forecast(m_umidas,
                   newdata = list(ibc_m = fill_locf(ibc_m, meses_fc$ibc, pad),
                                  pim_m = fill_locf(pim_m, meses_fc$pim, pad),
                                  pmc_m = fill_locf(pmc_m, meses_fc$pmc, pad),
                                  pms_m = fill_locf(pms_m, meses_fc$pms, pad)),
                   horizon = 1)$mean, 1))
      }, error = function(e) NA_real_) else NA_real_
    )

    # Combinacao com pesos do vintage correspondente
    k_vint    <- min(3L, max(1L, as.integer(linha$meses_disp)))
    pesos_k   <- combo_pesos %>% filter(vintage == k_vint) %>%
                   select(modelo, peso) %>% tibble::deframe()
    disp_k    <- pesos_k[!is.na(prev_qoq[names(pesos_k)])]
    disp_k    <- disp_k / sum(disp_k)
    prev_combo <- sum(prev_qoq[names(disp_k)] * disp_k)
    prev_todos <- c(prev_qoq, combo = prev_combo)

    cat(sprintf("  %-10s %8s %8s\n", "Modelo", "QoQ", "YoY"))
    cat(sprintf("  %-10s %8s %8s\n", "------", "---", "---"))
    for (k in seq_along(prev_todos)) {
      if (!is.na(prev_todos[k])) {
        idx_fc  <- pib_idx_ref * (1 + prev_todos[k] / 100)
        yoy_fc  <- if (length(pib_idx_base_yoy) == 1)
                     (idx_fc / pib_idx_base_yoy - 1) * 100
                   else NA_real_
        yoy_str <- if (!is.na(yoy_fc)) sprintf("%+.2f%%", yoy_fc) else "  n/d"
        cat(sprintf("  %-10s %+7.2f%% %8s\n", names(prev_todos)[k], prev_todos[k], yoy_str))
      }
    }
    # Usa o combo como indice de referencia para o proximo trimestre
    pib_idx_ref <- pib_idx_ref * (1 + prev_combo / 100)
  }
}

# ---- 8. Visualizacao ---------------------------------------

p <- eval_all %>%
  ggplot(aes(trim, erro_abs, color = modelo)) +
  geom_line(linewidth = 0.6, alpha = 0.85) +
  geom_vline(xintercept = CORTE_COVID_INI, linetype = "dotted") +
  geom_vline(xintercept = CORTE_COVID_FIM, linetype = "dotted") +
  labs(title = "Erro absoluto por trimestre (pseudo-OOS)",
       subtitle = "Linhas pontilhadas: janela COVID",
       x = NULL, y = "|erro| (p.p.)", color = NULL) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom")

print(p)

# ============================================================
# Leitura esperada:
#  - AR(1) deve dar RMSE baixo no pre-COVID e pos-COVID, mas
#    sofrer em 2020 (estamos pedindo demais da persistencia)
#  - full v1 captura o mensal mas paga caro nos outliers COVID
#  - full v2 deve ganhar em pre/pos pela limpeza dos parametros
#    via dummies, e ganhar em 2020 pelo pib_qoq_lag1
#
# Atencao no roll_eval: ate o modelo "ver" 2020T2, a dummy
# correspondente tem variancia zero no treino e e' descartada.
# Logo, para os proprios trimestres COVID, o ganho das dummies
# e' principalmente IN-SAMPLE (limpeza dos demais betas).
# ============================================================
