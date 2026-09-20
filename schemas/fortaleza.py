from typing import Optional

from pydantic import BaseModel


class FortalezaLinha(BaseModel):
    """Um registro de GET /linhas/ (src.fortaleza_client.buscar_linhas)."""

    numero: int
    nome: str
    numeroNome: Optional[str] = None
    tipoLinha: Optional[str] = None


class FortalezaPonto(BaseModel):
    """Um trecho de itinerario, ja achatado (ver lambdas.fortaleza_cadastro.handler).
    Sem lat/lon -- a API so da a sequencia de logradouros, nao coordenadas."""

    codigo_linha: int
    sentido: str
    logId: Optional[int] = None
    nome: str
    distanciaPercorrida: Optional[float] = None
