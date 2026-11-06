import os

import redis

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))

CANAL_SP = "posicoes:sp"
CANAL_RIO = "posicoes:rio"

# Hash com a ultima posicao conhecida de cada veiculo, mantido pelo consumer.
# Chave do hash = id do veiculo; valor = JSON da leitura mais recente.
ESTADO_SP = "estado:sp"
ESTADO_RIO = "estado:rio"


def conectar():
    return redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
