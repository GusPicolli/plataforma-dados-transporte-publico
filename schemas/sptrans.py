from typing import Optional

from pydantic import BaseModel


class SPTransLinha(BaseModel):
    """Um registro de GET /Linha/Buscar (src.sptrans_client.buscar_linhas)."""

    cl: int
    lc: bool
    lt: str
    sl: int
    tl: int
    tp: Optional[str] = None
    ts: Optional[str] = None


class SPTransPosicao(BaseModel):
    """Um veiculo, ja achatado por src.sptrans_client.flatten_posicao_geral."""

    codigo_linha: int
    letreiro: Optional[str] = None
    sentido: Optional[int] = None
    origem: Optional[str] = None
    destino: Optional[str] = None
    qtd_veiculos_linha: Optional[int] = None
    prefixo_veiculo: int
    acessivel: bool
    horario_veiculo: str
    latitude: float
    longitude: float
    horario_referencia: Optional[str] = None


class SPTransPonto(BaseModel):
    """Uma parada, do join do GTFS oficial (src.sptrans_gtfs.buscar_pontos_todas_linhas).
    route_short_name/route_long_name podem faltar se o GTFS tiver uma rota
    sem esses campos preenchidos -- por isso opcionais, diferente de stop_id/
    stop_name/lat/lon, que sao o minimo pra um ponto fazer sentido."""

    route_id: str
    route_short_name: Optional[str] = None
    route_long_name: Optional[str] = None
    stop_id: str
    stop_name: str
    stop_desc: Optional[str] = None
    stop_lat: float
    stop_lon: float
