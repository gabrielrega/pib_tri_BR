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

# ---- 2. Funcoes puras --------------------------------------

# Converte colunas de nivel para variacao YoY (12 meses).
# Assume painel mensal contiguo e ordenado por data. Mantem 'date'.
to_yoy <- function(df, cols) {
  df <- df[order(df$date), , drop = FALSE]
  for (c in cols) df[[c]] <- (df[[c]] / dplyr::lag(df[[c]], 12) - 1) * 100
  df
}

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
      # 'meses' antes do across: .data[[cols[1]]] deve ler o vetor original
      # do grupo, nao a coluna ja' sumarizada (evita shadowing do nome).
      meses = sum(!is.na(.data[[cols[1]]])),
      dplyr::across(dplyr::all_of(cols), ~ mean(.x, na.rm = TRUE)),
      .groups = "drop"
    )
}

# Converte um YoY previsto do trimestre-alvo em QoQ, usando os indices
# encadeados ja' publicados de t-1 (trimestre anterior) e t-4 (ano antes).
yoy_para_qoq <- function(yoy_prev, idx_lag1, idx_lag4) {
  idx_t <- idx_lag4 * (1 + yoy_prev / 100)
  (idx_t / idx_lag1 - 1) * 100
}

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

# ---- 9. Orquestracao ---------------------------------------
main <- function() {
  cat("[early-read] main() ainda nao implementado\n")
}

if (Sys.getenv("EARLY_READ_TEST") != "1") {
  main()
}
