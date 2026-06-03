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

cat("OK: todos os testes passaram\n")
