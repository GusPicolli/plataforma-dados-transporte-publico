-- Dimensão de pontos, com tratamento geoespacial.
--
-- Grão: o PAR (linha, parada). A mesma parada atende várias linhas, e cada
-- combinação é uma linha da tabela — deduplicar só por id_ponto perderia as
-- demais linhas que passam por ela.
--
-- Fortaleza fica sem geometria de propósito: a ETUFOR entrega a sequência de
-- logradouros do itinerário, não coordenadas. Nulo honesto.

with ordenadas as (
    select
        *,
        row_number() over (
            partition by praca, id_linha, id_ponto
            order by coletado_em desc
        ) as versao
    from {{ source('silver', 'pontos') }}
)

select
    praca,
    id_ponto,
    id_linha,
    codigo_publico,
    split_part(codigo_publico, '-', 1) as codigo_base,
    nome,
    latitude,
    longitude,

    -- Geometria em WKT: é o formato que o Athena, o QGIS e a maioria das
    -- ferramentas de BI leem. Guardar como texto evita depender de um tipo
    -- geométrico que nem todo cliente entende.
    case
        when latitude is not null and longitude is not null
            then st_astext(st_point(longitude, latitude))
    end as geometria_wkt,

    -- Indice H3, calculado na silver (o Athena nao tem funcao H3). Grade
    -- hexagonal: celulas vizinhas ficam todas a mesma distancia, diferente
    -- de grade retangular, onde a diagonal e mais longe que a horizontal.
    -- r8 ~0,74 km2 (bairro), r9 ~0,11 km2 (quarteirao).
    h3_r8,
    h3_r9,

    coletado_em as atualizado_em
from ordenadas
where versao = 1
