# Design — Módulo *early-read* do PIB trimestral (QoQ + banda)

**Data:** 2026-06-03
**Status:** Aprovado (aguardando revisão do spec)
**Autor:** Gabriel (com Claude)

## 1. Contexto e motivação

O nowcast oficial (`nowcast_pib_bridge_v2_1.R`) depende de quatro indicadores
mensais dessazonalizados do BCB/SGS — IBC-Br (24363), PIM-PF (21859), PMC (1455)
e PMS (25405) — que só são publicados ~45 dias após o mês de referência. Em
03/jun/2026, todos param em **março/2026**, então o modelo não consegue projetar
o **2026T2** (retorna `Sem indicadores disponiveis`).

A avaliação do 2026T1 (ver `CHANGELOG.md` e seção "Limitações conhecidas" do
`CLAUDE.md`) mostrou que o erro daquele trimestre foi de *ragged edge*: com 1–2
meses, a regra de agregação `mean(QoQ dos meses disponíveis)` subestimou um
trimestre de forte aceleração intratrimestral (previu +0,2% a +0,6% vs +1,10%
realizado). Com o trimestre cheio o modelo acerta (erro 0,05 p.p.).

Existem indicadores de divulgação mais rápida que já têm dado de Q2 hoje
(confirmado via sonda em `diag_fast_sources.R`):

| Série | Fonte/código | Último mês (03/jun) |
|---|---|---|
| Produção de autoveículos (Anfavea) | SGS 1373 | abr/2026 |
| Licenciamentos de veículos | SGS 7384 | abr/2026 |
| Consumo de energia elétrica | SGS 1406 | abr/2026 |
| Saldo/fluxo balança comercial | SGS 22709 | abr/2026 |
| Confiança do consumidor (ICC FCESP) | SGS 4393 | **mai/2026** |

O pacote `ipeadatar` instala e funciona (2.899 séries), abrindo acesso a CNI
(ICEI), FGV (construção), ABPO (papelão ondulado), ELETRO/ONS (energia).

## 2. Objetivo

Construir um **módulo early-read separado**, que produz uma **projeção pontual de
PIB QoQ (e YoY) com banda de incerteza larga** para o trimestre corrente, usando
indicadores de divulgação rápida — semanas antes de o nowcast oficial ter dados.

**Não-objetivos (YAGNI):**
- Não altera nem importa `nowcast_pib_bridge_v2_1.R`. Risco isolado.
- Não substitui o número oficial — é leitura preliminar; o bridge/MIDAS vira o
  número definitivo quando IBC/PIM/PMC/PMS de abril saírem.
- Não introduz dessazonalização via X-13 (ver decisão na seção 5).

## 3. Critério de sucesso

1. O script roda self-contained (instala pacotes ausentes, baixa dados ao vivo) e
   imprime uma projeção QoQ+YoY com banda para o 2026T2 usando os dados de abril
   (e confiança de maio) disponíveis hoje.
2. **Backtest do 2026T1 com k=1 mês**: o early-read deve errar *menos* que o
   bridge naquele vintage (bridge errou ~+0,9 p.p.; alvo: erro materialmente
   menor). Este é o teste central de que o módulo agrega valor onde o oficial
   falhou.
3. A banda alarga monotonicamente conforme menos meses estão disponíveis
   (k=1 > k=2 > k=3), por construção empírica.

## 4. Arquitetura e estrutura de arquivos

- **Novo arquivo:** `nowcast_early_read.R` na raiz do projeto. Autônomo, mesmo
  padrão self-contained dos scripts existentes (setup de pacotes → coleta →
  transformação → modelo → OOS → projeção → output).
- **Trimestre-alvo auto-detectado:** primeiro trimestre após o último PIB
  publicado que tenha ≥1 indicador rápido disponível (mesma lógica da seção 7 do
  script oficial). Generaliza para qualquer trimestre futuro, não só 2026T2.
- Não toca nos arquivos existentes além de docs (seção 9).

### Unidades (cada uma testável/inspecionável isoladamente)

| Unidade | O que faz | Depende de |
|---|---|---|
| `baixar_rapidos()` | Coleta a cesta via SGS (`rbcb`) + Ipeadata (`ipeadatar`), devolve painel mensal alinhado por data | rbcb, ipeadatar |
| `to_yoy()` | Converte cada série para variação YoY (12m); confiança → YoY do índice | dplyr |
| `agregar_trim_yoy(k)` | Agrega meses disponíveis do trimestre por média do YoY (ragged edge, vintage k) | dplyr, lubridate |
| `fatores_pca()` | Padroniza a cesta e extrai 1–2 PCs (pulso de atividade) | stats::prcomp |
| `ajustar_mapa()` | Regride `pib_yoy` nos PCs; amostra a partir do overlap comum | stats::lm |
| `yoy_para_qoq()` | Converte YoY previsto → índice → QoQ usando índices publicados | base |
| `oos_vintage()` | Pseudo-OOS rolling estratificado por k=1/2/3 → RMSE p/ banda | — |
| `imprimir_early_read()` | Output formatado (ponto, banda, vintage, comparação com bridge) | — |

## 5. Decisões de design

### 5.1 Transformação: YoY em vez de dessazonalização (X-13)
Usar **variação YoY (12 meses)** de cada indicador como feature, e modelar o
**PIB YoY** (`pib_yoy`, já calculado no projeto). Razões:
- YoY remove sazonalidade sem depender de X-13/SEATS (dependência pesada, ajuste
  ARIMA por série dentro do loop OOS = lento e frágil).
- O projeto já tem `pib_yoy` e os índices encadeados para a conversão.

**Conversão YoY → QoQ:** dado o índice publicado de 2026T1 (`idx_{t-1}`) e de
2025T2 (`idx_{t-4}`), a previsão `pib_yoy_t` implica
`idx_t = idx_{t-4}·(1 + yoy_t/100)` e então
`qoq_t = (idx_t / idx_{t-1} − 1)·100`. Todos os índices necessários já existem.

### 5.2 Mapeamento: fator PCA (1–2 componentes)
Cesta de ~5–7 YoY é colinear. Extrair 1–2 PCs dos YoY padronizados e regredir
`pib_yoy` neles (parcimônia + robustez). Decisão entre 1 ou 2 PCs: usar 2 apenas
se o 2º PC melhorar o RMSE OOS; caso contrário, 1 PC.

### 5.3 Ragged edge: média do YoY
Agregar os meses disponíveis do trimestre-alvo pela **média do YoY** desses meses.
YoY é comparável mês a mês, então a média de 1 ou 2 meses é proxy bem menos
distorcida do trimestre do que o `QoQ-de-médias` (que falhou no Q1, pois comparava
nível-de-1-mês contra nível-de-1-mês de um trimestre base atípico).

### 5.4 Banda: pseudo-OOS estratificado por vintage
Rolling pseudo-OOS pós-overlap-comum, calculado separadamente para k=1, k=2 e
k=3 meses disponíveis (reconstruindo a disponibilidade real-time, como a seção 5b
do script oficial). RMSE por vintage define a banda:
- 80% ≈ ±1,28·RMSE_k ; 90% ≈ ±1,64·RMSE_k.
A banda é reportada tanto em YoY quanto convertida para QoQ.

## 6. Fluxo de dados

```
SGS + Ipeadata ──baixar_rapidos()──> painel mensal (nível)
        └─ to_yoy() ──> painel YoY mensal
              └─ agregar_trim_yoy(k) ──> YoY trimestral (ragged edge)
                    ├─ histórico ──> fatores_pca() ──> ajustar_mapa() ──> mapa PIB
                    │                                        └─ oos_vintage() ──> RMSE_k (banda)
                    └─ trimestre-alvo ──> PCs do alvo ──> pib_yoy previsto
                                                └─ yoy_para_qoq() ──> QoQ ± banda
                                                      └─ imprimir_early_read()
```

## 7. Cesta final (a confirmar no plano por histórico/qualidade)

Inclusão definitiva decidida no plano após checar histórico comum e poder
preditivo individual. Candidatos priorizados:
1. Produção de autoveículos (SGS 1373)
2. Licenciamentos de veículos (SGS 7384)
3. Consumo de energia elétrica (SGS 1406)
4. Fluxo de comércio exterior — exportações+importações em volume (preferir a
   saldo; código a definir no plano)
5. Confiança do consumidor — ICC FCESP (SGS 4393)
6. Confiança industrial — ICEI/CNI (Ipeadata, código `CNI12_ICEIGER12`)
7. Papelão ondulado — ABPO (Ipeadata, `ABPO12_PAPEL12`)

Regra: manter série só se tiver overlap a partir de ~2003–2005 e sinal coerente
no mapeamento. Mínimo viável: 4 séries.

## 8. Output esperado (exemplo ilustrativo)

```
===== EARLY-READ 2026T2 (último PIB: 2026T1 = +1,10% QoQ) =====
Indicadores disponíveis (vintage k=1 mês — abril; confiança até maio):
  veic_prod  veic_lic  energia  comex  icc  icei  abpo
Pulso de atividade (PC1): +0.83 sd

  Projeção        QoQ            YoY
  ponto         +0.6%          +2.3%
  banda 80%   [-0.1, +1.3]   [+1.5, +3.1]
  banda 90%   [-0.4, +1.6]   [+1.2, +3.4]

  [aviso] k=1 mês → banda larga; leitura preliminar.
  Bridge oficial: n/d (IBC/PIM/PMC/PMS de abril ainda não publicados)
```

## 9. Documentação

- `CHANGELOG.md` → `[Não lançado]` → `Adicionado`: módulo early-read.
- `CLAUDE.md` → seção "Architecture": registrar `nowcast_early_read.R` como
  módulo paralelo (early-read), com link conceitual para a limitação ragged-edge.

## 10. Validação (idioma do projeto, sem framework de testes)

- Tabela de RMSE pseudo-OOS por vintage (k=1/2/3) pós-overlap-comum.
- **Backtest 2026T1**: rodar o early-read como se estivéssemos no início de Q1
  (só janeiro/fevereiro disponíveis) e comparar o erro vs +1,10% realizado contra
  o erro do bridge no mesmo vintage. Sucesso = erro menor no k=1.
- Sanidade: sinais dos PCs e dos coeficientes economicamente plausíveis.

## 11. Riscos e mitigação

| Risco | Mitigação |
|---|---|
| Série Ipeadata sem dessaz. ou com revisão pesada | YoY já neutraliza sazonalidade; revisões são aceitas como ruído refletido na banda OOS |
| Histórico curto de alguma confiança no SGS (ex.: ICI 7341, n=3) | Usar versão longa do Ipeadata; descartar série se overlap insuficiente |
| Overfit com poucas obs trimestrais (~80) | PCA reduz dimensão; máx. 1–2 PCs; OOS honesto |
| `ipeadatar` indisponível offline no momento do run | Já instalado nesta máquina; script tenta instalar e degrada para cesta só-SGS se falhar |
| Banda subestimada no k=1 (mesmo erro do Q1) | Banda empírica estratificada por vintage; backtest 2026T1 é gate de aceitação |
