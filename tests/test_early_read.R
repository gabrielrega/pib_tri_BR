# Testes unitarios network-free do modulo early-read.
# Rodar: Rscript tests/test_early_read.R
Sys.setenv(EARLY_READ_TEST = "1")
suppressMessages(source("nowcast_early_read.R"))

cat("== test_early_read ==\n")

# (asserts adicionados nas Tasks 2-8)

cat("OK: todos os testes passaram\n")
