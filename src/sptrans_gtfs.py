import csv
import io
import os
import zipfile

import requests

GTFS_URL = "https://www.sptrans.com.br/umbraco/Surface/PerfilDesenvolvedor/BaixarGTFS"

# Na Lambda o disco so e gravavel em /tmp -- ".cache/" (CLI local) da
# "Read-only file system". AWS_LAMBDA_FUNCTION_NAME so existe dentro da
# Lambda de verdade, entao isso nao muda nada pra quem roda local.
# /tmp tambem e efemero entre invocacoes (cold start rebaixa de novo) --
# cache entre invocacoes fica pra quando isso migrar pro S3.
_DIRETORIO_CACHE = "/tmp" if os.environ.get("AWS_LAMBDA_FUNCTION_NAME") else ".cache"
CACHE_PATH = os.path.join(_DIRETORIO_CACHE, "gtfs_sptrans.zip")


def _baixar_gtfs():
    if not os.path.exists(CACHE_PATH):
        os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
        resposta = requests.get(GTFS_URL)
        resposta.raise_for_status()
        with open(CACHE_PATH, "wb") as arquivo:
            arquivo.write(resposta.content)

    return zipfile.ZipFile(CACHE_PATH)


def _ler_csv(pacote_gtfs, nome_arquivo):
    with pacote_gtfs.open(nome_arquivo) as arquivo_bruto:
        texto = io.TextIOWrapper(arquivo_bruto, encoding="utf-8")
        return list(csv.DictReader(texto))


def buscar_pontos_todas_linhas():
    """Junta routes -> trips -> stop_times -> stops numa unica passada pelo
    GTFS oficial da SPTrans, retornando um ponto de parada por linha que
    passa por ele. A chave aqui e o letreiro+sentido (ex: "1012-10"), o
    mesmo formato do campo "letreiro" de posicoes.csv -- nao o codigo
    numerico "cl" de linhas.csv, que a Olho Vivo nao expoe no GTFS."""
    with _baixar_gtfs() as pacote_gtfs:
        rotas_por_id = {rota["route_id"]: rota for rota in _ler_csv(pacote_gtfs, "routes.txt")}

        viagens = _ler_csv(pacote_gtfs, "trips.txt")
        rota_da_viagem = {viagem["trip_id"]: viagem["route_id"] for viagem in viagens}

        stop_ids_por_rota = {}
        with pacote_gtfs.open("stop_times.txt") as arquivo_bruto:
            texto = io.TextIOWrapper(arquivo_bruto, encoding="utf-8")
            for registro in csv.DictReader(texto):
                route_id = rota_da_viagem.get(registro["trip_id"])
                if route_id is None:
                    continue
                stop_ids_por_rota.setdefault(route_id, set()).add(registro["stop_id"])

        paradas_por_id = {parada["stop_id"]: parada for parada in _ler_csv(pacote_gtfs, "stops.txt")}

        linha_pontos = []
        for route_id, stop_ids in stop_ids_por_rota.items():
            rota = rotas_por_id.get(route_id, {})
            for stop_id in stop_ids:
                parada = paradas_por_id.get(stop_id, {})
                linha_pontos.append(
                    {
                        "route_id": route_id,
                        "route_short_name": rota.get("route_short_name"),
                        "route_long_name": rota.get("route_long_name"),
                        **parada,
                    }
                )
        return linha_pontos
