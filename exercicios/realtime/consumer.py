import json
import time

from exercicios.realtime.broker import CANAL_RIO, CANAL_SP, ESTADO_RIO, ESTADO_SP, conectar

RESUMO_A_CADA_SEGUNDOS = 5


def main():
    redis_cliente = conectar()
    pubsub = redis_cliente.pubsub()
    pubsub.subscribe(CANAL_SP, CANAL_RIO)

    print(f"[consumer] escutando '{CANAL_SP}' e '{CANAL_RIO}'...")

    contagem_desde_resumo = 0
    ultimo_resumo = time.monotonic()

    for mensagem in pubsub.listen():
        if mensagem["type"] != "message":
            continue  # a primeira mensagem de cada canal e so a confirmacao do subscribe

        veiculo = json.loads(mensagem["data"])
        praca = veiculo["praca"]
        id_veiculo = veiculo["id_veiculo"] if praca == "rio" else veiculo["prefixo_veiculo"]
        hash_estado = ESTADO_RIO if praca == "rio" else ESTADO_SP

        redis_cliente.hset(hash_estado, str(id_veiculo), json.dumps(veiculo))

        print(f"[consumer] {praca} · veiculo {id_veiculo} · ({veiculo.get('latitude')}, {veiculo.get('longitude')})")

        contagem_desde_resumo += 1
        agora = time.monotonic()
        if agora - ultimo_resumo >= RESUMO_A_CADA_SEGUNDOS:
            taxa = contagem_desde_resumo / (agora - ultimo_resumo)
            print(f"[consumer] --- {taxa:.1f} mensagens/s nos ultimos {RESUMO_A_CADA_SEGUNDOS}s ---")
            contagem_desde_resumo = 0
            ultimo_resumo = agora


if __name__ == "__main__":
    main()
