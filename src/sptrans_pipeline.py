import os
from datetime import datetime, timezone

from src import sptrans_gtfs
from src.csv_utils import escrever_csv
from src.sptrans_client import (
    autenticar,
    buscar_posicao_geral,
    buscar_todas_linhas,
    flatten_posicao_geral,
)

PASTA_SAIDA = "output/sptrans"


def rodar_pipeline():
    token = os.getenv("SPTRANS_TOKEN")
    if not token:
        raise RuntimeError(
            "Defina SPTRANS_TOKEN no arquivo .env (veja .env.example). "
            "Token gratuito em: https://www.sptrans.com.br/desenvolvedores/"
        )

    coletado_em = datetime.now(timezone.utc).isoformat()
    cookies = autenticar(token)

    print("Buscando todas as linhas cadastradas...")
    linhas = buscar_todas_linhas(cookies)
    for linha in linhas:
        linha["coletado_em"] = coletado_em
    escrever_csv(f"{PASTA_SAIDA}/linhas.csv", linhas)
    print(f"{len(linhas)} linha(s) encontrada(s).")

    print("Buscando posicao de todos os veiculos em circulacao agora...")
    posicao_geral = buscar_posicao_geral(cookies)
    posicoes = flatten_posicao_geral(posicao_geral)
    for posicao in posicoes:
        posicao["coletado_em"] = coletado_em
    escrever_csv(f"{PASTA_SAIDA}/posicoes.csv", posicoes)
    print(f"{len(posicoes)} veiculo(s) em circulacao agora.")

    print("Cruzando GTFS oficial da SPTrans (routes -> trips -> stop_times -> stops)...")
    # /Parada/BuscarParadasPorLinha (ao vivo) so cobre ~18% das linhas, mesmo
    # para linhas com veiculo circulando agora -- e uma lacuna da API, nao de
    # throttling (ver README). O GTFS oficial da SPTrans cobre isso.
    pontos = sptrans_gtfs.buscar_pontos_todas_linhas()
    for ponto in pontos:
        ponto["coletado_em"] = coletado_em
    escrever_csv(f"{PASTA_SAIDA}/pontos.csv", pontos)

    return {"linhas": len(linhas), "posicoes": len(posicoes), "pontos": len(pontos)}
