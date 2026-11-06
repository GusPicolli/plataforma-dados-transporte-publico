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
| SPTrans    | `coleta/pipelines.py`     | ✅ | ✅ | ✅ |
| Rio de Janeiro | `coleta/pipelines.py`     | ✅ | ✅ | ✅ |
| Fortaleza  | `coleta/pipelines.py`   | ✅ | ❌ (não existe API pública) | ✅ |

## Começando

Três comandos, do zero até uma coleta de verdade. O caminho básico **não
precisa de token, conta AWS nem Docker**:

```bash
make setup    # cria o venv, instala as dependencias e o .env
make check    # diz o que ja funciona e o que falta configurar
make demo     # coleta o Rio inteiro de verdade (~7s) -> output/rio/
```

`make` sozinho lista todos os comandos disponíveis.

O `make demo` é proposital: o Rio é a única praça que entrega linhas,
posições e pontos sem nenhuma credencial — dá pra ver o projeto funcionando
antes de configurar qualquer coisa.

### O que precisa de quê

| Pra rodar | Precisa de |
|---|---|
| `make demo`, `run-rio`, `run-fortaleza` | nada além do `make setup` |
| `make run-sptrans` | `SPTRANS_TOKEN` no `.env` ([cadastro gratuito](https://www.sptrans.com.br/desenvolvedores/)) |
| `make realtime-*` (exercício de tempo real) | Docker rodando (é onde sobe o Redis) |
| `make docker-build` / `docker-run` (Lambdas) | Docker rodando |
| `infra/terraform/` | credencial AWS (`aws configure`) |

`make check` responde essa tabela olhando a **sua** máquina: lista o que já
dá pra executar agora e, pro que não dá, o motivo e o comando que resolve —
em vez de você descobrir lendo código ou pelo traceback.

### Sem `make` na máquina

O Makefile é conveniência, não dependência. O equivalente na mão:

```bash
python -m venv .venv
.venv\Scripts\activate             # Windows;  source .venv/bin/activate no Linux/Mac
pip install -r requirements.txt -r lambdas/requirements.txt
copy .env.example .env             # cp no Linux/Mac
python scripts/check_ambiente.py   # = make check
python main.py rio                 # = make demo
```

## Estado atual do projeto

Última atualização: 21/09/2026.

O projeto tem **três camadas independentes**, e dá para mexer em qualquer uma
sem tocar nas outras:

| Camada | O que é | Precisa de |
|---|---|---|
| **Pipelines em lote** (`coleta/`, `main.py`) | Coleta as 3 praças e gera CSV local | nada (Rio/Fortaleza) ou token (SP) |
| **Ingestão em produção** (`lambdas/`, `infra/`) | A mesma coleta rodando na AWS, bronze → silver | conta AWS + Docker |
| **Exercício de tempo real** (`exemplos/`) | Producer/consumer com Redis, para estudo | Docker |

**Para só ver o projeto funcionando, use a primeira.** `make demo` roda em ~7s
e não pede credencial nenhuma. As outras duas são opcionais.

### O que funciona hoje

| Item | Estado |
|---|---|
| Coleta local das 3 praças | funciona |
| Ingestão na AWS (bronze) | funciona, agendada |
| Normalização bronze → silver (Parquet) | funciona, automática por evento do S3 |
| Validação de schema, retry, log estruturado | funciona |
| Alarmes e painel no CloudWatch | funciona (15 alarmes) |
| Exercício de tempo real (local) | funciona |
| `rio_cadastro` (linhas e pontos do Rio) | funciona |
| Camada gold | não existe |
| Testes automatizados | não existem |
| CI | não existe |

### Uma fonte que já quebrou, e como se consertou

O GTFS do Rio ficou **semanas fora do ar**: o item no ArcGIS passou a
responder `403 — You do not have permissions to access this resource`, tanto
no dado quanto nos **metadados** — que é como o ArcGIS responde para item
privado ou removido, não para bloqueio de download.

A prefeitura havia republicado em
`https://dados.mobilidade.rio/gtfs/schedule`, o **mesmo host da API de GPS**
que o projeto já usava. O schema do zip é idêntico; foi troca de URL.

Vale registrar porque é o modo de falha típico de fonte pública aberta: ela
não avisa que mudou. O que o projeto fez certo foi **degradar em vez de
quebrar** — durante todo o período, SP e Fortaleza seguiram carregando, e o
alarme `rio-cadastro-dado-velho` ficou aceso apontando exatamente para o
problema.

### O que este repositório ainda não é

Sendo explícito, para ninguém se surpreender ao abrir:

- **O state do Terraform é local.** Não há backend remoto nem lock. Se outra
  pessoa for aplicar infraestrutura, combine antes — dois `apply` simultâneos
  corrompem o state.
- **Sem testes e sem CI.** Nada valida uma mudança antes do merge.
- **Dependências não fixadas** (`>=`) e imagem base em tag mutável: um build de
  hoje não é necessariamente igual ao de amanhã.
- **Deploy sem versão**: as funções apontam para a tag `latest` num ECR mutável.

Nada disso impede rodar ou testar. Impede tratar como produção de empresa.

## Mapa do repositório

```
main.py                 CLI dos pipelines em lote (sptrans | rio | fortaleza)
Makefile                todos os comandos; `make` sozinho lista

coleta/                 como falar com cada fonte: clientes HTTP, GTFS, pipelines
                        reusado pelas Lambdas — a lógica de coleta existe uma vez só
schemas/                contratos: models pydantic do bronze, o canônico da silver
                        e mapeamento_silver.py, o metadado que liga os dois

lambdas/
  common/               validação, retry, log estruturado, escrita S3, leitura SSM
  ingestao/             UM handler para as 5 fontes + fontes.py, a tabela que as descreve
  silver/               normalização genérica, sem `if praca ==`
  heartbeat/            publica a idade do dado como métrica

infra/
  terraform/            toda a infraestrutura; ver o README de lá
  docker/               Dockerfile único das 7 funções + build_and_push.sh

transform/              modelos dbt: dimensional + geoespacial (make dbt-build)
scripts/
  check_ambiente.py     `make check` — o que já roda e o que falta configurar
  status_pipeline.py    `make status` — os pipelines na AWS estão entregando?

exemplos/realtime/      producer/consumer com Redis — estudo, fora de produção
docs/                   FONTES.md, TEMPO-REAL.md e a proposta inicial
output/                 CSVs gerados (gitignored)
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

## Ingestão em produção (`lambdas/` + `infra/terraform/`)

Implementação da arquitetura da
[Proposta_inicial_Mapeamento_rotas_onibus.md](docs/Proposta_inicial_Mapeamento_rotas_onibus.md).
São **7 funções Lambda**, todas na mesma imagem de container:

| Função | Dispara por | O que faz |
|---|---|---|
| `sp_posicoes`, `rio_posicoes` | **Step Functions**, 1 min, 8h–17h seg-sex | posição dos veículos → bronze |
| `sp_cadastro`, `rio_cadastro`, `fortaleza_cadastro` | **Step Functions**, 7h seg-sex | linhas e pontos → bronze |
| `silver` | **chamada pelo fluxo** | bronze → Parquet no schema canônico |
| `heartbeat` | EventBridge, 1 hora | publica a idade do dado como métrica |

### Como o dado anda

```
EventBridge → Step Functions ─┬─→ Lambda de ingestão → S3 bronze (NDJSON)
                              │                            │
                              └──────── fan-in ────────────┘
                                          ↓
                                   Lambda silver → S3 silver (Parquet)
```

**Todas as fontes passam pelo Step Functions.** Um fluxo genérico recebe a
lista de funções a coletar; os dois agendamentos (posições a cada minuto,
cadastro diário) passam listas diferentes. O fluxo não sabe nada sobre praça
nem cadência.

O que isso dá, que o agendamento direto não dava:

- **Sinal de conclusão.** "A coleta das 14h32 terminou?" tem resposta — o
  histórico de execução, com entrada e saída de cada passo.
- **Falha parcial vira estado.** Qualquer fonte que falhe é marcada como
  degradada e as demais seguem. Nenhuma fonte está degradada hoje.
- **Dois agendamentos no lugar de cinco.**

A silver é chamada **explicitamente** pelo fluxo. Havia um gatilho por evento
do S3 que parou de funcionar — configuração, permissão e função foram
verificadas sem achar causa, e ele foi removido. A chamada explícita é melhor
de qualquer forma: o evento avisava "um objeto chegou", o fluxo responde "a
coleta terminou".

**Custo:** ~9 transições por execução, ~105 mil/mês, ≈ US$ 2,54/mês. É a
escolha deliberada de pagar por visibilidade — o tipo Express custaria
~US$ 0,14, mas sem histórico visual de execução.

### A silver é genérica

Não existe um `if praca == ...` no handler. Ele lê
[`schemas/mapeamento_silver.py`](schemas/mapeamento_silver.py), um metadado
declarativo que diz, para cada par (praça, entidade), qual model canônico usar e
de que campo do bronze vem cada campo canônico. Fonte nova ou campo renomeado na
origem se resolve ali, sem tocar em código.

O metadado mora no repositório de propósito — não há banco de metadados nesta
fase.

### Observabilidade

15 alarmes cobrindo três classes de falha que exigem detecções diferentes: a
função quebrou (`Errors`), a função nem rodou (idade do dado), e a função rodou
sem erro mas o dado veio ruim (métrica extraída do log JSON). Mais um painel no
CloudWatch e um tópico SNS.

Para saber se está tudo entregando, sem abrir o console:

```bash
make status
```

Detalhes — inclusive por que o "não executou" precisou de uma Lambda de
heartbeat em vez de um alarme sobre `Invocations` — em
[`infra/terraform/README.md`](infra/terraform/README.md).

### Empacotamento: imagem de container, não zip+layer

As 7 funções compartilham a **mesma imagem** (`infra/docker/Dockerfile`),
publicada no ECR — só o `command` (o handler) muda entre elas, via
`image_config` no Terraform. Rodar dentro da imagem base oficial da AWS já
resolve sozinho o problema de baixar o wheel para a plataforma errada, que
apareceu de verdade quando isso ainda era zip+layer buildado num Windows.

Para testar uma função localmente, sem publicar nada:

```bash
infra/docker/run_local.sh lambdas.rio_posicoes.handler.lambda_handler
# noutro terminal:
curl -XPOST "http://localhost:9000/2015-03-31/functions/function/invocations" -d '{}'
```

Usa o Lambda Runtime Interface Emulator, que já vem embutido na imagem base —
não precisa de `aws-sam-cli` nem de nada além do Docker.

### Duas listas de dependências, de propósito

`lambdas/requirements.txt` é para rodar e testar os handlers localmente (inclui
`boto3` e `python-dotenv`). `lambdas/requirements-layer.txt` é só o que vai
**dentro da imagem** — sem `boto3`, que o runtime da Lambda já traz, e sem
`python-dotenv`, que não faz sentido em produção.

### Onde está o resto

- **Por fonte** (formato, frequência real de atualização, particularidades e
  armadilhas): [`docs/FONTES.md`](docs/FONTES.md)
- **Deploy, ligar, verificar, observabilidade e custo**:
  [`infra/terraform/README.md`](infra/terraform/README.md)

## Documentação

| Arquivo | O que tem |
|---|---|
| [`docs/FONTES.md`](docs/FONTES.md) | Referência operacional por fonte: o que cada Lambda faz, e o detalhe de cada API de origem com suas armadilhas |
| [`docs/DECISOES.md`](docs/DECISOES.md) | Data lake vs warehouse, FinOps e plano de contingência de orçamento |
| [`docs/MODELAGEM.md`](docs/MODELAGEM.md) | Modelagem dos dados: entidades, chaves, grão e relacionamentos de cada fonte, medidos nos dados reais |
| [`docs/CONSULTAS.md`](docs/CONSULTAS.md) | Como consultar a camada silver em SQL (Athena): as tabelas, as armadilhas de junção e exemplos que funcionam |
| [`docs/TEMPO-REAL.md`](docs/TEMPO-REAL.md) | O exercício de producer/consumer e os conceitos por trás dele |
| [`infra/terraform/README.md`](infra/terraform/README.md) | Deploy, ligar e verificar o pipeline, observabilidade e custo |
| [`docs/Proposta_inicial_Mapeamento_rotas_onibus.md`](docs/Proposta_inicial_Mapeamento_rotas_onibus.md) | A proposta que originou o projeto: problema, arquitetura, custo e riscos |
