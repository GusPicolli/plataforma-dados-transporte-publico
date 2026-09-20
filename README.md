# Teste API Olho Vivo (SPTrans) + Rio de Janeiro + Fortaleza

Aplicação de teste com um **pipeline por cidade** (SPTrans, Rio de Janeiro e
Fortaleza). Cada execução sempre busca **todas as linhas cadastradas e
todas as posições/pontos daquele momento** (sem filtro por termo ou por
linha) e gera até três tabelas CSV em `output/<cidade>/`:

- `linhas.csv` — linhas de ônibus cadastradas.
- `posicoes.csv` — posição dos veículos em circulação (quando a cidade
  expõe isso publicamente).
- `pontos.csv` — paradas/pontos ao longo da linha.

| Cidade     | Pipeline                     | linhas.csv | posicoes.csv | pontos.csv |
|------------|-------------------------------|:----------:|:-------------:|:----------:|
| SPTrans    | `src/sptrans_pipeline.py`     | ✅ | ✅ | ✅ |
| Rio de Janeiro | `src/rio_pipeline.py`     | ✅ | ✅ | ✅ |
| Fortaleza  | `src/fortaleza_pipeline.py`   | ✅ | ❌ (não existe API pública) | ✅ |

## Como a API funciona

1. **Token de acesso**: é necessário se cadastrar gratuitamente em
   https://www.sptrans.com.br/desenvolvedores/ para obter um token pessoal.
2. **Autenticação por sessão**: não existe header de API key. Você chama
   `GET /Login/Autenticar?token=SEU_TOKEN` uma vez; a API responde `true`/`false`
   e devolve um cookie de sessão. Esse cookie precisa ser reenviado em todas
   as chamadas seguintes (é o que `src/sptrans_client.py` faz).
3. **Endpoint de linhas**: `GET /Linha/Buscar?termosBusca=TERMO`. O termo
   pode ser o número da linha (ex: `8000`) ou parte do nome/bairro (ex:
   `lapa`). Retorna código da linha, letreiro, sentido, origem e destino.
   **Não existe um endpoint para listar todas as linhas de uma vez** — para
   montar `linhas.csv` completo, `buscar_todas_linhas()`
   (`src/sptrans_client.py`) varre `termosBusca` com cada dígito (`0-9`) e
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
6. **GTFS oficial** (`src/sptrans_gtfs.py`) → fonte de `pontos.csv`. A SPTrans
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

## Configuração

```bash
python -m venv .venv
.venv\Scripts\activate      # Windows
pip install -r requirements.txt
copy .env.example .env
# edite .env e coloque seu token em SPTRANS_TOKEN
```

## Uso

```bash
python main.py              # pipeline da SPTrans (todas as linhas/posicoes/paradas)
python main.py sptrans      # o mesmo, explicito
python main.py rio          # pipeline do Rio (cidade toda)
python main.py fortaleza    # pipeline de Fortaleza (cidade toda)
```

ou via Makefile:

```bash
make run-sptrans      # so SPTrans
make run-rio          # so Rio
make run-fortaleza    # so Fortaleza
make run-all          # os tres pipelines em sequencia
```

Nenhum pipeline aceita mais termo de busca ou código de linha — cada
execução sempre busca tudo que a fonte tem disponível naquele momento e
escreve as tabelas em `output/<cidade>/`, imprimindo no final quantas
linhas cada CSV recebeu. SPTrans e Rio geram `pontos.csv` a partir de GTFS
(rápido, segundos, graças ao cache); Fortaleza ainda faz uma chamada HTTP
por linha para o itinerário (~2 min, sem alternativa em GTFS estático
verificada) — o progresso é impresso a cada 100 linhas processadas.

## Rio de Janeiro (`src/rio_client.py` + `src/rio_gtfs.py`)

Não é a mesma API da SPTrans — o pipeline do Rio combina duas fontes do
**Data.Rio** (portal `data.rio`, hospedado em ArcGIS Hub):

1. **GPS em tempo real** (`src/rio_client.py`) → `posicoes.csv`.
2. **GTFS oficial** (`src/rio_gtfs.py`) → `linhas.csv` e `pontos.csv`. É um
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

## Fortaleza (`src/fortaleza_client.py`)

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

## Tempo real (`exercicios/realtime/`)

Os pipelines acima são em lote: rodam, escrevem um CSV, terminam. O módulo
`exercicios/realtime/` é um exercício pessoal, **fora do caminho de
produção** (esse é `lambdas/` + `infra/`, ver seção abaixo) — a mesma ideia
de ingestão, mas como um fluxo contínuo, só para SP e Rio (as praças com
posição em tempo real). Fortaleza não entra aqui por não ter essa fonte.
Fica em `exercicios/` de propósito, separado do que é pensado pra rodar em
produção, pra ficar claro o que é uma coisa e o que é outra.

### Os conceitos

- **Producer** (`producer_sp.py`, `producer_rio.py`) — só sabe consultar a
  fonte e publicar cada posição como uma mensagem. Não sabe (nem precisa
  saber) quem vai ler, nem o que vai ser feito com o dado.
- **Broker** (Redis, rodando à parte) — a fila/canal no meio. É o que permite
  producer e consumer rodarem em processos diferentes, em ritmos diferentes,
  sem um conhecer o outro diretamente.
- **Consumer** (`consumer.py`) — assina o canal, recebe cada mensagem e
  materializa a "última posição conhecida" de cada veículo num hash do
  Redis. É a ponte entre o fluxo de eventos e um estado consultável.
- **API** (`api.py`) — só lê esse hash. Não sabe nada sobre producer/broker;
  para ela, é só um dado que já está lá, pronto.

Esse desenho (producer → broker → consumer → estado materializado → leitura)
é o mesmo padrão geral de sistemas maiores como Kafka — aqui só trocamos o
broker por Redis Pub/Sub, que é mais simples de rodar e de entender primeiro.

**Sobre "tempo real" e "5 segundos":** nenhuma das fontes empurra dado pra
nós — continuamos fazendo *polling* (perguntando de novo e de novo), só que
rápido. E cada veículo só manda um novo ping de GPS a cada ~30s (confirmado
nos dados: ver campo `ta` na SPTrans e `datetime` no Rio). Então "5 segundos
de latência" aqui significa **o tempo entre a fonte ter um dado novo e a
nossa API conseguir servir esse dado** — não que a posição do ônibus vai
mudar visualmente a cada 5s. Se o producer consulta mais rápido do que a
fonte atualiza, boa parte das consultas simplesmente vai repetir o mesmo
dado — isso é esperado, não é bug.

### Como rodar

Precisa de um Redis rodando (usei Docker, mas qualquer Redis local serve) e
5 processos separados, cada um no seu terminal:

```bash
docker run -d --name realtime-redis -p 6379:6379 redis:7-alpine   # broker

python -m exercicios.realtime.producer_sp     # publica posicoes de SP
python -m exercicios.realtime.producer_rio    # publica posicoes do Rio
python -m exercicios.realtime.consumer        # materializa a ultima posicao de cada veiculo
python -m uvicorn exercicios.realtime.api:app --reload --port 8000   # GET /posicoes/sp, /posicoes/rio
```

ou via Makefile: `make realtime-redis`, `make realtime-producer-sp`,
`make realtime-producer-rio`, `make realtime-consumer`, `make realtime-api`.

Por padrão cada producer publica **todos os veículos da cidade** — pra SP
isso é ~5.000 mensagens a cada ciclo, difícil de acompanhar no terminal.
Pra um primeiro teste, filtre por uma linha específica:

```bash
SP_FILTRO_LETREIRO="3459-10" python -m exercicios.realtime.producer_sp   # letreiro com sentido, ex: "3459-10"
RIO_FILTRO_SERVICO="497" python -m exercicios.realtime.producer_rio      # so o numero do servico
```

Variáveis de ambiente aceitas: `SP_INTERVALO_SEGUNDOS` / `RIO_INTERVALO_SEGUNDOS`
(padrão 5s), `SP_FILTRO_LETREIRO`, `RIO_FILTRO_SERVICO`, `REDIS_HOST` /
`REDIS_PORT` (padrão `localhost:6379`).

Com tudo rodando:

```bash
curl http://127.0.0.1:8000/posicoes/sp              # todas as posicoes conhecidas em SP
curl http://127.0.0.1:8000/posicoes/rio/B31066       # uma posicao especifica no Rio
```

### Limitações conhecidas (é um exercício, não é produção)

- Redis Pub/Sub **não persiste**: se o consumer estiver fora do ar quando o
  producer publica, essa mensagem se perde (o hash de estado não atualiza,
  mas nada quebra). Um broker baseado em log — Redis Streams ou Kafka — guarda
  as mensagens e permite reprocessar; é o passo natural depois de entender
  este exercício.
- Sem reconexão automática se o Redis cair no meio da execução.
- SPTrans: sessão de cookie sem renovação proativa — o producer só
  reautentica quando uma chamada falha.

## Ingestão em produção (`lambdas/` + `infra/terraform/`)

Implementação da arquitetura da
[Proposta_inicial_Mapeamento_rotas_onibus.md](docs/Proposta_inicial_Mapeamento_rotas_onibus.md):
5 funções Lambda (uma por praça × cadência), disparadas pelo EventBridge
Scheduler, escrevendo na camada bronze de um bucket S3 — com validação de
schema, retry e logs estruturados. Detalhes:

- **Por fonte** (formato, frequência, particularidade, schema, retry, onde
  cai no S3): [`docs/FONTES.md`](docs/FONTES.md).
- **Deploy** (pré-requisitos, o que é criado, o que já foi validado e o
  que ainda não): [`infra/terraform/README.md`](infra/terraform/README.md).
- **Código**: `schemas/` (models `pydantic`, um por entidade/praça),
  `lambdas/common/` (validação, retry, log estruturado, escrita em S3),
  `lambdas/<funcao>/handler.py` (um por função — reusam `src/`, não
  duplicam a lógica de coleta dos pipelines em lote).

Duas listas de dependências separadas em `lambdas/`, de propósito:
`requirements.txt` é pra rodar/testar os handlers localmente (inclui
`boto3` e `python-dotenv`); `requirements-layer.txt` é só o que vai
**dentro da imagem de container** (sem `boto3`, que o runtime já traz; sem
`python-dotenv`, que não faz sentido em produção).

**Empacotamento: imagem de container (Docker), não zip+layer.** As 5
funções compartilham a mesma imagem (`infra/docker/Dockerfile`), publicada
no ECR — só o `command` (o handler) muda entre elas, via `image_config` no
Terraform. Rodar dentro da imagem base oficial da AWS já resolve sozinho o
problema de baixar o wheel pra plataforma errada (que apareceu de verdade
quando isso ainda era zip+layer buildado num Windows). Pra testar uma
função localmente, sem precisar publicar nada:

```bash
infra/docker/run_local.sh lambdas.rio_posicoes.handler.lambda_handler
# noutro terminal:
curl -XPOST "http://localhost:9000/2015-03-31/functions/function/invocations" -d '{}'
```

Isso usa o Lambda Runtime Interface Emulator, que já vem embutido na
imagem base — não precisa de `aws-sam-cli` nem de nenhuma ferramenta além
do Docker.
