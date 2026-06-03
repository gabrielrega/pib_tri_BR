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

# ---- 9. Orquestracao ---------------------------------------
main <- function() {
  cat("[early-read] main() ainda nao implementado\n")
}

if (Sys.getenv("EARLY_READ_TEST") != "1") {
  main()
}
