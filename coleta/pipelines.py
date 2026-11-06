"""Pipelines em lote: coletam tudo de uma praca e gravam CSV em output/.

Sempre buscam TODAS as linhas e TODAS as posicoes/pontos do momento -- nao
aceitam filtro por termo nem por linha, de proposito.

Os handlers das Lambdas (lambdas/) reusam os mesmos clientes daqui, mas nao
estes pipelines: la o destino e o S3 em NDJSON, nao CSV local."""

import os
from datetime import datetime, timezone

from coleta import fortaleza, gtfs, rio, sptrans
from coleta.csv_utils import escrever_csv

PASTA_BASE = "output"

# A ETUFOR so expoe o itinerario como sequencia de logradouros, por sentido.
SENTIDOS_FORTALEZA = (("ida", "itinerarioIda"), ("volta", "itinerarioVolta"))


def _agora():
    return datetime.now(timezone.utc).isoformat()


def _gravar(praca, nome, registros, coletado_em):
    """Carimba coletado_em, grava o CSV e devolve a contagem.

    Os tres pipelines faziam esse mesmo bloco de tres linhas para cada uma
    das suas tabelas -- nove repeticoes no total."""
    for registro in registros:
        registro["coletado_em"] = coletado_em
    escrever_csv(f"{PASTA_BASE}/{praca}/{nome}.csv", registros)
    return len(registros)


def rodar_sptrans():
    token = os.getenv("SPTRANS_TOKEN")
    if not token:
        raise RuntimeError(
            "Defina SPTRANS_TOKEN no arquivo .env (veja .env.example). "
            "Token gratuito em: https://www.sptrans.com.br/desenvolvedores/"
        )

    coletado_em = _agora()
    cookies = sptrans.autenticar(token)

    print("Buscando todas as linhas cadastradas...")
    linhas = _gravar("sptrans", "linhas", sptrans.buscar_todas_linhas(cookies), coletado_em)
    print(f"{linhas} linha(s) encontrada(s).")

    print("Buscando posicao de todos os veiculos em circulacao agora...")
    veiculos = sptrans.flatten_posicao_geral(sptrans.buscar_posicao_geral(cookies))
    posicoes = _gravar("sptrans", "posicoes", veiculos, coletado_em)
    print(f"{posicoes} veiculo(s) em circulacao agora.")

    # /Parada/BuscarParadasPorLinha (ao vivo) so cobre ~18% das linhas, mesmo
    # para linhas com veiculo circulando agora -- e uma lacuna da API, nao
    # throttling (ver docs/FONTES.md). O GTFS oficial cobre isso.
    print("Cruzando GTFS oficial da SPTrans (routes -> trips -> stop_times -> stops)...")
    pontos = _gravar("sptrans", "pontos", gtfs.SPTRANS.buscar_pontos_todas_linhas(), coletado_em)

    return {"linhas": linhas, "posicoes": posicoes, "pontos": pontos}


def rodar_rio():
    coletado_em = _agora()

    print("Buscando todas as linhas (GTFS oficial)...")
    linhas = _gravar("rio", "linhas", gtfs.RIO.buscar_linhas(), coletado_em)
    print(f"{linhas} linha(s) encontrada(s).")

    # buscar_posicao_geral ja deduplica por veiculo: a API devolve o log bruto
    # de pings da janela, nao um retrato do momento (ver docs/FONTES.md).
    print("Buscando posicao de todos os veiculos em circulacao agora...")
    posicoes = _gravar("rio", "posicoes", rio.buscar_posicao_geral(), coletado_em)
    print(f"{posicoes} veiculo(s) em circulacao agora.")

    print("Cruzando GTFS (routes -> trips -> stop_times -> stops) para todas as linhas...")
    pontos = _gravar("rio", "pontos", gtfs.RIO.buscar_pontos_todas_linhas(), coletado_em)

    return {"linhas": linhas, "posicoes": posicoes, "pontos": pontos}


def rodar_fortaleza():
    coletado_em = _agora()

    print("Buscando todas as linhas...")
    registros_linhas = fortaleza.buscar_linhas()
    linhas = _gravar("fortaleza", "linhas", registros_linhas, coletado_em)
    print(f"{linhas} linha(s) encontrada(s).")

    print(f"Buscando itinerario de {linhas} linha(s) (uma chamada por linha)...")
    pontos_brutos, falhas = [], []
    for indice, linha in enumerate(registros_linhas, start=1):
        codigo_linha = linha["numero"]
        try:
            itinerario = fortaleza.buscar_itinerario(codigo_linha)
        except Exception:
            itinerario = {}

        if "ida" not in itinerario and "volta" not in itinerario:
            # A API da ETUFOR e nao-oficial e responde 500 para alguns codigos
            # pontuais; pular a linha em vez de abortar a coleta inteira.
            falhas.append(codigo_linha)
            continue

        for sentido, chave_pontos in SENTIDOS_FORTALEZA:
            bloco = itinerario.get(sentido) or {}
            for ponto in bloco.get(chave_pontos, []):
                pontos_brutos.append(
                    {
                        "codigo_linha": codigo_linha,
                        "sentido": sentido,
                        "logId": ponto.get("logId"),
                        "nome": ponto.get("nome"),
                        "distanciaPercorrida": ponto.get("distanciaPercorrida"),
                    }
                )

        if indice % 100 == 0:
            print(f"  ... {indice}/{linhas} linhas processadas")

    pontos = _gravar("fortaleza", "pontos", pontos_brutos, coletado_em)
    if falhas:
        print(f"{len(falhas)} linha(s) sem itinerario (erro da API da ETUFOR): {falhas}")

    return {"linhas": linhas, "pontos": pontos}


PRACAS = {
    "sptrans": rodar_sptrans,
    "rio": rodar_rio,
    "fortaleza": rodar_fortaleza,
}


def rodar(praca):
    """Roda o pipeline da praca. Devolve (pasta_de_saida, contagens)."""
    if praca not in PRACAS:
        raise KeyError(f'Praca "{praca}" desconhecida. Use: {", ".join(PRACAS)}.')
    return f"{PASTA_BASE}/{praca}", PRACAS[praca]()
