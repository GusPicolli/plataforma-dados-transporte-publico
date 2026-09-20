from datetime import datetime, timezone

from src import rio_client, rio_gtfs
from src.csv_utils import escrever_csv

PASTA_SAIDA = "output/rio"


def rodar_pipeline():
    coletado_em = datetime.now(timezone.utc).isoformat()

    print("Buscando todas as linhas (GTFS oficial)...")
    linhas = rio_gtfs.buscar_linhas()
    for linha in linhas:
        linha["coletado_em"] = coletado_em
    escrever_csv(f"{PASTA_SAIDA}/linhas.csv", linhas)
    print(f"{len(linhas)} linha(s) encontrada(s).")

    print("Buscando posicao de todos os veiculos em circulacao agora...")
    posicoes = rio_client.buscar_posicao_geral()
    for posicao in posicoes:
        posicao["coletado_em"] = coletado_em
    escrever_csv(f"{PASTA_SAIDA}/posicoes.csv", posicoes)
    print(f"{len(posicoes)} veiculo(s) em circulacao agora.")

    print("Cruzando GTFS (routes -> trips -> stop_times -> stops) para todas as linhas...")
    pontos = rio_gtfs.buscar_pontos_todas_linhas()
    for ponto in pontos:
        ponto["coletado_em"] = coletado_em
    escrever_csv(f"{PASTA_SAIDA}/pontos.csv", pontos)

    return {"linhas": len(linhas), "posicoes": len(posicoes), "pontos": len(pontos)}
