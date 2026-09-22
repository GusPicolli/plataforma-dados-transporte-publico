# Infraestrutura — Terraform

Implementa a arquitetura da
[Proposta_inicial_Mapeamento_rotas_onibus.md](../../docs/Proposta_inicial_Mapeamento_rotas_onibus.md):
**7 funções Lambda** — 5 de ingestão, 1 de normalização para a camada silver e
1 de heartbeat — mais agendamento, observabilidade e um bucket S3 com bronze e
silver. Athena e Metabase ainda não entram; esta fase é ingestão e normalização.

## Estado: aplicado e rodando

Foi aplicado numa conta AWS real e está no ar. `terraform plan` acusa
`No changes` — o código e a infraestrutura batem.

O que já foi exercido de verdade, não só planejado:

- As 7 funções executaram na AWS, não só localmente.
- O caminho completo roda sem intervenção: EventBridge dispara, a Lambda grava
  o NDJSON na bronze, o evento do S3 aciona a silver, e o Parquet aparece no
  mesmo minuto.
- Os alarmes foram validados **contra falha real** — o único aceso é o do
  `rio_cadastro`, que está genuinamente quebrado.

### Falha conhecida: `rio_cadastro`

A fonte GTFS do Rio no ArcGIS responde `403 Forbidden` ("You do not have
permissions to access this resource"). Confirmado batendo direto no host, sem
container no meio: **não é o nosso código nem permissão IAM**. As posições do
Rio vêm de outra origem e seguem coletando, então a praça está degradada, não
fora do ar.

Do jeito que foi desenhado, isso é visível em três lugares sem ninguém
investigar: o `tenacity` tenta 3 vezes e devolve erro estruturado, o alarme
`rio-cadastro-dado-velho` acende, e `make status` marca `SEM DADO`.

### O que este módulo ainda não tem

- **State local.** Sem backend remoto nem lock — se mais de uma pessoa for
  aplicar, combinem antes; dois `apply` simultâneos corrompem o state. É o item
  mais importante da fila.
- **Tag `latest` num ECR mutável.** Não dá para responder qual código está
  rodando numa função, nem voltar atrás. O caminho é tag imutável por SHA.
- **Sem CI.** Nada roda `validate`/`fmt` antes de um merge.

## Bugs reais encontrados aqui (e por que ficam registrados)

Servem de aviso para quem for mexer:

- `block_public_policies` não existe em `aws_s3_bucket_public_access_block` — o
  nome certo é `block_public_policy`. Pego pelo `terraform validate`.
- O BuildKit atual gera manifesto com attestation que **a Lambda rejeita**
  (`image manifest, config or layer media type ... is not supported`). Por isso
  todos os scripts de build usam `--provenance=false --sbom=false`.
- `lambdas/common/__init__.py` importava `dotenv` sem guarda; como a imagem não
  traz `python-dotenv` de propósito, derrubava o módulo antes do handler rodar.
  Virou `try/except ImportError`.
- Na Lambda, só `/tmp` é gravável — o cache do GTFS em `.cache/` dava
  `Read-only file system`.
- Sem `schedule_expression_timezone`, o EventBridge assume **UTC**: a janela
  documentada como 5h–22h rodava de fato das 2h às 19h de Brasília.

## Pré-requisitos

1. [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.7 (validei com 1.9.8).
2. Docker Desktop (ou equivalente) rodando — pra build/push da imagem e pra testar local.
3. AWS CLI configurado (`aws configure`) com permissão pra ECR, Lambda, S3, IAM, SSM e EventBridge Scheduler.

## Deploy (2 fases — é assim mesmo, não é engano)

O Lambda só aceita ser criado apontando pra uma tag que **já existe** no
ECR. Como o Terraform também é quem cria o repositório ECR, dá pra criar
tudo de uma vez só na primeira vez:

```bash
# 1. Configurar variaveis
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars com o SPTRANS_TOKEN real -- nunca commitar esse arquivo

# 2. Criar so o repositorio ECR primeiro
terraform init
terraform apply -target=aws_ecr_repository.lambda

# 3. Buildar e publicar a imagem (usa a URL que o passo 2 criou)
REPO_URL=$(terraform output -raw ecr_repository_url)
../docker/build_and_push.sh "$REPO_URL" latest

# 4. Agora sim, aplicar o resto (Lambdas, Scheduler, etc.) apontando pra essa imagem
terraform plan
terraform apply
```

Em deploys **seguintes** (a imagem já existe, só o código mudou): rode o
passo 3 de novo com uma tag nova (ex: um hash do commit) e depois
`terraform apply -var="image_tag=<tag-nova>"`.

## O que é criado

**68 recursos** no total. Os que importam:

| Recurso | Qtd | Observação |
|---|---|---|
| `aws_s3_bucket` | 1 | Guarda bronze **e** silver, separados por prefixo. Versionamento e criptografia ligados, acesso público bloqueado |
| `aws_ecr_repository` | 1 | A imagem compartilhada pelas 7 funções; lifecycle mantém as 10 tags mais recentes |
| `aws_lambda_function` | 7 | 5 de ingestão + `silver` + `heartbeat` — `package_type = "Image"`, mesma imagem, `command` diferente em cada |
| `aws_scheduler_schedule` | 6 | 5 de ingestão + o heartbeat de hora em hora. A `silver` não tem: dispara por evento do S3 |
| `aws_s3_bucket_notification` | 1 | bronze → silver, filtrado por prefixo `bronze/` e sufixo `.ndjson` (sem os dois, laço infinito) |
| `aws_cloudwatch_metric_alarm` | 15 | Erro (7), dado velho (5), qualidade do dado (3) |
| `aws_cloudwatch_log_metric_filter` | 8 | Transformam o log JSON em métrica |
| `aws_cloudwatch_dashboard` | 1 | Painel único |
| `aws_sns_topic` | 1 | Destino dos alarmes; a inscrição por e-mail é opcional |
| `aws_cloudwatch_log_group` | 7 | Um por função, retenção de 30 dias |
| `aws_ssm_parameter` | 1 | Token da SPTrans, `SecureString` — nunca no código |
| `aws_iam_role` | 4 | Ingestão, silver, heartbeat e Scheduler — separadas de propósito |

**Por que 4 roles e não uma:** as permissões são genuinamente diferentes. A
ingestão escreve na bronze e lê o token; a silver lê a bronze e escreve na
silver; o heartbeat só lista o bucket e publica métrica. Separar evita que um
bug na ingestão escreva na silver, e que a silver enxergue o token da SPTrans.

## Ligar o pipeline e verificar que está rodando

O apply **não liga** a coleta recorrente: `agendamento_habilitado` é `false` por
padrão, de propósito — os 6 schedules sobem criados e desligados. Ligar custo e
tráfego recorrente contra API de terceiro deve ser uma escolha explícita.

### Ligar

```bash
cd infra/terraform
terraform plan  -var 'agendamento_habilitado=true' -out=ligar.tfplan   # confira: deve ser 5 in-place, 0 destroy
terraform apply ligar.tfplan
```

Para desligar, o mesmo com `agendamento_habilitado=false`. Os recursos continuam
existindo — só param de disparar.

### Verificar

```bash
make status
```

Lê Scheduler, CloudWatch e S3 e aplica um critério único por pipeline: o
agendamento está ligado, houve zero erro nas últimas 24h, e o dado mais recente
no S3 é mais novo que a cadência esperada. Sai com código 1 se algo precisa de
atenção, então serve direto num alarme ou num passo de CI.

| Estado | Significa |
|---|---|
| `OK` | agendado, sem erro, dado dentro da tolerância |
| `PAUSADO` | agendamento desligado — nada novo vai aparecer sozinho |
| `FALHA` | a Lambda executou e deu erro nas últimas 24h |
| `SEM DADO` | está ligada e sem erro, mas não gravou nada dentro da tolerância |

A distinção entre `FALHA` e `SEM DADO` importa: a primeira é a função quebrando,
a segunda é ela nem chegando a rodar (agenda errada, fuso errado, gatilho não
disparando). São causas diferentes e o diagnóstico muda.

A tolerância por pipeline está em `PIPELINES`, em
[`scripts/status_pipeline.py`](../../scripts/status_pipeline.py) — é a cadência
mais folga, não a cadência crua, porque atraso de minutos é rotina e não deveria
acender alerta.

### Onde olhar quando algo acusa

```bash
aws logs tail /aws/lambda/onibus-tempo-real-sp-posicoes --since 1h --follow
```

Cada execução loga, em JSON, quantos registros vieram, quantos passaram na
validação, quantos foram descartados, a chave gravada no S3 e a duração.

### Limitação conhecida

`make status` é **sob demanda**: alguém precisa rodar. Não há alarme que avise
sozinho — se um pipeline parar às 3h da manhã, ninguém fica sabendo até a próxima
consulta. Fechar isso é um alarme do CloudWatch sobre a métrica `Errors` das
funções, mais um sobre idade do objeto mais recente no S3.

## Observabilidade

Três classes de falha, detectadas de formas diferentes porque se parecem
nada uma com a outra:

| Classe | Como se detecta | Alarme |
|---|---|---|
| A função quebrou | métrica `Errors` da Lambda | `*-erro` (6, uma por função) |
| A função nem rodou | idade do dado no S3, medida de hora em hora | `*-dado-velho` (5) |
| Rodou, sem erro, dado ruim | métrica extraída do log JSON | `registros-invalidos`, `*-volume-baixo` |

A terceira é a que escapa de monitoramento ingênuo: nada falha, o alarme
fica quieto e o dado apodrece. É o motivo de a ingestão logar
`total_valido` e `total_invalido` — esses campos viram métrica via
`aws_cloudwatch_log_metric_filter`.

**Por que existe uma Lambda de heartbeat** ([`lambdas/heartbeat/`](../../lambdas/heartbeat/)):
não dá para alarmar de forma confiável sobre a **ausência** de execução usando
a métrica `Invocations`. Ela é esparsa — só ganha ponto quando a função roda —
e o CloudWatch, ao avaliar, procura datapoint para trás até achar algum.

Isso foi implementado, testado contra a conta real e descartado: com o
`sp_cadastro` 26h parado, o alarme continuou **OK**, porque encontrou o ponto
de dois dias antes. Só disparava para função que nunca rodou na vida — o caso
que menos precisa de alarme. `FILL(m,0)` também não resolve: sem nenhum ponto
na janela, não há lacuna a preencher.

O heartbeat roda de hora em hora e **sempre** publica um ponto por pipeline.
Métrica densa, alarme confiável. E o que ele mede — há quanto tempo não chega
dado — é a pergunta que importa, em vez de um proxy dela.

As tolerâncias (`local.tolerancia_idade_h`) são as mesmas de `PIPELINES` em
[`scripts/status_pipeline.py`](../../scripts/status_pipeline.py), de propósito:
o critério do alarme e o do terminal precisam ser o mesmo, senão um diz OK e o
outro diz problema.

**Por que uma métrica só para registros inválidos:** os 6 filtros escrevem na
mesma métrica, sem dimensão. Cada métrica customizada custa por mês, e uma
por função seria 6× o custo para responder "qual?" — pergunta que o log
responde de graça. O alarme diz "vá olhar"; o painel e o log dizem onde.

**Os pisos de volume** (`local.piso_volume`) não são "quantos ônibus
esperamos" — são o ponto abaixo do qual só pode ser fonte vazia. Medido: SP
entregou 8.047, 7.657 e 5.049 veículos em coletas reais; Rio, 1.962 e 3.488.
Pisos em 200 e 50, frouxos de propósito: alarme de volume que grita por
variação normal vira ruído e para de ser lido.

### Receber os alarmes por e-mail

```hcl
# terraform.tfvars
email_alertas = "voce@exemplo.com"
```

A AWS envia um e-mail de confirmação. **Enquanto ninguém clicar no link, a
inscrição fica `pending confirmation` e não entrega nada** — o alarme dispara,
aparece no console, e o e-mail não chega. Confira em SNS → Subscriptions.

Sem e-mail configurado os alarmes são criados mesmo assim: ficam visíveis no
console e no painel, só não empurram aviso.

### Painel

Um dashboard `onibus-tempo-real-dev` com execuções, erros, duração p95
(proximidade do timeout), veículos coletados por execução, registros
descartados, e um widget de log com os últimos WARNING e ERROR das 6 funções.

### Custo

| Item | Qtd | US$/mês |
|---|---|---|
| Alarmes | 15 | 1,50 |
| Métricas customizadas | 8 | 2,40 |
| Lambda heartbeat (720 exec/mês) | | ~0 |
| Dashboard | 1 | 0 (3 grátis) |
| Ingestão de log (~22 MB) | | 0,01 |
| SNS e-mail | | 0 (1.000 grátis) |

≈ **US$ 3,91/mês** fora do free tier. O free tier permanente cobre 10 alarmes,
10 métricas customizadas, 3 dashboards e 5 GB de log — dentro dele, ~US$ 0,50.

## Testar localmente antes de publicar

```bash
../docker/run_local.sh lambdas.rio_posicoes.handler.lambda_handler
# noutro terminal:
curl -XPOST "http://localhost:9000/2015-03-31/functions/function/invocations" -d '{}'
```

Isso usa o Runtime Interface Emulator que já vem na imagem base da AWS —
não precisa instalar nada além do Docker. Detalhes de como apontar pra um
S3 de mentira (MinIO) em vez da AWS real estão comentados dentro do
`run_local.sh`.

## Destruir

```bash
terraform destroy
```

Isso não apaga a imagem do ECR sozinho se `force_delete` não estiver
configurado no repositório (não está, de propósito — apagar o repo com
imagem dentro é irreversível, preferi deixar explícito).
