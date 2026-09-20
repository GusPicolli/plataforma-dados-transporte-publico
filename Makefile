.PHONY: venv install run run-sptrans run-rio run-fortaleza run-all clean \
	realtime-redis realtime-producer-sp realtime-producer-rio realtime-consumer realtime-api

venv:
	python -m venv .venv

install:
	.venv/Scripts/pip install -r requirements.txt

run:
	.venv/Scripts/python main.py $(ARGS)

# Cada pipeline sempre busca TODAS as linhas e TODAS as posicoes/pontos
# daquela cidade no momento da execucao (sem filtro por termo/linha).
run-sptrans:
	.venv/Scripts/python main.py sptrans

run-rio:
	.venv/Scripts/python main.py rio

run-fortaleza:
	.venv/Scripts/python main.py fortaleza

run-all: run-sptrans run-rio run-fortaleza

clean:
	rm -rf .venv output .cache
	find . -type d -name __pycache__ -exec rm -rf {} +

# Exercicio de tempo real (ver realtime/README.md). Cada alvo roda um processo
# de cada vez -- abra um terminal por alvo (broker, 2 producers, consumer, api).
realtime-redis:
	docker run -d --name realtime-redis -p 6379:6379 redis:7-alpine

realtime-producer-sp:
	.venv/Scripts/python -m realtime.producer_sp

realtime-producer-rio:
	.venv/Scripts/python -m realtime.producer_rio

realtime-consumer:
	.venv/Scripts/python -m realtime.consumer

realtime-api:
	.venv/Scripts/python -m uvicorn realtime.api:app --reload --port 8000