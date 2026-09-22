"""Metadado de normalizacao bronze -> silver, declarativo e versionado no
proprio repo (sem banco de metadados por enquanto).

Cada entrada diz, para um par (praca, entidade), qual model canonico usar e
de que campo do bronze vem cada campo canonico. A Lambda de silver nao tem
nenhum "if praca == ..." -- ela so consulta esta tabela. Fonte nova ou
campo renomeado na origem se resolve aqui, sem tocar no handler.

Os nomes do lado esquerdo sao os campos como saem do bronze (ver
schemas/sptrans.py, schemas/rio.py, schemas/fortaleza.py)."""

from schemas.canonico import LinhaCanonica, PontoCanonico, PosicaoCanonica

_PONTO_GTFS = {
    "stop_id": "id_ponto",
    "route_id": "id_linha",
    "route_short_name": "codigo_publico",
    "stop_name": "nome",
    "stop_lat": "latitude",
    "stop_lon": "longitude",
    "coletado_em": "coletado_em",
}

MAPEAMENTOS = {
    ("sp", "posicoes"): {
        "modelo": PosicaoCanonica,
        "campos": {
            "prefixo_veiculo": "id_veiculo",
            "codigo_linha": "id_linha",
            "letreiro": "codigo_publico",
            "latitude": "latitude",
            "longitude": "longitude",
            "horario_veiculo": "timestamp_veiculo",
            "coletado_em": "coletado_em",
        },
    },
    ("sp", "linhas"): {
        "modelo": LinhaCanonica,
        "campos": {
            "cl": "id_linha",
            "lt": "codigo_publico",
            "ts": "origem",
            "tp": "destino",
            "coletado_em": "coletado_em",
        },
    },
    ("sp", "pontos"): {"modelo": PontoCanonico, "campos": _PONTO_GTFS},
    ("rio", "posicoes"): {
        "modelo": PosicaoCanonica,
        "campos": {
            "id_veiculo": "id_veiculo",
            # route_id ja foi visto nulo nessa fonte (por isso id_linha e
            # opcional no canonico), mas na ultima medicao veio preenchido
            # em 1.943/1.943 registros. Nao dependa de nenhum dos dois casos.
            "route_id": "id_linha",
            "servico": "codigo_publico",
            "latitude": "latitude",
            "longitude": "longitude",
            "velocidade": "velocidade",
            "datetime": "timestamp_veiculo",
            "coletado_em": "coletado_em",
        },
    },
    ("rio", "linhas"): {
        "modelo": LinhaCanonica,
        "campos": {
            "route_id": "id_linha",
            "route_short_name": "codigo_publico",
            "route_long_name": "nome",
            "coletado_em": "coletado_em",
        },
    },
    ("rio", "pontos"): {"modelo": PontoCanonico, "campos": _PONTO_GTFS},
    ("fortaleza", "linhas"): {
        "modelo": LinhaCanonica,
        "campos": {
            "numero": "id_linha",
            "numeroNome": "codigo_publico",
            "nome": "nome",
            "coletado_em": "coletado_em",
        },
    },
    ("fortaleza", "pontos"): {
        "modelo": PontoCanonico,
        # Sem latitude/longitude: a ETUFOR so da a sequencia de logradouros,
        # nao coordenadas. Os campos ficam nulos no canonico.
        "campos": {
            "logId": "id_ponto",
            "codigo_linha": "id_linha",
            "nome": "nome",
            "coletado_em": "coletado_em",
        },
    },
}


def obter_mapeamento(praca, entidade):
    mapeamento = MAPEAMENTOS.get((praca, entidade))
    if mapeamento is None:
        raise KeyError(
            f'Sem mapeamento silver para praca="{praca}", entidade="{entidade}". '
            f"Conhecidos: {sorted(MAPEAMENTOS)}"
        )
    return mapeamento
