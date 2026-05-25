# ============================================================
# PIB Brasil - Nowcasting trimestral via Bridge Equations
# v2: + AR(1) benchmark
#     + PIB defasado no full
#     + dummies COVID
#     + decomposicao do erro por subperiodo
# ============================================================

# ---- 0. Setup ----------------------------------------------
pacotes <- c("rbcb", "sidrar", "dplyr", "tidyr", "lubridate",
             "purrr", "tibble", "ggplot2")
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
    trim    = yq(`Trimestre (Codigo)`),
    pib_idx = as.numeric(Valor)
  ) %>%
  arrange(trim) %>%
  mutate(
    pib_qoq      = (pib_idx / lag(pib_idx)    - 1) * 100,
    pib_yoy      = (pib_idx / lag(pib_idx, 4) - 1) * 100,
    pib_qoq_lag1 = lag(pib_qoq)
  )

message("[2/3] Baixando indicadores mensais (BCB/SGS)...")
codigos <- c(ibc = 24363, pim = 21859, pmc = 1455)
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
    meses_disp = sum(!is.na(ibc)),
    .groups    = "drop"
  ) %>%
  mutate(across(c(ibc, pim, pmc),
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

form_full1 <- as.formula(paste(ALVO, "~ ibc_qoq + pim_qoq + pmc_qoq"))

form_full2 <- as.formula(paste(
  ALVO, "~ pib_qoq_lag1 + ibc_qoq + pim_qoq + pmc_qoq +",
  paste(nomes_dummies, collapse = " + ")
))

# Estimacao in-sample (referencia)
m_ar1   <- lm(form_ar1,   data = dados %>% drop_na(pib_qoq_lag1))
m_full1 <- lm(form_full1, data = dados %>% drop_na(ibc_qoq, pim_qoq, pmc_qoq))
m_full2 <- lm(form_full2, data = dados %>%
                drop_na(pib_qoq_lag1, ibc_qoq, pim_qoq, pmc_qoq))

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
  drop_na(pib_qoq_lag1, ibc_qoq, pim_qoq, pmc_qoq, !!sym(ALVO))

eval_ar1   <- roll_eval(form_ar1,   dados_eval) %>% mutate(modelo = "AR(1)")
eval_full1 <- roll_eval(form_full1, dados_eval) %>% mutate(modelo = "full v1")
eval_full2 <- roll_eval(form_full2, dados_eval) %>% mutate(modelo = "full v2")

eval_all <- bind_rows(eval_ar1, eval_full1, eval_full2)

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

trim_atual <- as.Date(floor_date(Sys.Date(), "quarter"))

# Para o full v2 precisamos do pib_qoq do trimestre anterior
ultimo_pib_qoq <- pib %>%
  filter(!is.na(pib_qoq)) %>%
  slice_tail(n = 1) %>%
  pull(pib_qoq)

x_atual <- indic_trim %>%
  filter(trim == trim_atual) %>%
  mutate(pib_qoq_lag1 = ultimo_pib_qoq)

# As dummies COVID sao zero no presente (assumindo trim_atual nao
# coincide com COVID_TRIMESTRES)
for (nome in nomes_dummies) x_atual[[nome]] <- 0L

cat(sprintf("\n========== Nowcast %dT%d ==========\n",
            year(trim_atual), quarter(trim_atual)))

if (nrow(x_atual) == 0 || is.na(x_atual$ibc_qoq)) {
  cat("[!] Sem dados suficientes do trimestre corrente.\n")
} else {
  prev <- c(
    "AR(1)"   = predict(m_ar1,   newdata = x_atual),
    "full v1" = predict(m_full1, newdata = x_atual),
    "full v2" = predict(m_full2, newdata = x_atual)
  )
  cat(sprintf("Meses ja divulgados no trimestre: %d/3\n",
              x_atual$meses_disp))
  cat(sprintf("PIB QoQ realizado no trimestre anterior: %+.2f%%\n",
              ultimo_pib_qoq))
  for (k in seq_along(prev)) {
    cat(sprintf("  %-10s %+.2f%%\n", names(prev)[k], prev[k]))
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
