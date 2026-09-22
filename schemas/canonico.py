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


class PosicaoCanonica(_Canonico):
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


class PontoCanonico(_Canonico):
    id_ponto: str
    id_linha: Optional[str] = None
    codigo_publico: Optional[str] = None
    nome: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
