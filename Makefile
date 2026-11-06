# Caminho do venv muda entre Windows e Unix -- detectar aqui deixa todos os
# alvos abaixo funcionando nos dois sem ninguem precisar editar nada.
VENV_BIN := .venv/bin
ifeq ($(OS),Windows_NT)
	VENV_BIN := .venv/Scripts
endif
PY := $(VENV_BIN)/python
PIP := $(VENV_BIN)/pip

.DEFAULT_GOAL := help

.PHONY: help setup check status metabase-aws-ligar metabase-aws-desligar metabase-aws-conexao metabase-aws-shell metabase-aws-atualizar metabase-aws-logs bootstrap query query-gold dbt-deps dbt-build dbt-test dbt-docs metabase metabase-stop metabase-limpar demo deploy publish refresh \n	tf-init tf-plan tf-apply tf-ligar tf-desligar tf-destroy venv install run run-sptrans run-rio run-fortaleza run-all clean \
	realtime-redis realtime-producer-sp realtime-producer-rio realtime-consumer realtime-api \
	docker-build docker-run

help:  ## Mostra esta lista
	@echo "Primeira vez no projeto? Rode nesta ordem:"
	@echo "  make setup    # prepara venv, dependencias e .env"
	@echo "  make check    # diz o que ja funciona e o que falta configurar"
	@echo "  make demo     # primeira coleta de verdade, sem precisar de token nenhum"
	@echo ""
	@echo "Todos os comandos:"
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-24s %s\n", $$1, $$2}'

setup: venv install  ## Prepara o projeto do zero (venv + dependencias + .env)
	@test -f .env || (cp .env.example .env && echo ".env criado a partir do .env.example")
	@echo ""
	@echo "Pronto. Rode 'make check' pra ver o que ja da pra executar."

check:  ## Diz se o ambiente esta pronto e o que falta
	@$(PY) scripts/check_ambiente.py

status:  ## Diz se os pipelines na AWS estao rodando normalmente (precisa de credencial)
	@$(PY) scripts/status_pipeline.py

query:  ## Consulta a camada silver via Athena. Ex: make query SQL="SELECT praca, count(*) FROM posicoes GROUP BY praca"
	@test -n "$(SQL)" || (echo 'Faltou o SQL. Ex: make query SQL="SELECT * FROM posicoes LIMIT 5"' && exit 1)
	@$(PY) scripts/consultar.py "$(SQL)"

query-gold:  ## Consulta a camada dimensional. Ex: make query-gold SQL="SELECT * FROM dim_linhas LIMIT 5"
	@test -n "$(SQL)" || (echo 'Faltou o SQL. Ex: make query-gold SQL="SELECT * FROM dim_linhas LIMIT 5"' && exit 1)
	@$(PY) scripts/consultar.py "$(SQL)" --camada gold

# --- Modelagem dimensional (dbt) ---------------------------------------------
# Os modelos vivem em transform/models/. O dbt descobre a ordem sozinho pelo
# grafo de dependencia -- nao ha numeracao de arquivo como em sql/gold/.

# Os nomes saem do terraform output, nao ficam fixos em arquivo nenhum --
# e por isso que profiles.yml pode ser versionado sem expor a conta.
TF_OUT = terraform -chdir=infra/terraform output -raw
DBT_ENV = DBT_PROFILES_DIR=transform 	DBT_BUCKET=$$($(TF_OUT) bucket_dados) 	DBT_SCHEMA_SILVER=$$($(TF_OUT) athena_database) 	DBT_SCHEMA_GOLD=$$($(TF_OUT) athena_database_gold) 	DBT_WORKGROUP=$$($(TF_OUT) athena_workgroup)

DBT := $(DBT_ENV) $(VENV_BIN)/dbt

dbt-deps:  ## Instala os pacotes do dbt (primeira vez)
	@$(DBT) deps --project-dir transform

dbt-build:  ## Roda os modelos E os testes da camada dimensional
	@$(DBT) build --project-dir transform

dbt-test:  ## So os testes (nao reconstroi nada)
	@$(DBT) test --project-dir transform

dbt-docs:  ## Gera e abre o catalogo com o grafo de linhagem
	@$(DBT) docs generate --project-dir transform
	@$(DBT) docs serve --project-dir transform

demo:  ## Coleta real do Rio (a unica fonte que nao exige token nem AWS)
	$(PY) main.py rio

venv:
	python -m venv .venv

install:
	$(PIP) install -q --disable-pip-version-check -r requirements.txt
	$(PIP) install -q --disable-pip-version-check -r lambdas/requirements.txt

# --- Pipelines em lote (rodam local, gravam CSV em output/) -------------------
# Cada pipeline sempre busca TODAS as linhas e TODAS as posicoes/pontos
# daquela cidade no momento da execucao (sem filtro por termo/linha).

run:
	$(PY) main.py $(ARGS)

run-sptrans:  ## Coleta SP -- precisa de SPTRANS_TOKEN no .env
	$(PY) main.py sptrans

run-rio:  ## Coleta Rio -- nao precisa de token
	$(PY) main.py rio

run-fortaleza:  ## Coleta Fortaleza (~2min) -- nao precisa de token
	$(PY) main.py fortaleza

run-all: run-sptrans run-rio run-fortaleza  ## Coleta as 3 pracas em sequencia

clean:  ## Apaga venv, saidas e caches
	rm -rf .venv output .cache
	find . -type d -name __pycache__ -exec rm -rf {} +

# --- Lambdas de producao, rodando local via container ------------------------

docker-build:  ## Builda a imagem das Lambdas (precisa de Docker)
	docker build --provenance=false --sbom=false -f infra/docker/Dockerfile -t onibus-lambda:local .

docker-run: docker-build  ## Roda uma Lambda local no emulador. Ex: make docker-run FONTE=rio_posicoes
	@test -n "$(FONTE)" || (echo "Faltou a FONTE. Ex: make docker-run FONTE=rio_posicoes  (ou: sp_posicoes, sp_cadastro, rio_cadastro, fortaleza_cadastro)" && exit 1)
	@echo "Invoque noutro terminal com:"
	@echo '  curl -XPOST "http://localhost:9000/2015-03-31/functions/function/invocations" -d "{}"'
	docker run --rm -p 9000:8080 --env-file .env -e FONTE=$(FONTE) onibus-lambda:local lambdas.ingestao.handler.lambda_handler

# --- Infraestrutura na AWS (Terraform) ---------------------------------------
# Ordem que importa: a imagem precisa existir no ECR ANTES do apply, porque a
# Lambda so aceita ser criada apontando pra uma tag que ja existe. "make
# deploy" faz a sequencia inteira na ordem certa.

TF := terraform -chdir=infra/terraform

# As chamadas a "$(MAKE)" abaixo ficam ENTRE ASPAS de proposito: no Windows
# o make costuma estar em "C:\Program Files (x86)\...", e o "(x86)" sem
# aspas vira erro de sintaxe no shell ("unexpected token `('").
bootstrap:  ## Do zero ate rodando: ECR -> imagem -> infra -> modelos dbt
	@test -f infra/terraform/terraform.tfvars || (echo "Falta infra/terraform/terraform.tfvars. Copie o .example e preencha o SPTRANS_TOKEN." && exit 1)
	@echo "== 1/5  providers =="
	@$(TF) init -input=false
	@echo ""
	@echo "== 2/5  so o repositorio ECR =="
	@# Em duas fases porque a Lambda so aceita ser criada apontando pra uma
	@# tag que JA existe no ECR -- e e o proprio Terraform que cria o ECR.
	@$(TF) plan -input=false -target=aws_ecr_repository.lambda -out=bootstrap.tfplan
	@$(TF) apply bootstrap.tfplan
	@rm -f infra/terraform/bootstrap.tfplan
	@echo ""
	@echo "== 3/5  imagem no ECR =="
	@"$(MAKE)" --no-print-directory publish
	@echo ""
	@echo "== 4/5  o resto da infraestrutura =="
	@$(TF) plan -input=false -out=bootstrap.tfplan
	@$(TF) apply bootstrap.tfplan
	@rm -f infra/terraform/bootstrap.tfplan
	@echo ""
	@echo "== 5/5  modelos dimensionais =="
	@"$(MAKE)" --no-print-directory dbt-deps
	@"$(MAKE)" --no-print-directory dbt-build
	@echo ""
	@echo "Pronto. Os agendamentos sobem DESLIGADOS -- 'make tf-ligar' para ativar."
	@echo "Confira com 'make status'."

tf-init:  ## Baixa os providers do Terraform (primeira vez)
	$(TF) init

tf-plan:  ## Mostra o que mudaria na AWS e salva o plano em plano.tfplan
	$(TF) plan -out=plano.tfplan

tf-apply: ## Aplica o plano salvo por tf-plan (nunca aplica as cegas)
	@test -f infra/terraform/plano.tfplan || (echo "Nao existe plano salvo. Rode 'make tf-plan' e confira a saida antes." && exit 1)
	$(TF) apply plano.tfplan
	@rm -f infra/terraform/plano.tfplan

publish:  ## Builda a imagem e publica no ECR (precisa de Docker)
	bash infra/docker/build_and_push.sh "$$($(TF) output -raw ecr_repository_url)" latest

refresh:  ## Faz as Lambdas adotarem a imagem :latest atual (o Terraform nao faz)
	@$(PY) scripts/atualizar_funcoes.py

deploy: publish tf-plan tf-apply refresh  ## Deploy completo: imagem -> ECR -> Terraform -> funcoes
	@echo ""
	@echo "Deploy concluido. Verifique com 'make status'."

tf-ligar:  ## Liga os agendamentos -- passa a coletar sozinho (e a gerar custo)
	$(TF) plan -var 'agendamento_habilitado=true' -out=plano.tfplan
	$(TF) apply plano.tfplan
	@rm -f infra/terraform/plano.tfplan

tf-desligar:  ## Desliga os agendamentos (os recursos continuam existindo)
	$(TF) plan -var 'agendamento_habilitado=false' -out=plano.tfplan
	$(TF) apply plano.tfplan
	@rm -f infra/terraform/plano.tfplan

tf-destroy:  ## APAGA toda a infraestrutura, inclusive os dados no S3
	@echo "Isto apaga o bucket (bronze E silver), o ECR, as 7 funcoes e os alarmes."
	@echo "Digite 'apagar tudo' para confirmar:"
	@read -r resposta; test "$$resposta" = "apagar tudo" || (echo "Cancelado." && exit 1)
	@# DOIS passos, e nao "destroy -var" direto: force_destroy e rastreado no
	@# ESTADO, entao o destroy usa o valor que esta la, nao o que vem no -var.
	@# Sem o apply antes, o destroy falha em "BucketNotEmpty". Verificado: o
	@# plan com -var acusa "force_destroy = false -> true", provando que e
	@# mudanca de estado e nao so de configuracao.
	@echo "1/2  liberando a remocao (bucket e ECR)..."
	@$(TF) apply -auto-approve -input=false -var 'permitir_destruir_dados=true' -target=aws_s3_bucket.dados -target=aws_ecr_repository.lambda
	@echo "2/2  destruindo..."
	$(TF) destroy -var 'permitir_destruir_dados=true'

# --- Dashboards na AWS (EC2 que liga e desliga) ------------------------------
# A instancia fica DESLIGADA por padrao. Ligar e desligar nao destroi nada:
# o disco persiste, e com ele dashboards, usuarios e conexoes.
#
# O "ligar" descobre o seu IP publico do momento e libera so ele na porta
# 3000 -- Metabase aberto pra internet enxerga o data lake inteiro.

metabase-aws-ligar:  ## Liga a instancia do Metabase na AWS
	@$(TF) plan -input=false -out=mb.tfplan -var 'metabase_ligado=true'
	@$(TF) apply mb.tfplan
	@rm -f infra/terraform/mb.tfplan
	@echo ""
	@echo "Ligada. A primeira subida leva ~3 min (baixa as imagens)."
	@echo "Acesso: pelo hostname do Cloudflare Tunnel -- a porta 3000 NAO"
	@echo "e exposta, o Metabase escuta so em localhost dentro da maquina."
	@echo ""
	@echo "Sem tunel configurado ainda? Veja docs/CONSULTAS.md."

metabase-aws-desligar:  ## Desliga a instancia (para de cobrar; dashboards ficam)
	@$(TF) plan -input=false -out=mb.tfplan -var 'metabase_ligado=false'
	@$(TF) apply mb.tfplan
	@rm -f infra/terraform/mb.tfplan
	@echo "Desligada. 'make metabase-aws-ligar' religa com tudo salvo."

metabase-aws-conexao:  ## Mostra os valores pra conectar o Metabase ao Athena
	@$(PY) scripts/metabase_aws_conexao.py

metabase-aws-shell:  ## Abre um shell na instancia via SSM (sem SSH, sem porta aberta)
	@ID=$$(aws ec2 describe-instances --region us-east-1 	  --filters "Name=tag:Name,Values=onibus-tempo-real-metabase" "Name=instance-state-name,Values=running" 	  --query "Reservations[0].Instances[0].InstanceId" --output text); 	test "$$ID" != "None" || (echo "A instancia nao esta ligada. Rode: make metabase-aws-ligar" && exit 1); 	echo "Conectando em $$ID (Ctrl+D pra sair)..."; 	aws ssm start-session --region us-east-1 --target "$$ID"

metabase-aws-atualizar:  ## Aplica a versao configurada do Metabase, sem recriar a maquina
	@ID=$$(aws ec2 describe-instances --region us-east-1 	  --filters "Name=tag:Name,Values=onibus-tempo-real-metabase" "Name=instance-state-name,Values=running" 	  --query "Reservations[0].Instances[0].InstanceId" --output text); 	test "$$ID" != "None" || (echo "A instancia nao esta ligada." && exit 1); 	echo "Reiniciando os containers com a versao do SSM..."; 	aws ssm send-command --region us-east-1 --instance-ids "$$ID" 	  --document-name AWS-RunShellScript 	  --parameters 'commands=["/usr/local/bin/subir-metabase.sh"]' 	  --query "Command.CommandId" --output text

metabase-aws-logs:  ## Mostra o log do container do Metabase na instancia
	@ID=$$(aws ec2 describe-instances --region us-east-1 	  --filters "Name=tag:Name,Values=onibus-tempo-real-metabase" "Name=instance-state-name,Values=running" 	  --query "Reservations[0].Instances[0].InstanceId" --output text); 	test "$$ID" != "None" || (echo "A instancia nao esta ligada." && exit 1); 	C=$$(aws ssm send-command --region us-east-1 --instance-ids "$$ID" 	  --document-name AWS-RunShellScript 	  --parameters 'commands=["docker ps -a","docker logs --tail 40 metabase 2>&1"]' 	  --query "Command.CommandId" --output text); 	sleep 6; 	aws ssm get-command-invocation --region us-east-1 --command-id "$$C" --instance-id "$$ID" 	  --query "StandardOutputContent" --output text

# --- Dashboards (Metabase local) ---------------------------------------------
# Roda na SUA maquina, nao na AWS. O Athena e acessivel de fora, entao nao ha
# motivo pra pagar um container 24/7 na nuvem enquanto so voce usa: o Metabase
# hospedado seria o item mais caro do projeto inteiro, que hoje custa ~US$ 4/mes.
#
# O driver do Athena ja vem embutido na imagem oficial -- nao precisa baixar
# .jar nenhum (verificado: o Metabase registra o driver :athena no boot).

metabase:  ## Sobe o Metabase local pra montar dashboards (precisa de Docker)
	@$(PY) scripts/metabase.py

metabase-stop:  ## Para o Metabase (dashboards e conexoes ficam salvos)
	@docker stop onibus-metabase >/dev/null 2>&1 && echo "Parado. 'make metabase' religa com tudo salvo." || echo "Nao estava rodando."

metabase-limpar:  ## APAGA o Metabase e TODOS os dashboards criados nele
	@echo "Isto apaga os dashboards, perguntas e conexoes do Metabase local."
	@echo "Digite 'apagar' para confirmar:"
	@read -r r; test "$$r" = "apagar" || (echo "Cancelado." && exit 1)
	@docker rm -f onibus-metabase >/dev/null 2>&1 || true
	@docker volume rm onibus-metabase-dados >/dev/null 2>&1 || true
	@echo "Removido."

# --- Exercicio de tempo real -------------------------------------------------
# NAO faz parte do caminho de producao (esse e lambdas/ + infra/) -- ver a
# secao "Tempo real" do README.md. Cada alvo roda um processo de cada vez:
# abra um terminal por alvo (broker, 2 producers, consumer, api).

realtime-redis:  ## Sobe o Redis do exercicio de tempo real (precisa de Docker)
	docker run -d --name realtime-redis -p 6379:6379 redis:7-alpine

realtime-producer-sp:  ## Publica posicoes de SP no broker
	$(PY) -m exemplos.realtime.producer_sp

realtime-producer-rio:  ## Publica posicoes do Rio no broker
	$(PY) -m exemplos.realtime.producer_rio

realtime-consumer:  ## Consome o broker e materializa a ultima posicao de cada veiculo
	$(PY) -m exemplos.realtime.consumer

realtime-api:  ## Sobe a API que le o estado materializado (porta 8000)
	$(PY) -m uvicorn exemplos.realtime.api:app --reload --port 8000
