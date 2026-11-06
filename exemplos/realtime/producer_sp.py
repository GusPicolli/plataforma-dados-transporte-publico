import json
import os
import time
from datetime import datetime, timezone

from dotenv import load_dotenv

from exemplos.realtime.broker import CANAL_SP, conectar
from coleta.sptrans import autenticar, buscar_posicao_geral, flatten_posicao_geral

load_dotenv()

INTERVALO_SEGUNDOS = float(os.getenv("SP_INTERVALO_SEGUNDOS", "5"))
FILTRO_LETREIRO = os.getenv("SP_FILTRO_LETREIRO")  # ex: "8000-10"; vazio = todos os veiculos


def _autenticar():
    token = os.getenv("SPTRANS_TOKEN")
    if not token:
        raise RuntimeError("Defina SPTRANS_TOKEN no .env (veja .env.example).")
    return autenticar(token)


def main():
    redis_cliente = conectar()
    cookies = _autenticar()

    filtro_desc = f"filtro: {FILTRO_LETREIRO}" if FILTRO_LETREIRO else "sem filtro (todos os veiculos)"
    print(f"[producer-sp] publicando em '{CANAL_SP}' a cada {INTERVALO_SEGUNDOS}s ({filtro_desc})")

    while True:
        inicio = time.monotonic()

        try:
            veiculos = flatten_posicao_geral(buscar_posicao_geral(cookies))
        except Exception as erro:
            print(f"[producer-sp] falha na coleta ({erro}); reautenticando...")
            cookies = _autenticar()
            time.sleep(INTERVALO_SEGUNDOS)
            continue

        if FILTRO_LETREIRO:
            veiculos = [v for v in veiculos if v.get("letreiro") == FILTRO_LETREIRO]

        publicado_em = datetime.now(timezone.utc).isoformat()
        for veiculo in veiculos:
            mensagem = {**veiculo, "praca": "sp", "id_veiculo": veiculo["prefixo_veiculo"], "publicado_em": publicado_em}
            redis_cliente.publish(CANAL_SP, json.dumps(mensagem))

        print(f"[producer-sp] publicou {len(veiculos)} posicao(oes)")

        decorrido = time.monotonic() - inicio
        time.sleep(max(0.0, INTERVALO_SEGUNDOS - decorrido))


if __name__ == "__main__":
    main()
