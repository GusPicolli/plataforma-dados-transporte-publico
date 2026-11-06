{{ config(materialized='table') }}

-- Dimensão de data. Não vem de fonte nenhuma: é gerada.
--
-- Existe porque "compare dia útil com sábado" e "agrupe por mês" hoje
-- exigiriam manipular o texto da partição dt. Com ela viram um join.
--
-- O intervalo começa em 2026-09-01, a mesma data do início da projeção de
-- partição das tabelas silver -- não faz sentido ter data de dimensão sem
-- dado possível do outro lado.

with dias as (
    select
        sequence(
            date '2026-09-01',
            date_add('year', 1, current_date),
            interval '1' day
        ) as intervalo
)

select
    -- CAST explicito pra DATE: sem ele, o format_datetime abaixo forca uma
    -- conversao implicita pra timestamp(0) e o Athena recusa gravar em
    -- Parquet ("Incorrect timestamp precision ... configured precision is
    -- MILLISECONDS").
    cast(data as date)                           as data,
    -- O cast pra DATE aqui tambem nao e opcional, e pelo mesmo motivo: o
    -- sequence() acima devolve TIMESTAMP (o passo e um interval day), entao
    -- "cast(data as varchar)" sozinho rendia '2026-11-06 00:00:00'.
    --
    -- Esta e a coluna que casa com fato_posicoes.dt, que e '2026-11-06'. Com
    -- o horario junto a juncao nao dava erro -- devolvia ZERO LINHA, em
    -- silencio. Achado testando as consultas do roteiro de demonstracao.
    cast(cast(data as date) as varchar)          as data_texto,
    year(data)                                   as ano,
    month(data)                                  as mes,
    day(data)                                    as dia,
    quarter(data)                                as trimestre,
    week(data)                                   as semana_do_ano,
    day_of_week(data)                            as dia_da_semana,
    -- day_of_week devolve 1=segunda ... 7=domingo (ISO-8601)
    element_at(
        array['segunda', 'terca', 'quarta', 'quinta', 'sexta', 'sabado', 'domingo'],
        day_of_week(data)
    )                                            as nome_do_dia,
    day_of_week(data) >= 6                       as eh_fim_de_semana,
    -- A coleta roda de segunda a sexta; fim de semana sem dado novo é
    -- esperado, não é falha. Este campo existe pra consulta não acusar
    -- lacuna onde não há.
    day_of_week(data) <= 5                       as tem_coleta_de_cadastro
from dias
cross join unnest(intervalo) as t(data)
