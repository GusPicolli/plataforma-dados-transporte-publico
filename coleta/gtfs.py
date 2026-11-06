"""Leitura de feeds GTFS estaticos.

SPTrans e Rio publicam GTFS oficial, e a logica de ler os dois e a MESMA --
baixar o zip, cachear, e cruzar routes -> trips -> stop_times -> stops. Antes
isso vivia em dois modulos que diferiam so na URL e no nome do cache; o resto
era copia byte a byte. Agora e uma classe e duas instancias.

Fortaleza nao entra aqui: a ETUFOR nao publica GTFS utilizavel, por isso os
pontos de la saem da API de itinerario (ver coleta/fortaleza.py)."""

import csv
import io
import os
import zipfile

import requests

# Na Lambda o disco so e gravavel em /tmp -- ".cache/" (uso local) da
# "Read-only file system". AWS_LAMBDA_FUNCTION_NAME so existe dentro da
# Lambda de verdade, entao isso nao muda nada pra quem roda local.
# /tmp tambem e efemero entre invocacoes (cold start baixa de novo) --
# cache entre invocacoes ficaria pra quando isso migrar pro S3.
_DIRETORIO_CACHE = "/tmp" if os.environ.get("AWS_LAMBDA_FUNCTION_NAME") else ".cache"


class FonteGTFS:
    """Um feed GTFS. Instancias prontas no fim do modulo."""

    def __init__(self, nome, url):
        self.nome = nome
        self.url = url
        self.cache_path = os.path.join(_DIRETORIO_CACHE, f"gtfs_{nome}.zip")

    def _abrir(self):
        if not os.path.exists(self.cache_path):
            os.makedirs(os.path.dirname(self.cache_path), exist_ok=True)
            resposta = requests.get(self.url)
            resposta.raise_for_status()
            with open(self.cache_path, "wb") as arquivo:
                arquivo.write(resposta.content)

        return zipfile.ZipFile(self.cache_path)

    @staticmethod
    def _ler_csv(pacote_gtfs, nome_arquivo):
        with pacote_gtfs.open(nome_arquivo) as arquivo_bruto:
            texto = io.TextIOWrapper(arquivo_bruto, encoding="utf-8")
            return list(csv.DictReader(texto))

    def buscar_linhas(self):
        with self._abrir() as pacote_gtfs:
            return self._ler_csv(pacote_gtfs, "routes.txt")

    def buscar_pontos_todas_linhas(self):
        """Junta routes -> trips -> stop_times -> stops numa UNICA passada,
        devolvendo um par linha+ponto por parada de cada linha (uma linha com
        N paradas gera N registros).

        A passada unica importa: o stop_times.txt do Rio tem ~86 MB, e ler
        esse arquivo mais de uma vez domina o tempo total.

        Atencao a chave de juncao em SP: o GTFS identifica a linha pelo
        letreiro com sentido (route_short_name, ex: "1012-10") -- o mesmo
        formato do campo "letreiro" de posicoes.csv, e NAO o codigo numerico
        "cl" de linhas.csv, que a Olho Vivo nao expoe no GTFS.
        """
        with self._abrir() as pacote_gtfs:
            rotas_por_id = {
                rota["route_id"]: rota
                for rota in self._ler_csv(pacote_gtfs, "routes.txt")
            }

            viagens = self._ler_csv(pacote_gtfs, "trips.txt")
            rota_da_viagem = {v["trip_id"]: v["route_id"] for v in viagens}

            stop_ids_por_rota = {}
            with pacote_gtfs.open("stop_times.txt") as arquivo_bruto:
                texto = io.TextIOWrapper(arquivo_bruto, encoding="utf-8")
                for registro in csv.DictReader(texto):
                    route_id = rota_da_viagem.get(registro["trip_id"])
                    if route_id is None:
                        continue
                    stop_ids_por_rota.setdefault(route_id, set()).add(registro["stop_id"])

            paradas_por_id = {
                parada["stop_id"]: parada
                for parada in self._ler_csv(pacote_gtfs, "stops.txt")
            }

            linha_pontos = []
            for route_id, stop_ids in stop_ids_por_rota.items():
                rota = rotas_por_id.get(route_id, {})
                for stop_id in stop_ids:
                    linha_pontos.append(
                        {
                            "route_id": route_id,
                            "route_short_name": rota.get("route_short_name"),
                            "route_long_name": rota.get("route_long_name"),
                            **paradas_por_id.get(stop_id, {}),
                        }
                    )
            return linha_pontos


SPTRANS = FonteGTFS(
    "sptrans",
    "https://www.sptrans.com.br/umbraco/Surface/PerfilDesenvolvedor/BaixarGTFS",
)

# A URL mudou em 2026. O item no ArcGIS
# (8ffe62ad3b2f42e49814bf941654ea6c) passou a responder 403 tanto no dado
# quanto nos METADADOS -- que e como o ArcGIS responde pra item privado ou
# removido, nao pra bloqueio de download. A prefeitura publicou um item novo
# ("GTFS do Rio de Janeiro", tipo Document Link) apontando pra ca.
#
# Repare que agora e o MESMO host da API de GPS (dados.mobilidade.rio): a
# prefeitura consolidou as duas fontes do Rio num lugar so. O schema do zip
# e identico ao anterior -- mesmas colunas, mesmo formato de route_id.
RIO = FonteGTFS("rio", "https://dados.mobilidade.rio/gtfs/schedule")
