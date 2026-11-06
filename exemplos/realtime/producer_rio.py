import json
import os
import time
from datetime import datetime, timezone

from dotenv import load_dotenv

from exemplos.realtime.broker import CANAL_RIO, conectar
from coleta.rio import buscar_posicao_geral

load_dotenv()

INTERVALO_SEGUNDOS = float(os.getenv("RIO_INTERVALO_SEGUNDOS", "5"))
FILTRO_SERVICO = os.getenv("RIO_FILTRO_SERVICO")  # ex: "497"; vazio = todos os veiculos

# Janela pequena porque o poll e frequente -- so precisa ser larga o
# suficiente pra nao perder ping se uma chamada atrasar um pouco.
JANELA_MINUTOS = 2


def main():
    redis_cliente = conectar()

    filtro_desc = f"filtro: servico {FILTRO_SERVICO}" if FILTRO_SERVICO else "sem filtro (todos os veiculos)"
    print(f"[producer-rio] publicando em '{CANAL_RIO}' a cada {INTERVALO_SEGUNDOS}s ({filtro_desc})")

    while True:
        inicio = time.monotonic()

        try:
            veiculos = buscar_posicao_geral(janela_minutos=JANELA_MINUTOS)
        except Exception as erro:
            print(f"[producer-rio] falha na coleta ({erro})")
            time.sleep(INTERVALO_SEGUNDOS)
            continue

        if FILTRO_SERVICO:
            veiculos = [v for v in veiculos if v.get("servico") == FILTRO_SERVICO]

        publicado_em = datetime.now(timezone.utc).isoformat()
        for veiculo in veiculos:
            mensagem = {**veiculo, "praca": "rio", "publicado_em": publicado_em}
            redis_cliente.publish(CANAL_RIO, json.dumps(mensagem))

        print(f"[producer-rio] publicou {len(veiculos)} posicao(oes)")

        decorrido = time.monotonic() - inicio
        time.sleep(max(0.0, INTERVALO_SEGUNDOS - decorrido))


if __name__ == "__main__":
    main()
