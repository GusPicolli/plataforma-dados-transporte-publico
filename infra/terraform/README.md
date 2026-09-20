# Infraestrutura — Terraform

Implementa a arquitetura da [Proposta_inicial_Mapeamento_rotas_onibus.md](../../docs/Proposta_inicial_Mapeamento_rotas_onibus.md):
5 funções Lambda (uma por praça × cadência), disparadas pelo EventBridge
Scheduler, escrevendo na camada bronze de um bucket S3. Sem Athena/Metabase
ainda — essa fase é só a ingestão (ver `docs/FONTES.md` pros detalhes de
cada fonte).

**Empacotamento: imagem de container, não zip.** As 5 funções rodam a
partir da mesma imagem Docker (`infra/docker/Dockerfile`), publicada no
ECR — o que muda entre elas é só o `image_config.command` (o handler) em
cada `aws_lambda_function`. Trocamos de zip+layer pra isso de propósito,
como exercício — na escala atual (poucas dependências leves) zip
continuava sendo suficiente; container image compensa mais quando surgir
dependência nativa pesada (ex: GDAL/geopandas, cogitado pra fase de
enriquecimento geográfico).

**O que eu validei e o que eu não fiz:**
- ✅ `terraform validate` passa (corrigi 2 bugs reais nessa fase: `block_public_policies` não existe em `aws_s3_bucket_public_access_block` — o nome certo é `block_public_policy` — e o provider `archive` ficou órfão depois de trocar zip por imagem, removido de `versions.tf`).
- ✅ `terraform fmt` aplicado.
- ✅ `docker build` da imagem — funciona (~800 MB, `pydantic_core` já vem como `.so` Linux certo, de graça, sem flag nenhuma — o problema de plataforma que existia no zip some sozinho aqui).
- ✅ **As 5 funções rodadas de verdade** via `docker run` + Lambda Runtime Interface Emulator (a mesma imagem, trocando só o handler no `docker run`), com um MinIO local fazendo de S3 (rede Docker dedicada). 4 delas gravaram com sucesso: `rio_posicoes` (3.237 posições), `sp_posicoes` (10.078), `sp_cadastro` (2.692 linhas + 96.477 pontos), `fortaleza_cadastro` (543 linhas + 19.524 pontos, ~133s — dentro do timeout de 420s configurado).
- ⚠️ `rio_cadastro` **falhou** — não é bug nosso: a fonte GTFS do Rio no ArcGIS está devolvendo `403 Forbidden` ("You do not have permissions...") agora, confirmado batendo direto no host, sem container no meio. É a instabilidade que já esperávamos de uma fonte rotulada "beta". O lado bom: isso testou o caminho de falha de verdade — `tenacity` tentou 3x, esgotou, e o erro voltou estruturado com stack trace completo, exatamente como desenhado. Vale checar de novo mais tarde se a fonte volta.
- 🐛 **Achei e corrigi 1 bug real testando o container**: `lambdas/common/__init__.py` importava `dotenv` sem guarda — como a imagem não tem `python-dotenv` (de propósito, não faz sentido em produção), a importação derrubava o módulo inteiro (`ModuleNotFoundError`) antes mesmo do handler rodar. Virou `try/except ImportError`.
- ✅ `terraform validate` re-confirmado depois de todas essas mudanças.
- ❌ **Ainda não rodei `terraform plan`/`apply` contra a AWS de verdade** — sem credenciais AWS nesta máquina, e de qualquer forma criar recursos reais e cobráveis não é decisão minha pra tomar sozinho.

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

| Recurso | Quantidade | Observação |
|---|---|---|
| `aws_s3_bucket` | 1 | Camada bronze (só o que essa fase escreve); silver/gold ficam pra próxima fase |
| `aws_ecr_repository` | 1 | Guarda a imagem compartilhada pelas 5 funções; lifecycle policy mantém só as 10 tags mais recentes |
| `aws_lambda_function` | 5 | sp_posicoes, sp_cadastro, rio_posicoes, rio_cadastro, fortaleza_cadastro — `package_type = "Image"`, mesma imagem, `command` diferente cada uma |
| `aws_scheduler_schedule` | 5 | Um por função — cadência de posição (30 min) separada de cadastro (1x/dia), ver `variables.tf` |
| `aws_ssm_parameter` | 1 | Token da SPTrans, `SecureString` |
| `aws_cloudwatch_log_group` | 5 | Retenção de 30 dias (ver seção de custo na proposta) |
| roles/policies IAM | 2 roles | Uma pra execução das Lambdas, uma pro Scheduler invocar as Lambdas |

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
