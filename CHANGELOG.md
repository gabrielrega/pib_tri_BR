# Changelog

Todas as mudanças notáveis deste projeto são documentadas aqui.
Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/);
versionamento conforme [SemVer](https://semver.org/lang/pt-BR/).

## [Não lançado]

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
