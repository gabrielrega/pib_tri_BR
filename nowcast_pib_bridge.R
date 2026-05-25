# ============================================================
# PIB Brasil — Nowcasting trimestral via Bridge Equations
# ============================================================
# Pipeline minimalista em um único arquivo:
#   1. Coleta PIB trimestral (alvo) e indicadores mensais
#   2. Agrega séries mensais -> média trimestral
#   3. Estima bridge equation por OLS
#   4. Avalia performance pseudo-out-of-sample (rolling)
#   5. Projeta trimestre corrente com meses já disponíveis
#
# Fontes:
#   - PIB trimestral: IBGE/SIDRA, tabela 1621 (índice volume SA)
#   - Indicadores mensais: BCB/SGS via pacote rbcb
# ============================================================

# ---- 0. Setup ----------------------------------------------
pacotes <- c("rbcb", "sidrar", "dplyr", "tidyr", "lubridate",
             "purrr", "tibble", "broom", "ggplot2")
novos <- setdiff(pacotes, rownames(installed.packages()))
if (length(novos) > 0) install.packages(novos)
invisible(lapply(pacotes, library, character.only = TRUE))

options(scipen = 999)

# ---- 1. Parâmetros -----------------------------------------
DATA_INICIO <- as.Date("2003-01-01")
DATA_FIM    <- Sys.Date()
ALVO        <- "pib_qoq"   # alternativa: "pib_yoy"
MIN_OBS_OOS <- 24          # mínimo de trimestres para iniciar OOS

# ---- 2. Coleta de dados ------------------------------------

## 2.1 PIB trimestral (IBGE, Tab. 1621)
## Variável 584: índice encadeado de volume trimestral c/ ajuste sazonal
## Categoria 90707: PIB a preços de mercado
## (Se 1621 for descontinuada, alternativa atual é a tab. 6612)
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
    pib_qoq = (pib_idx / lag(pib_idx)     - 1) * 100,
    pib_yoy = (pib_idx / lag(pib_idx, 4)  - 1) * 100
  )

## 2.2 Indicadores mensais (BCB/SGS)
## Códigos (verifique com rbcb::search_series() se houver dúvida):
##   - IBC-Br dessazonalizado: 24363
##   - PIM-PF Indústria Geral dessaz: 21859
##   - PMC Varejo Ampliado dessaz: 1455
## Para PMS / outros, adicionar aqui.
message("[2/3] Baixando indicadores mensais (BCB/SGS)...")
codigos <- c(
  ibc = 24363,
  pim = 21859,
  pmc = 1455
)

indic_raw <- rbcb::get_series(
  codigos,
  start_date = DATA_INICIO,
  end_date   = DATA_FIM
)

indic <- reduce(indic_raw, full_join, by = "date") %>%
  arrange(date) %>%
  mutate(date = as.Date(date))

# ---- 3. Transformações -------------------------------------

message("[3/3] Agregando mensal -> trimestral...")

# Agrega por média do trimestre. Para ragged-edge (trimestre incompleto),
# usa a média dos meses disponíveis. Refinamento futuro: projetar
# meses faltantes via AR antes da agregação.
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

# ---- 4. Bridge equation ------------------------------------

dados <- pib %>%
  inner_join(indic_trim, by = "trim") %>%
  filter(!is.na(.data[[ALVO]]))

# Modelo full
form_full  <- as.formula(paste(ALVO, "~ ibc_qoq + pim_qoq + pmc_qoq"))
bridge_full <- lm(form_full,
                  data = dados %>% drop_na(ibc_qoq, pim_qoq, pmc_qoq))

# Modelo benchmark: só IBC-Br
form_ibc   <- as.formula(paste(ALVO, "~ ibc_qoq"))
bridge_ibc <- lm(form_ibc, data = dados %>% drop_na(ibc_qoq))

cat("\n========== Bridge full (IBC + PIM + PMC) ==========\n")
print(summary(bridge_full))
cat("\n========== Bridge benchmark (só IBC-Br) ==========\n")
print(summary(bridge_ibc))

# ---- 5. Avaliação pseudo-out-of-sample ---------------------

# Janela expansiva: usa dados [1, t-1] para prever t
roll_eval <- function(form, df, min_obs = MIN_OBS_OOS) {
  out <- list()
  for (i in (min_obs + 1):nrow(df)) {
    treino <- df[1:(i - 1), ] %>% drop_na(all.vars(form))
    teste  <- df[i, ]
    if (nrow(treino) < 10) next
    mod   <- lm(form, data = treino)
    pred  <- predict(mod, newdata = teste)
    out[[i]] <- tibble(
      trim = teste$trim,
      obs  = teste[[as.character(form)[2]]],
      pred = as.numeric(pred)
    )
  }
  bind_rows(out) %>%
    mutate(erro = obs - pred, erro_abs = abs(erro))
}

dados_eval <- dados %>%
  drop_na(ibc_qoq, pim_qoq, pmc_qoq, !!sym(ALVO))

eval_full <- roll_eval(form_full, dados_eval)
eval_ibc  <- roll_eval(form_ibc,  dados_eval)

cat("\n========== Performance pseudo-OOS ==========\n")
metricas <- bind_rows(
  eval_full %>% summarise(
    modelo = "full",
    RMSE   = sqrt(mean(erro^2,    na.rm = TRUE)),
    MAE    = mean(erro_abs,       na.rm = TRUE),
    bias   = mean(erro,           na.rm = TRUE),
    n      = sum(!is.na(erro))
  ),
  eval_ibc %>% summarise(
    modelo = "só IBC-Br",
    RMSE   = sqrt(mean(erro^2,    na.rm = TRUE)),
    MAE    = mean(erro_abs,       na.rm = TRUE),
    bias   = mean(erro,           na.rm = TRUE),
    n      = sum(!is.na(erro))
  )
)
print(metricas)

# ---- 6. Nowcast do trimestre corrente ----------------------

trim_atual <- as.Date(floor_date(Sys.Date(), "quarter"))
x_atual    <- indic_trim %>% filter(trim == trim_atual)

cat(sprintf("\n========== Nowcast %dT%d ==========\n",
            year(trim_atual), quarter(trim_atual)))

if (nrow(x_atual) == 0 || is.na(x_atual$ibc_qoq)) {
  cat("[!] Sem dados suficientes do trimestre corrente.\n")
} else {
  prev_full <- tryCatch(predict(bridge_full, newdata = x_atual),
                        error = function(e) NA_real_)
  prev_ibc  <- predict(bridge_ibc, newdata = x_atual)

  cat(sprintf("Meses já divulgados no trimestre: %d/3\n",
              x_atual$meses_disp))
  cat(sprintf("Bridge full (IBC + PIM + PMC) : %+.2f%% %s\n",
              prev_full, toupper(sub("pib_", "", ALVO))))
  cat(sprintf("Bridge só IBC-Br              : %+.2f%% %s\n",
              prev_ibc,  toupper(sub("pib_", "", ALVO))))
}

# ---- 7. Visualização ---------------------------------------

p <- eval_full %>%
  pivot_longer(cols = c(obs, pred), names_to = "serie") %>%
  ggplot(aes(trim, value, color = serie)) +
  geom_line(linewidth = 0.7) +
  geom_hline(yintercept = 0, linetype = "dotted") +
  scale_color_manual(values = c(obs = "black", pred = "steelblue"),
                     labels = c("Realizado", "Previsto (bridge full)")) +
  labs(title = "Bridge equation — pseudo-OOS",
       subtitle = sprintf("Alvo: %s | RMSE: %.2f", ALVO,
                          metricas$RMSE[metricas$modelo == "full"]),
       x = NULL, y = paste0(ALVO, " (%)"), color = NULL) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom")

print(p)

# ---- 8. Salvar resultados (opcional) -----------------------
# saveRDS(list(bridge_full = bridge_full,
#              bridge_ibc  = bridge_ibc,
#              eval_full   = eval_full,
#              eval_ibc    = eval_ibc,
#              metricas    = metricas),
#         file = "bridge_results.rds")

# ============================================================
# Próximos refinamentos sugeridos:
#   - Projetar meses faltantes do trimestre via AR(p) antes
#     da agregação (Mariano-Murasawa style)
#   - Adicionar PMS, confiança FGV, PMI, energia (ONS)
#   - Variável defasada do PIB como regressor (persistência)
#   - Bridge com seleção via BIC ou LASSO sobre pool maior
#   - Comparar com benchmark AR(1) puro do PIB
# ============================================================
