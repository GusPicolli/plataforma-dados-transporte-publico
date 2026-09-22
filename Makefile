# Caminho do venv muda entre Windows e Unix -- detectar aqui deixa todos os
# alvos abaixo funcionando nos dois sem ninguem precisar editar nada.
VENV_BIN := .venv/bin
ifeq ($(OS),Windows_NT)
	VENV_BIN := .venv/Scripts
endif
PY := $(VENV_BIN)/python
PIP := $(VENV_BIN)/pip

.DEFAULT_GOAL := help

.PHONY: help setup check status demo venv install run run-sptrans run-rio run-fortaleza run-all clean \
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

docker-run:  ## Roda uma Lambda local via emulador. Ex: make docker-run HANDLER=lambdas.rio_posicoes.handler.lambda_handler
	@test -n "$(HANDLER)" || (echo "Faltou o HANDLER. Ex: make docker-run HANDLER=lambdas.rio_posicoes.handler.lambda_handler" && exit 1)
	docker run --rm -p 9000:8080 --env-file .env onibus-lambda:local $(HANDLER)

# --- Exercicio de tempo real -------------------------------------------------
# NAO faz parte do caminho de producao (esse e lambdas/ + infra/) -- ver a
# secao "Tempo real" do README.md. Cada alvo roda um processo de cada vez:
# abra um terminal por alvo (broker, 2 producers, consumer, api).

realtime-redis:  ## Sobe o Redis do exercicio de tempo real (precisa de Docker)
	docker run -d --name realtime-redis -p 6379:6379 redis:7-alpine

realtime-producer-sp:  ## Publica posicoes de SP no broker
	$(PY) -m exercicios.realtime.producer_sp

realtime-producer-rio:  ## Publica posicoes do Rio no broker
	$(PY) -m exercicios.realtime.producer_rio

realtime-consumer:  ## Consome o broker e materializa a ultima posicao de cada veiculo
	$(PY) -m exercicios.realtime.consumer

realtime-api:  ## Sobe a API que le o estado materializado (porta 8000)
	$(PY) -m uvicorn exercicios.realtime.api:app --reload --port 8000
