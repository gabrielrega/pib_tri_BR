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
cat("OK: agregar_trim_yoy\n")

cat("OK: todos os testes passaram\n")
