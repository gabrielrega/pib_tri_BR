# Changelog

Todas as mudanças notáveis deste projeto são documentadas aqui.
Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/);
versionamento conforme [SemVer](https://semver.org/lang/pt-BR/).

## [Não lançado]

### Modificado
- Combo do bridge agora inclui o AR(1), com pesos inverso-RMSE calculados em
  pool **ex-COVID** (a COVID inflava o RMSE do AR(1) e matava seu peso nos
  vintages curtos, onde ele estabiliza o ruído das proxies). Validação em
  `diag_combo_ar1.R`: RMSE ex-COVID do combo cai em todos os vintages
  (v1 0,80→0,76; v2 0,76→0,72; v3 0,62→0,59); em rupturas tipo 2020 o combo
  piora — trade-off aceito. Nowcast 2026T2 (k=1) desce de +1,10% para +0,95%.

### Corrigido
- Nome do elemento AR(1) em `prev_qoq` (seção 7): `predict()` devolvia vetor
  nomeado e o nome virava `AR(1).1`, o que faria o combo descartar o AR(1)
  silenciosamente no lookup por nome.

### Adicionado
- `RODADAS.md`: registro numerado das rodadas de nowcast (data, alvo, vintage,
  números por modelo, realizado e comentário). Semeado com a retrospectiva do
  2026T1 e a primeira leitura do 2026T2 (2026-07-06: early-read k=2 +0,62%;
  bridge combo k=1 +1,10%).

## [0.2.0] - 2026-06-03

### Adicionado
- Módulo early-read (`nowcast_early_read.R`): projeção precoce de PIB QoQ/YoY
  com banda por vintage, a partir de indicadores rápidos (SGS + Ipeadata:
  produção e licenciamento de veículos, energia, comércio exterior, confiança
  do consumidor ICC e industrial ICEI, papelão ABPO). Features em YoY (mata
  sazonalidade sem X-13), fator PCA → `pib_yoy`, convertido para QoQ via índices
  publicados. Banda do pseudo-OOS estratificada por nº de meses, excluindo a
  janela base-COVID (2020T2–2021T2). Backtest 2026T1 (k=1): erro de **0,34 p.p.**
  vs ~0,91 do bridge — o early-read vê a força do trimestre que o oficial perdeu.

### Modificado
- Documentada limitação conhecida de *ragged edge* no nowcast (ver CLAUDE.md,
  "Limitações conhecidas").

### Notas
- **Avaliação 2026T1 (PIB realizado: +1,10% QoQ).** O nowcast em tempo real
  subestimou fortemente o trimestre (full v1/v2 previam +0,2% a +0,6% com 1–2
  meses de dados). Investigação concluiu que **não houve bug nem erro de
  especificação**: com os 3 meses do trimestre o modelo acerta (erro de
  0,05 p.p.). O miss decorreu de (1) forte aceleração intratrimestral — IBC-Br
  saltou ~10% em março — e (2) ruído de proxies de 1 mês (sinal QoQ de PIM de
  −15,8% com apenas janeiro). Decisão: manter o modelo como está; o episódio é
  uma surpresa de aceleração não-prevísivel no início do trimestre, não um
  parâmetro a corrigir.

## [0.1.0] - 2026-05-25

### Adicionado
- Versão inicial do nowcasting trimestral do PIB do Brasil.
- Bridge equations (full v1 e full v2 com PIB defasado e dummies COVID) e
  benchmark AR(1).
- Modelos MIDAS (nealmon) e UMIDAS sobre indicadores mensais.
- Avaliação pseudo-OOS rolling, análise por *vintage* (1/2/3 meses) e
  combinação de modelos por RMSE inverso.
- Coleta automática de dados (IBGE/SIDRA e BCB/SGS).
