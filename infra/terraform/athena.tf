# Acesso SQL a camada silver: Glue Data Catalog + Athena.
#
# DECISAO: as tabelas sao DECLARADAS aqui, nao descobertas por um Glue
# Crawler. O crawler custa por execucao (minimo de 10 min cobrados a cada
# passada) e INFERE o schema -- e nos ja sabemos o schema, porque a silver
# grava a partir de schemas/canonico.py. Deixar o crawler adivinhar o que ja
# esta declarado em codigo seria pagar para introduzir incerteza.
#
# DECISAO: uma tabela por ENTIDADE, nao por praca. E o que a camada canonica
# compra: posicoes de SP, Rio e Fortaleza tem o mesmo schema, entao viram uma
# tabela so com "praca" como particao. Dai sai "compare as tres cidades" numa
# query, em vez de UNION ALL entre tabelas separadas.

locals {
  # Os tipos abaixo sao os do Parquet que a silver grava de verdade
  # (verificados lendo os arquivos), nao os que o pydantic sugere.
  #
  # "praca" NAO entra nestas listas: e chave de particao, e o Glue rejeita
  # uma coluna que seja as duas coisas. A coluna existe dentro do Parquet e
  # o Athena simplesmente a ignora, lendo o valor do caminho.
  colunas_silver = {
    posicoes = [
      { name = "id_veiculo", type = "string", comment = "Prefixo/identificador do veiculo na frota" },
      { name = "id_linha", type = "string", comment = "Id da linha na origem; nulo quando a fonte nao informa" },
      { name = "codigo_publico", type = "string", comment = "Como a linha aparece pro passageiro (letreiro, servico)" },
      { name = "latitude", type = "double", comment = "" },
      { name = "longitude", type = "double", comment = "" },
      { name = "velocidade", type = "double", comment = "So o Rio informa; nulo nas demais" },
      { name = "timestamp_veiculo", type = "string", comment = "Quando o VEICULO reportou -- nao quando coletamos" },
      { name = "coletado_em", type = "string", comment = "Quando a ingestao gravou na bronze" },
      { name = "h3_r8", type = "string", comment = "Celula H3 na resolucao 8 (~0,74 km2) -- agregacao de bairro" },
      { name = "h3_r9", type = "string", comment = "Celula H3 na resolucao 9 (~0,11 km2) -- agregacao de quarteirao" },
    ]
    linhas = [
      { name = "id_linha", type = "string", comment = "" },
      { name = "codigo_publico", type = "string", comment = "" },
      { name = "nome", type = "string", comment = "" },
      { name = "origem", type = "string", comment = "So a SPTrans informa" },
      { name = "destino", type = "string", comment = "So a SPTrans informa" },
      { name = "coletado_em", type = "string", comment = "" },
    ]
    pontos = [
      { name = "id_ponto", type = "string", comment = "" },
      { name = "id_linha", type = "string", comment = "" },
      { name = "codigo_publico", type = "string", comment = "" },
      { name = "nome", type = "string", comment = "" },
      { name = "latitude", type = "double", comment = "Nulo em Fortaleza: a ETUFOR so da logradouro, sem coordenada" },
      { name = "longitude", type = "double", comment = "Nulo em Fortaleza" },
      { name = "coletado_em", type = "string", comment = "" },
      { name = "h3_r8", type = "string", comment = "Celula H3 na resolucao 8 (~0,74 km2) -- agregacao de bairro" },
      { name = "h3_r9", type = "string", comment = "Celula H3 na resolucao 9 (~0,11 km2) -- agregacao de quarteirao" },
    ]
  }

  # A partir de quando existe dado. Serve so pra projecao de particao nao
  # varrer anos vazios -- ampliar e inofensivo, estreitar esconde dado.
  inicio_particoes = "2026-09-01"
}

resource "aws_glue_catalog_database" "silver" {
  name        = replace("${var.project_name}_${var.ambiente}", "-", "_")
  description = "Camada silver: posicoes, linhas e pontos das 3 pracas no schema canonico."
}

# Banco separado por camada, e nao um prefixo "gold_" no mesmo banco: quem
# consulta ve duas listas distintas e sabe, pelo banco que escolheu, se esta
# olhando o dado normalizado (silver) ou o dado pronto pra uso (gold).
#
# As views da gold NAO sao declaradas aqui. Uma view do Athena vira, no Glue,
# uma tabela com o plano do Presto embutido em base64 -- escrever isso a mao
# em Terraform e fragil e ilegivel. O SQL mora em sql/gold/ e e aplicado por
# "make gold", que e idempotente (CREATE OR REPLACE).
resource "aws_glue_catalog_database" "gold" {
  name        = replace("${var.project_name}_${var.ambiente}_gold", "-", "_")
  description = "Camada gold: dimensoes deduplicadas e fatos com as correcoes de juncao e fuso ja aplicadas."
}

resource "aws_glue_catalog_table" "silver" {
  for_each = local.colunas_silver

  name          = each.key
  database_name = aws_glue_catalog_database.silver.name
  table_type    = "EXTERNAL_TABLE"
  description   = "Camada silver de ${each.key}, ja normalizada. Particionada por praca, data e hora."

  parameters = {
    classification       = "parquet"
    EXTERNAL             = "TRUE"
    "has_encrypted_data" = "false"

    # --- Projecao de particao -------------------------------------------
    # Sem isto seria preciso rodar MSCK REPAIR TABLE (ou ADD PARTITION) toda
    # vez que a ingestao gravasse numa hora nova -- ou seja, a cada minuto
    # durante a janela de posicoes. A projecao CALCULA as particoes a partir
    # do padrao do caminho, entao nao ha nada a manter: particao nova passa a
    # ser consultavel no instante em que o arquivo cai no S3.
    "projection.enabled" = "true"

    "projection.praca.type"   = "enum"
    "projection.praca.values" = "sp,rio,fortaleza"

    # Enum de um valor so: e isto que impede a tabela "posicoes" de enxergar
    # os arquivos de "linhas", ja que as duas moram sob o mesmo prefixo de
    # praca e so se separam um nivel adiante.
    "projection.entidade.type"   = "enum"
    "projection.entidade.values" = each.key

    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.range"         = "${local.inicio_particoes},NOW"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"

    "projection.hh.type"   = "integer"
    "projection.hh.range"  = "0,23"
    "projection.hh.digits" = "2"

    "storage.location.template" = "s3://${aws_s3_bucket.dados.bucket}/silver/praca=$${praca}/entidade=$${entidade}/dt=$${dt}/hh=$${hh}"
  }

  partition_keys {
    name    = "praca"
    type    = "string"
    comment = "sp | rio | fortaleza"
  }
  partition_keys {
    name    = "entidade"
    type    = "string"
    comment = "Fixo por tabela; existe porque faz parte do caminho no S3"
  }
  partition_keys {
    name    = "dt"
    type    = "string"
    comment = "Data da coleta (UTC), yyyy-MM-dd"
  }
  partition_keys {
    name    = "hh"
    type    = "string"
    comment = "Hora da coleta (UTC), 00-23"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.dados.bucket}/silver/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters            = { "serialization.format" = "1" }
    }

    dynamic "columns" {
      for_each = each.value
      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.comment
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Athena
# ---------------------------------------------------------------------------

resource "aws_athena_workgroup" "principal" {
  name        = "${var.project_name}-${var.ambiente}"
  description = "Consultas sobre a camada silver."

  configuration {
    # Forca TODA consulta a gravar resultado no local abaixo. Sem isto, cada
    # pessoa configura o seu, e o bucket vira um deposito de resultados
    # soltos sem ciclo de vida.
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.dados.bucket}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    # Corta a consulta que varreria mais de 1 GB. No tamanho atual da silver
    # (dezenas de MB) isso nunca dispara por uso legitimo -- e um freio
    # contra o acidente de varrer tudo sem filtro, nao um limite de uso.
    bytes_scanned_cutoff_per_query = 1073741824
  }

  # Sem isto o destroy falha quando ha historico de consulta no workgroup.
  force_destroy = true
}

output "athena_database" {
  description = "Banco no Glue Data Catalog com as tabelas da silver."
  value       = aws_glue_catalog_database.silver.name
}

output "athena_database_gold" {
  description = "Banco no Glue Data Catalog com as views da gold."
  value       = aws_glue_catalog_database.gold.name
}

output "athena_workgroup" {
  description = "Workgroup a usar no console do Athena."
  value       = aws_athena_workgroup.principal.name
}
