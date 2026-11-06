{{ config(materialized='table') }}

-- FATO: um veículo num instante.
--
-- NÃO é deduplicado, e isso é proposital. Medido: a silver já está no grão
-- certo (10.529 registros = 10.529 eventos distintos). Posição é evento —
-- o histórico é o dado, não ruído a limpar.
--
-- Materializada em tabela, diferente das dimensões: o cálculo geoespacial
-- abaixo é uma junção com agregação contra todas as paradas da linha, e não
-- vale repetir isso a cada consulta.

with posicoes as (

    select
        praca,
        dt,
        hh,
        id_veiculo,
        id_linha,
        codigo_publico,
        split_part(codigo_publico, '-', 1) as codigo_base,
        praca || '|' || split_part(codigo_publico, '-', 1) as chave_linha,
        latitude,
        longitude,
        velocidade,
        h3_r8,
        h3_r9,

        -- Correção de fuso. A API do Data.Rio devolve horário de Brasília
        -- com sufixo "Z", que significa UTC. Medido: às 23:50 UTC a origem
        -- respondeu "20:49:45Z". Sem isto, comparar instante entre praças
        -- dá 3 horas de erro.
        --
        -- O CAST ... AT TIME ZONE 'UTC' não é enfeite: from_iso8601_timestamp
        -- devolve "timestamp with time zone", tipo que view do Glue rejeita.
        cast(
            case
                when praca = 'rio'
                    then from_iso8601_timestamp(timestamp_veiculo) + interval '3' hour
                else from_iso8601_timestamp(timestamp_veiculo)
            end at time zone 'UTC' as timestamp
        ) as instante_utc,

        -- O valor como a origem mandou, preservado: se a fonte corrigir o
        -- fuso do lado dela, dá pra perceber comparando os dois.
        timestamp_veiculo as instante_origem,
        cast(from_iso8601_timestamp(coletado_em) at time zone 'UTC' as timestamp) as coletado_em

    from {{ source('silver', 'posicoes') }}

),

paradas as (

    select praca, codigo_publico, latitude, longitude
    from {{ ref('dim_pontos') }}
    where latitude is not null

)

select
    p.praca,
    p.dt,
    p.hh,
    p.id_veiculo,
    p.id_linha,
    p.codigo_publico,
    p.codigo_base,
    p.chave_linha,
    p.latitude,
    p.longitude,
    p.velocidade,
    p.h3_r8,
    p.h3_r9,
    p.instante_utc,
    p.instante_origem,
    p.coletado_em,

    st_astext(st_point(p.longitude, p.latitude)) as geometria_wkt,

    -- MEDIDA geoespacial: a que distância o veículo está da parada mais
    -- próxima da PRÓPRIA linha. Responde "está parado num ponto ou no meio
    -- do caminho?" sem precisar de mapa.
    --
    -- great_circle_distance devolve QUILÔMETROS (verificado: SP->Rio = 360,7).
    -- ST_Distance devolveria graus, que não é distância.
    --
    -- Fica nulo quando a praça não tem pontos com coordenada (
    -- Fortaleza nao tem coordenada, entao fica nula la.
    cast(
        min(
            great_circle_distance(p.latitude, p.longitude, s.latitude, s.longitude)
        ) * 1000 as integer
    ) as metros_ate_parada_mais_proxima

from posicoes p
left join paradas s
    on s.praca = p.praca
    and s.codigo_publico = p.codigo_publico
group by
    p.praca, p.dt, p.hh, p.id_veiculo, p.id_linha, p.codigo_publico,
    p.codigo_base, p.chave_linha, p.latitude, p.longitude, p.velocidade,
    p.h3_r8, p.h3_r9,
    p.instante_utc, p.instante_origem, p.coletado_em
