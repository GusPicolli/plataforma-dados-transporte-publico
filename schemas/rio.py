from typing import Optional

from pydantic import BaseModel


class RioLinha(BaseModel):
    """Um registro de routes.txt no GTFS oficial (src.rio_gtfs.buscar_linhas)."""

    route_id: str
    agency_id: Optional[str] = None
    route_short_name: str
    route_long_name: Optional[str] = None
    route_desc: Optional[str] = None
    route_type: Optional[str] = None
    route_color: Optional[str] = None
    route_text_color: Optional[str] = None


class RioPosicao(BaseModel):
    """Um ping de GPS ja deduplicado (src.rio_client.buscar_posicao_geral).
    route_id costuma vir null na fonte -- normal, nao e falha de validacao."""

    id_veiculo: str
    servico: str
    sentido: Optional[str] = None
    latitude: float
    longitude: float
    velocidade: Optional[float] = None
    direcao: Optional[float] = None
    route_id: Optional[str] = None
    trip_id: Optional[str] = None
    shape_id: Optional[str] = None
    datetime: str
    datetime_envio: Optional[str] = None
    datetime_servidor: Optional[str] = None


class RioPonto(BaseModel):
    """Uma parada, do join do GTFS oficial (src.rio_gtfs.buscar_pontos_todas_linhas)."""

    route_id: str
    route_short_name: Optional[str] = None
    route_long_name: Optional[str] = None
    stop_id: str
    stop_name: str
    stop_desc: Optional[str] = None
    stop_lat: float
    stop_lon: float
