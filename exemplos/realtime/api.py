import json

from fastapi import FastAPI, HTTPException

from exemplos.realtime.broker import ESTADO_RIO, ESTADO_SP, conectar

app = FastAPI(title="Posicao de onibus em tempo real")
redis_cliente = conectar()

HASHES_POR_PRACA = {"sp": ESTADO_SP, "rio": ESTADO_RIO}


def _hash_da_praca(praca):
    hash_estado = HASHES_POR_PRACA.get(praca)
    if hash_estado is None:
        raise HTTPException(status_code=404, detail=f'Praca "{praca}" desconhecida. Use "sp" ou "rio".')
    return hash_estado


@app.get("/health")
def health():
    return {"redis": redis_cliente.ping()}


@app.get("/posicoes/{praca}")
def posicoes_da_praca(praca: str):
    hash_estado = _hash_da_praca(praca)
    veiculos = redis_cliente.hgetall(hash_estado)
    return {"praca": praca, "total": len(veiculos), "veiculos": [json.loads(v) for v in veiculos.values()]}


@app.get("/posicoes/{praca}/{id_veiculo}")
def posicao_do_veiculo(praca: str, id_veiculo: str):
    hash_estado = _hash_da_praca(praca)
    veiculo = redis_cliente.hget(hash_estado, id_veiculo)
    if veiculo is None:
        raise HTTPException(status_code=404, detail=f'Veiculo "{id_veiculo}" sem posicao conhecida em "{praca}".')
    return json.loads(veiculo)
