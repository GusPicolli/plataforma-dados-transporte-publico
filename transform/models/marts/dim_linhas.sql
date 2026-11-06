-- Dimensão de linhas: uma linha por linha de ônibus, não uma por coleta.
--
-- A silver é append-only. Medido em 09/10/2026: 13.478 registros para 2.698
-- linhas reais em SP — fator 5, o número de coletas. Qualquer COUNT direto
-- na silver mente.
--
-- Esta é uma SCD Tipo 1 (sobrescreve, não guarda histórico). A história
-- existe na silver; quando houver necessidade de "quando esta linha mudou de
-- itinerário?", o caminho é um dbt snapshot, que faz Tipo 2 declarativamente.

with ordenadas as (
    select
        *,
        row_number() over (
            partition by praca, id_linha
            order by coletado_em desc
        ) as versao
    from {{ source('silver', 'linhas') }}
)

select
    praca,
    id_linha,
    codigo_publico,
    -- ATENÇÃO: chave de junção incompleta para SP. Ver os testes em
    -- schema.yml e a seção "Dívidas do modelo" em docs/MODELAGEM.md.
    split_part(codigo_publico, '-', 1) as codigo_base,

    -- Chave composta explicita. O teste "relationships" do dbt compara UMA
    -- coluna -- sem isto ele ignora a praca, e 1.202 posicoes do Rio
    -- casavam falsamente com linhas de SP que tem o mesmo numero.
    praca || '|' || split_part(codigo_publico, '-', 1) as chave_linha,
    nome,
    origem,
    destino,
    coletado_em                        as atualizado_em
from ordenadas
where versao = 1
