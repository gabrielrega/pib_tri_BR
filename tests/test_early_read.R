# Testes unitarios network-free do modulo early-read.
# Rodar: Rscript tests/test_early_read.R
Sys.setenv(EARLY_READ_TEST = "1")
suppressMessages(source("nowcast_early_read.R"))

cat("== test_early_read ==\n")

# (asserts adicionados nas Tasks 2-8)

# to_yoy: valor sobe de 100 para 110 doze meses depois => YoY = 10
df_t2 <- data.frame(
  date = seq(as.Date("2020-01-01"), by = "month", length.out = 24),
  x    = c(rep(100, 12), rep(110, 12))
)
r2 <- to_yoy(df_t2, "x")
stopifnot(is.na(r2$x[1]))                       # sem base 12m no inicio
stopifnot(abs(r2$x[13] - 10) < 1e-9)            # 110/100 - 1 = 10%
cat("OK: to_yoy\n")

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
# ragged edge: mes presente na grade mas indicador ainda NA nao conta em 'meses'
df_t3b <- data.frame(
  date = as.Date(c("2021-01-01","2021-02-01","2021-03-01")),
  x    = c(2, NA, NA)
)
a_k3b <- agregar_trim_yoy(df_t3b, "x", k = 3)
stopifnot(a_k3b$meses == 1)              # so' janeiro tem dado
stopifnot(abs(a_k3b$x - 2) < 1e-9)       # media ignora NAs
cat("OK: agregar_trim_yoy\n")

# yoy_para_qoq: idx_lag4=100, yoy=4 => idx_t=104; idx_lag1=103 => qoq ~ 0.9709
q4 <- yoy_para_qoq(yoy_prev = 4, idx_lag1 = 103, idx_lag4 = 100)
stopifnot(abs(q4 - ((104/103 - 1) * 100)) < 1e-9)
cat("OK: yoy_para_qoq\n")

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

# excluir_covid_banda: tira 2020T2..2021T2 do pool de erros da banda
df_cov <- tibble::tibble(
  trim = as.Date(c("2019-01-01","2020-07-01","2021-01-01","2022-01-01")),
  erro = c(1, 999, 999, 2)
)
kept <- excluir_covid_banda(df_cov)
stopifnot(nrow(kept) == 2)
stopifnot(all(kept$trim %in% as.Date(c("2019-01-01","2022-01-01"))))
cat("OK: excluir_covid_banda\n")

cat("OK: todos os testes passaram\n")
