"""Modelo canonico da camada silver: o schema unico que as 3 pracas passam
a falar depois da normalizacao. Campo que a fonte nao tem fica nulo de
proposito -- nulo honesto e melhor que valor inventado, e a cobertura por
praca esta documentada em docs/FONTES.md."""

from typing import Optional

from pydantic import BaseModel, ConfigDict


class _Canonico(BaseModel):
    # As fontes divergem no tipo do mesmo conceito (prefixo de veiculo e int
    # na SPTrans e string no Rio, por exemplo). Padronizamos em str e
    # deixamos o pydantic converter, em vez de espalhar cast pelo mapeamento.
    model_config = ConfigDict(coerce_numbers_to_str=True)

    praca: str
    coletado_em: Optional[str] = None


class _ComGeo(BaseModel):
    """Indice espacial H3, preenchido pela silver quando ha coordenada.

    H3 e uma grade hexagonal hierarquica da Uber. Duas razoes pra usar aqui
    em vez de so lat/lon: agrupar por regiao vira GROUP BY (sem shapefile de
    bairro), e celulas vizinhas tem distancia uniforme -- diferente de grade
    retangular, onde vizinho na diagonal fica mais longe que na horizontal.

    Resolucao 8 (~0,74 km2) e resolucao 9 (~0,11 km2): a primeira da
    agregacao de bairro, a segunda de quarteirao. Guardar as duas custa dois
    campos de texto e evita recalcular, que no Athena nao da -- ele nao tem
    funcao H3 nativa.
    """

    h3_r8: Optional[str] = None
    h3_r9: Optional[str] = None


class PosicaoCanonica(_Canonico, _ComGeo):
    id_veiculo: str
    id_linha: Optional[str] = None
    codigo_publico: Optional[str] = None
    latitude: float
    longitude: float
    velocidade: Optional[float] = None
    timestamp_veiculo: Optional[str] = None


class LinhaCanonica(_Canonico):
    id_linha: str
    codigo_publico: Optional[str] = None
    nome: Optional[str] = None
    origem: Optional[str] = None
    destino: Optional[str] = None


class PontoCanonico(_Canonico, _ComGeo):
    id_ponto: str
    id_linha: Optional[str] = None
    codigo_publico: Optional[str] = None
    nome: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
