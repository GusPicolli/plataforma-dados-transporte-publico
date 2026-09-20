# Documentação das fontes — referência operacional

Isto é uma referência pra quem for operar/debugar os pipelines desta fase:
formato, frequência e particularidade de cada fonte, mais o que a
ingestão faz com isso (schema, retry, onde cai no S3). O histórico de
*descoberta* de cada fonte (como validamos, o que foi testado ao vivo)
está em [`Proposta_inicial_Mapeamento_rotas_onibus.md`](Proposta_inicial_Mapeamento_rotas_onibus.md)
— este documento não repete aquilo, só complementa com o que essa fase
de implementação acrescentou.

## SPTrans

### `sp_posicoes` (Lambda)

| | |
|---|---|
| Formato | JSON — `GET /Posicao` (snapshot único, todos os veículos da cidade) |
| Frequência na fonte | Tempo real — cada veículo atualiza a cada ~30s |
| Frequência de coleta | A cada 30 min, seg-sáb 5h-22h (`var.agenda_posicoes`) |
| Schema de validação | [`schemas/sptrans.py::SPTransPosicao`](../schemas/sptrans.py) |
| Retry | `tenacity`, 3 tentativas, backoff exponencial (1s/2s/4s), só em erro de rede ou JSON inválido |
| Saída | `s3://<bucket>/bronze/praca=sp/entidade=posicoes/dt=AAAA-MM-DD/hh=HH/*.ndjson` |
| Particularidade | Autenticação por sessão (cookie). A Lambda não guarda sessão entre invocações — autentica de novo a cada execução; se a chamada de posição falhar, reautentica e desiste depois de esgotar o retry |

### `sp_cadastro` (Lambda)

| | |
|---|---|
| Formato | JSON (linhas, via varredura heurística) + GTFS oficial em zip (pontos) |
| Frequência na fonte | Linhas mudam raramente. GTFS observado com `last-modified` de poucas horas de idade |
| Frequência de coleta | 1x/dia, seg-sáb (`var.agenda_cadastro`) |
| Schema de validação | [`SPTransLinha`, `SPTransPonto`](../schemas/sptrans.py) |
| Retry | `tenacity` na varredura de linhas e no download do GTFS |
| Saída | `bronze/praca=sp/entidade=linhas/...` e `bronze/praca=sp/entidade=pontos/...` |
| Particularidade | Não existe endpoint "listar todas as linhas" — a varredura por 36 termos (`0-9`, `a-z`) é heurística, não garantia formal da SPTrans. `/Parada/BuscarParadasPorLinha` cobre só ~18% das linhas (por isso pontos vêm do GTFS, não dessa API). Chave de junção do GTFS é o letreiro+sentido (ex: `"1012-10"`), não o `codigo_linha` numérico |

## Rio de Janeiro

### `rio_posicoes` (Lambda)

| | |
|---|---|
| Formato | JSON — log bruto de pings de GPS (não é snapshot) |
| Frequência na fonte | ~1 ping a cada 30s por veículo |
| Frequência de coleta | A cada 30 min |
| Schema de validação | [`schemas/rio.py::RioPosicao`](../schemas/rio.py) |
| Retry | `tenacity`, mesmo padrão do SP |
| Saída | `bronze/praca=rio/entidade=posicoes/...` |
| Particularidade | `src.rio_client.buscar_posicao_geral()` já deduplica por `id_veiculo` antes de chegar no handler — sem isso a frota apareceria ~11x inflada (uma janela de 5 min traz ~10 pings por veículo). Parâmetros de data em formato `MM-dd-yyyy HH:mm:ss` (não documentado oficialmente); formato brasileiro retorna `[]` com HTTP 200 — falha silenciosa, não dá erro |

### `rio_cadastro` (Lambda)

| | |
|---|---|
| Formato | GTFS oficial em zip |
| Frequência na fonte | Mensal |
| Frequência de coleta | 1x/dia (mais frequente que a fonte muda; sem custo real de rede por causa do cache local do GTFS) |
| Schema de validação | [`RioLinha`, `RioPonto`](../schemas/rio.py) |
| Saída | `bronze/praca=rio/entidade=linhas/...`, `bronze/praca=rio/entidade=pontos/...` |
| Particularidade | Em Lambda, o cache do GTFS grava em `/tmp` (único diretório gravável), não em `.cache/` como no CLI local — sem isso, a função derrubava com `OSError: Read-only file system` (achado testando de verdade em produção, corrigido em `src/rio_gtfs.py`/`src/sptrans_gtfs.py`). `/tmp` ainda é efêmero entre cold starts, então cada um rebaixa o GTFS de 25 MB — cache persistente entre invocações (S3) continua sendo trabalho da próxima fase, mas hoje a função pelo menos não quebra |

## Fortaleza

### `fortaleza_cadastro` (Lambda)

| | |
|---|---|
| Formato | JSON — API não-oficial da ETUFOR |
| Frequência na fonte | Cadastro; não é tempo real |
| Frequência de coleta | 1x/dia |
| Schema de validação | [`FortalezaLinha`, `FortalezaPonto`](../schemas/fortaleza.py) |
| Retry | `tenacity` por chamada de itinerário; além disso, uma linha que continue falhando após o retry é **pulada**, não aborta a coleta das ~540 restantes |
| Saída | `bronze/praca=fortaleza/entidade=linhas/...`, `bronze/praca=fortaleza/entidade=pontos/...` |
| Particularidade | **Sem posição em tempo real** — nenhuma fonte pública ou não-oficial encontrada (limitação estrutural da praça, não de implementação). Pontos vêm da sequência de logradouros do itinerário, sem latitude/longitude. Pelo menos 1 código de linha retorna erro 500 de forma intermitente — contado e logado como `linhas_sem_itinerario`, não trava o handler |

---

## Validação de schema — como funciona

Cada registro bruto é validado contra um model `pydantic`
([`lambdas/common/validation.py`](../lambdas/common/validation.py)) antes
de ir pro bronze. Um registro inválido **não derruba o lote inteiro** — vai
pra uma lista separada, contada e logada (`total_invalido` + amostra), e só
os válidos são escritos no S3. É o mesmo princípio de "falha por item, não
por lote" que já valia pro loop de itinerário da Fortaleza, agora aplicado
a todo dado que entra em qualquer uma das 3 fontes.

Testado com dados reais das 3 fontes ao vivo (ver histórico de implementação):
zero registros inválidos nesse teste — o que confirma que os schemas batem
com o formato real das APIs hoje, não é só uma suposição de tipo.

## Logs estruturados — como ler

Cada invocação emite uma linha JSON via `aws_lambda_powertools.Logger`
([`lambdas/common/logging_config.py`](../lambdas/common/logging_config.py)),
capturada pelo CloudWatch Logs. Campos fixos em toda linha: `service`
(nome da função), `function_request_id`, `cold_start`, `timestamp`. Campos
de negócio variam por handler, mas sempre incluem `total_recebido` /
`total_valido` / `total_invalido` e `duracao_s`.

Exemplo de consulta no CloudWatch Logs Insights:

```
fields @timestamp, praca, total_valido, total_invalido, duracao_s
| filter service = "sp-posicoes"
| sort @timestamp desc
```

## Retry — as duas camadas (não são a mesma coisa)

1. **Dentro do handler** ([`lambdas/common/retry.py`](../lambdas/common/retry.py),
   via `tenacity`): retenta uma chamada HTTP específica até 3x com backoff
   exponencial — só para erro de rede ou JSON inválido. Erro de *negócio*
   não aciona isso de propósito: o 500 intermitente da ETUFOR devolve um
   corpo `{"Message": "..."}` que é JSON válido, então não é retry, é
   tratado como falha de item (ver Fortaleza acima) — tentar de novo não
   resolveria, e o padrão de falha já é conhecido.
2. **No EventBridge Scheduler** ([`infra/terraform/eventbridge.tf`](../infra/terraform/eventbridge.tf)):
   se a invocação **inteira** da Lambda falhar (exceção não tratada,
   timeout), o Scheduler tenta de novo até 2x. É uma rede de segurança
   atrás da primeira camada, cobre um tipo de falha diferente (a função
   toda, não uma chamada específica).
