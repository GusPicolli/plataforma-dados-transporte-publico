from datetime import datetime, timedelta, timezone

import requests

BASE_URL = "https://dados.mobilidade.rio/gps/sppo"
FUSO_RIO = timezone(timedelta(hours=-3))
FORMATO_DATA = "%m-%d-%Y %H:%M:%S"


def _janela_atual(janela_minutos):
    agora = datetime.now(FUSO_RIO)
    inicio = agora - timedelta(minutes=janela_minutos)
    return inicio.strftime(FORMATO_DATA), agora.strftime(FORMATO_DATA)


def buscar_posicao_geral(janela_minutos=5):
    data_inicial, data_final = _janela_atual(janela_minutos)
    resposta = requests.get(
        BASE_URL, params={"dataInicial": data_inicial, "dataFinal": data_final}
    )
    registros = resposta.json()

    # A API devolve todos os pings de GPS na janela (varios por veiculo),
    # nao um snapshot. Mantemos so o ping mais recente de cada veiculo.
    mais_recente_por_veiculo = {}
    for registro in registros:
        veiculo = registro["id_veiculo"]
        atual = mais_recente_por_veiculo.get(veiculo)
        if atual is None or registro["datetime"] > atual["datetime"]:
            mais_recente_por_veiculo[veiculo] = registro

    return list(mais_recente_por_veiculo.values())


def buscar_posicao_linha(codigo_linha, janela_minutos=5):
    veiculos = buscar_posicao_geral(janela_minutos)
    return [v for v in veiculos if v.get("servico") == str(codigo_linha)]
