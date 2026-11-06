# Documentação das fontes — referência operacional

Isto é uma referência pra quem for operar/debugar os pipelines desta fase:
formato, frequência e particularidade de cada fonte, mais o que a
ingestão faz com isso (schema, retry, onde cai no S3). O histórico de
*descoberta* de cada fonte (como validamos, o que foi testado ao vivo)
está em [`Proposta_inicial_Mapeamento_rotas_onibus.md`](Proposta_inicial_Mapeamento_rotas_onibus.md)
— este documento não repete aquilo, só complementa com o que essa fase
de implementação acrescentou.

## Os dois pipelines

A ingestão é dividida em dois ritmos, porque os dados têm volatilidades
muito diferentes:

| | Pipeline lento (cadastro) | Pipeline rápido (posição) |
|---|---|---|
| **O que coleta** | Linhas e pontos/itinerário | Posição dos veículos |
| **Praças** | SP, Rio, Fortaleza | SP e Rio (Fortaleza não tem a fonte) |
| **Cadência** | 1x/dia, 7h, seg-sex | 1x/minuto, das 8h às 16h59, seg-sex |
| **Por quê** | A fonte muda em dias/semanas/meses — coletar mais rápido não traz frescura nenhuma | Exercita o cenário de "quase tempo real" numa janela curta e barata |
| **Funções** | `sp_cadastro`, `rio_cadastro`, `fortaleza_cadastro` | `sp_posicoes`, `rio_posicoes` |

O pipeline rápido **não é streaming** — é polling acelerado. 1 minuto é o
piso do EventBridge Scheduler; descer aos 5 segundos do exercício local
(`exemplos/realtime/`) exigiria um poller contínuo em Fargate + broker,
o que custaria ordens de grandeza a mais sem ganhar frescura, já que o GPS
de cada ônibus só reporta a cada ~30s de qualquer forma.

Os dois crons estão no fuso `America/Sao_Paulo` (`var.timezone_agendamento`).
Isso não é detalhe: o EventBridge assume **UTC** por padrão, e a primeira
versão desta infra rodava 3h deslocada sem ninguém perceber.

## SPTrans

### `sp_posicoes` (Lambda)

| | |
|---|---|
| Formato | JSON — `GET /Posicao` (snapshot único, todos os veículos da cidade) |
| Frequência na fonte | Tempo real — cada veículo atualiza a cada ~30s |
| Frequência de coleta | **Pipeline rápido**: a cada 1 minuto, das 8h às 16h59, de segunda a sexta (`var.agenda_posicoes`, fuso `America/Sao_Paulo`). 1 min é o piso do EventBridge Scheduler. A janela é horário comercial, por decisão de quem usa o dado — ônibus circulam todo dia e das 5h às 23h |
| Schema de validação | [`schemas/sptrans.py::SPTransPosicao`](../schemas/sptrans.py) |
| Retry | `tenacity`, 3 tentativas, backoff exponencial (1s/2s/4s), só em erro de rede ou JSON inválido |
| Saída | `s3://<bucket>/bronze/praca=sp/entidade=posicoes/dt=AAAA-MM-DD/hh=HH/*.ndjson` |
| Particularidade | Autenticação por sessão (cookie). A Lambda não guarda sessão entre invocações — autentica de novo a cada execução; se a chamada de posição falhar, reautentica e desiste depois de esgotar o retry |

### `sp_cadastro` (Lambda)

| | |
|---|---|
| Formato | JSON (linhas, via varredura heurística) + GTFS oficial em zip (pontos) |
| Frequência na fonte | Linhas mudam raramente. GTFS observado com `last-modified` de poucas horas de idade |
| Frequência de coleta | **Pipeline lento**: 1x/dia às 7h, seg-sex — antes da janela de posições abrir (`var.agenda_cadastro`, fuso `America/Sao_Paulo`) |
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
| Frequência de coleta | **Pipeline rápido**: a cada 1 minuto, das 8h às 16h59, de segunda a sexta (mesma janela de SP) |
| Schema de validação | [`schemas/rio.py::RioPosicao`](../schemas/rio.py) |
| Retry | `tenacity`, mesmo padrão do SP |
| Saída | `bronze/praca=rio/entidade=posicoes/...` |
| Particularidade | `src.rio_client.buscar_posicao_geral()` já deduplica por `id_veiculo` antes de chegar no handler — sem isso a frota apareceria ~11x inflada (uma janela de 5 min traz ~10 pings por veículo). Parâmetros de data em formato `MM-dd-yyyy HH:mm:ss` (não documentado oficialmente); formato brasileiro retorna `[]` com HTTP 200 — falha silenciosa, não dá erro |

### `rio_cadastro` (Lambda)

| | |
|---|---|
| Formato | GTFS oficial em zip |
| Frequência na fonte | Mensal |
| Frequência de coleta | **Pipeline lento**: 1x/dia às 7h. Ainda mais frequente que a fonte muda (o GTFS do Rio é publicado 1x/mês), mas diário mantém um único modelo mental de cadência pro cadastro das 3 praças |
| Schema de validação | [`RioLinha`, `RioPonto`](../schemas/rio.py) |
| Saída | `bronze/praca=rio/entidade=linhas/...`, `bronze/praca=rio/entidade=pontos/...` |
| Particularidade | Em Lambda, o cache do GTFS grava em `/tmp` (único diretório gravável), não em `.cache/` como no CLI local — sem isso, a função derrubava com `OSError: Read-only file system` (achado testando de verdade em produção, corrigido em `coleta/gtfs.py`). `/tmp` ainda é efêmero entre cold starts, então cada um rebaixa o GTFS de 25 MB — cache persistente entre invocações (S3) continua sendo trabalho da próxima fase, mas hoje a função pelo menos não quebra |

## Fortaleza

### `fortaleza_cadastro` (Lambda)

| | |
|---|---|
| Formato | JSON — API não-oficial da ETUFOR |
| Frequência na fonte | Cadastro; não é tempo real |
| Frequência de coleta | **Pipeline lento**: 1x/dia às 7h. Deliberadamente não mais que isso: cada execução faz ~540 chamadas sequenciais a uma API não-oficial, e de hora em hora daria 182 mil chamadas/mês pra um dado que muda em semanas |
| Schema de validação | [`FortalezaLinha`, `FortalezaPonto`](../schemas/fortaleza.py) |
| Retry | `tenacity` por chamada de itinerário; além disso, uma linha que continue falhando após o retry é **pulada**, não aborta a coleta das ~540 restantes |
| Saída | `bronze/praca=fortaleza/entidade=linhas/...`, `bronze/praca=fortaleza/entidade=pontos/...` |
| Particularidade | **Sem posição em tempo real** — nenhuma fonte pública ou não-oficial encontrada (limitação estrutural da praça, não de implementação). Pontos vêm da sequência de logradouros do itinerário, sem latitude/longitude. Pelo menos 1 código de linha retorna erro 500 de forma intermitente — contado e logado como `linhas_sem_itinerario`, não trava o handler |

---

## Camada silver — normalização

Uma única Lambda genérica (`lambdas/silver/handler.py`) atende as 3 praças.
Ela **não tem nenhum `if praca == ...`**: lê o par `(praca, entidade)` das
próprias partições da chave no S3 e consulta o metadado declarativo em
[`schemas/mapeamento_silver.py`](../schemas/mapeamento_silver.py) pra saber
quais campos do bronze viram quais campos do modelo canônico
([`schemas/canonico.py`](../schemas/canonico.py)). Fonte nova, ou campo
renomeado na origem, se resolve adicionando uma entrada naquele dicionário —
sem tocar no handler.

**Disparo:** evento do S3, não agendamento. Quando a bronze grava um
`.ndjson`, o S3 notifica a Lambda e o evento já traz bucket+key. Isso
elimina orquestração e desacopla: a ingestão nem sabe que a silver existe.
O handler também aceita `{"bucket": ..., "key": ...}` manual, pra
reprocessar. O filtro da notificação (`prefix=bronze/`, `suffix=.ndjson`) é
o que impede a silver de disparar em cima do próprio Parquet que ela grava.

**Saída:** Parquet com schema declarado explicitamente (derivado do model
pydantic, não inferido dos dados — inferir quebraria numa coluna
inteiramente nula, como `velocidade` em SP, que a fonte não tem). Redução
medida em dados reais:

| Entidade | Bronze (NDJSON) | Silver (Parquet) | Redução |
|---|---:|---:|---:|
| sp / pontos | 26.459 KB | 1.425 KB | 18,6x |
| rio / posicoes | 690 KB | 61 KB | 11,3x |
| sp / posicoes | 1.566 KB | 148 KB | 10,6x |
| sp / linhas | 284 KB | 43 KB | 6,6x |

Isso importa duas vezes: menos armazenamento, e muito menos dado escaneado
pelo Athena (que cobra por TB lido).

**Limite conhecido — a silver não deduplica.** Ela é 1 arquivo entra → 1
arquivo sai, então normaliza mas não consegue cruzar arquivos. Se o mesmo
veículo aparece em 3 coletas da mesma hora, a silver terá 3 registros. A
deduplicação fica pra leitura (`ROW_NUMBER() OVER (PARTITION BY id_veiculo
ORDER BY timestamp_veiculo DESC)` no Athena) ou pra camada gold. Resolver
isso na silver exigiria um job de compactação que lê a partição inteira —
mais caro e mais peça móvel do que o problema justifica hoje.

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

---

# Detalhe das APIs de origem

As seções acima descrevem **o que cada Lambda faz**. As abaixo descrevem **como
cada API de origem se comporta** — endpoints, autenticação e as armadilhas que
custaram retrabalho.

## SPTrans — a API Olho Vivo

1. **Token de acesso**: é necessário se cadastrar gratuitamente em
   https://www.sptrans.com.br/desenvolvedores/ para obter um token pessoal.
2. **Autenticação por sessão**: não existe header de API key. Você chama
   `GET /Login/Autenticar?token=SEU_TOKEN` uma vez; a API responde `true`/`false`
   e devolve um cookie de sessão. Esse cookie precisa ser reenviado em todas
   as chamadas seguintes (é o que `coleta/sptrans.py` faz).
3. **Endpoint de linhas**: `GET /Linha/Buscar?termosBusca=TERMO`. O termo
   pode ser o número da linha (ex: `8000`) ou parte do nome/bairro (ex:
   `lapa`). Retorna código da linha, letreiro, sentido, origem e destino.
   **Não existe um endpoint para listar todas as linhas de uma vez** — para
   montar `linhas.csv` completo, `buscar_todas_linhas()`
   (`coleta/sptrans.py`) varre `termosBusca` com cada dígito (`0-9`) e
   cada letra (`a-z`) e deduplica pelo código da linha (`cl`). É uma
   heurística (cobre tudo que aparece nesses 36 termos, incluindo prefixos
   como `N` das linhas noturnas), não uma garantia formal da SPTrans — mas
   na prática deu 2688 linhas únicas, em ~2s de chamadas.
4. **Trajeto/referência de rota**: `GET /Parada/BuscarParadasPorLinha?codigoLinha=X`
   retorna as paradas de uma linha com latitude/longitude, mas **na prática só
   responde para ~18% das linhas** — inclusive linhas com veículo circulando
   naquele exato momento. Testado ao vivo, não é throttling: a API devolve
   `[]` genuinamente. Por isso `pontos.csv` **não usa mais esse endpoint** —
   ver item 6.
5. **Posição em tempo real**: `GET /Posicao` (sem parâmetro) retorna, numa
   única chamada, todos os veículos em circulação agora agrupados por
   linha — é o que popula `posicoes.csv` (bem mais eficiente do que chamar
   `/Posicao/Linha` uma vez por linha).
6. **GTFS oficial** (`coleta/gtfs.py`) → fonte de `pontos.csv`. A SPTrans
   publica um feed GTFS completo e público em
   `https://www.sptrans.com.br/umbraco/Surface/PerfilDesenvolvedor/BaixarGTFS`
   (sem token, ~14 MB, atualizado com frequência — visto com poucas horas de
   idade). `buscar_pontos_todas_linhas()` cruza `routes → trips → stop_times →
   stops` numa única passada, igual ao padrão do Rio, e cobre exatamente as
   linhas que a API ao vivo não cobre (testado: as 5 linhas usadas como
   exemplo do achado acima aparecem todas no GTFS, com 31 a 101 paradas cada).
   Cache em `.cache/gtfs_sptrans.zip` — apague para forçar atualização.

   **Atenção à chave de junção**: o GTFS identifica a linha pelo letreiro com
   sentido (`route_short_name`, ex: `"1012-10"`) — o mesmo formato do campo
   `letreiro` em `posicoes.csv`. **Não é** o `codigo_linha` (`cl`) numérico
   usado em `linhas.csv`; esse código não existe no GTFS.


## Rio de Janeiro (`coleta/rio.py` + `coleta/gtfs.py`)

Não é a mesma API da SPTrans — o pipeline do Rio combina duas fontes do
**dados.mobilidade.rio** (GPS e GTFS no mesmo host; o GTFS saiu do ArcGIS em 2026):

1. **GPS em tempo real** (`coleta/rio.py`) → `posicoes.csv`.
2. **GTFS oficial** (`coleta/gtfs.py`) → `linhas.csv` e `pontos.csv`. É um
   zip (~25 MB) publicado mensalmente pela SMTR com `routes.txt`,
   `stops.txt`, `trips.txt` e `stop_times.txt`. `buscar_pontos_todas_linhas()`
   cruza essas quatro tabelas (rota → viagens → paradas) **numa única
   passada** pelo `stop_times.txt` (~86 MB) e devolve um par
   linha+ponto para cada parada de cada linha (~52 mil linhas na tabela,
   já que a maioria das paradas é compartilhada por várias linhas). O zip
   é baixado uma vez e cacheado em `.cache/gtfs_rio.zip` — apague esse
   arquivo para forçar atualização.

### GPS em tempo real

- Endpoint: `GET https://dados.mobilidade.rio/gps/sppo`
- Não exige token/autenticação.
- Parâmetros obrigatórios `dataInicial` e `dataFinal` no formato
  `MM-dd-yyyy HH:mm:ss` (mês antes do dia) — `_janela_atual()` monta essa
  janela automaticamente com o fuso de Brasília (UTC-3).
- Retorna todos os veículos que enviaram posição na janela pedida; não há
  filtro por linha no servidor, então `buscar_posicao_linha()` filtra pelo
  campo `servico` no lado do cliente.
- **Importante**: a API devolve o log bruto de pings de GPS da janela, não
  um snapshot único como o `/Posicao` da SPTrans — cada ônibus manda
  posição a cada ~30s, então uma janela de 5 minutos traz ~10 registros
  por veículo. `buscar_posicao_geral()` já deduplica isso, mantendo só o
  ping mais recente de cada `id_veiculo`, para o número de veículos fazer
  sentido como "em circulação agora".

```python
from src.rio_client import buscar_posicao_linha, buscar_posicao_geral

veiculos_linha_232 = buscar_posicao_linha("232")
todos_veiculos = buscar_posicao_geral()
```


## Fortaleza (`coleta/fortaleza.py`)

A Prefeitura de Fortaleza **não expõe uma API pública de posição de
veículo em tempo real** (o portal `dados.fortaleza.ce.gov.br` só tem
datasets estáticos: GTFS, mapas de linhas/paradas e um dump histórico de
GPS de 2015). Por isso este cliente usa a API não-oficial da ETUFOR
(`gistapis.etufor.ce.gov.br`) para dados de linhas, itinerário e horários
— sem posição em tempo real.

- `buscar_linhas()` — lista todas as linhas.
- `buscar_itinerario(codigo_linha)` — trajeto (logradouros) de ida/volta.
- `buscar_horarios(codigo_linha, data)` — horários programados (`data` no
  formato `YYYYMMDD`).
- `buscar_logradouros()` — lista de logradouros cadastrados.
- `buscar_linhas_por_logradouro(codigo_logradouro)` — linhas que passam
  por um logradouro. Alguns IDs de logradouro fazem a API da ETUFOR
  responder erro 500 (bug do lado deles, não do cliente).

**Nota sobre `pontos.csv` de Fortaleza**: como não há um cadastro de
paradas com latitude/longitude por linha, `pontos.csv` é montado chamando
`buscar_itinerario()` uma vez para cada uma das ~540 linhas — a sequência
de logradouros (ruas) percorridos de ida e volta, sem coordenadas
geográficas. Como é uma API não-oficial, algumas linhas pontuais respondem
erro 500; o pipeline pula essas linhas (loga o(s) código(s) no final) em
vez de abortar a coleta das demais.

```python
from src.fortaleza_client import buscar_linhas, buscar_itinerario

linhas = buscar_linhas()
itinerario = buscar_itinerario(linhas[0]["numero"])
```
