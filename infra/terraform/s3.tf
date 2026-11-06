data "aws_caller_identity" "atual" {}

resource "aws_s3_bucket" "dados" {
  # Nome de bucket e global entre todas as contas AWS -- inclui o account id
  # pra nao colidir com o de mais ninguem.
  bucket = "${var.project_name}-${var.ambiente}-${data.aws_caller_identity.atual.account_id}"

  # Sem isto, o destroy falha em "BucketNotEmpty" -- que e a protecao certa
  # pro dia a dia. Ver a variavel pra como o ciclo de teste contorna.
  force_destroy = var.permitir_destruir_dados
}

resource "aws_s3_bucket_public_access_block" "dados" {
  bucket = aws_s3_bucket.dados.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dados" {
  bucket = aws_s3_bucket.dados.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "dados" {
  bucket = aws_s3_bucket.dados.id

  rule {
    id     = "bronze-para-infrequent-access"
    status = "Enabled"

    filter {
      prefix = "bronze/"
    }

    # A camada bronze e imutavel e cresce todo mes (ja registrado como risco
    # na Proposta_inicial) -- isso e o guardrail combinado la, nao uma
    # decisao nova.
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }

  # As posicoes crescem ~134 GB/mes com a coleta de minuto a minuto (medido:
  # 4,15 MB por coleta das duas pracas). Sem esta regra o custo sai de ~US$ 4
  # pra ~US$ 24/mes no mes 12, e continua subindo.
  #
  # Expira so o BRONZE de POSICOES. A silver e 93% menor, guarda o mesmo dado
  # ja normalizado, e e o que as consultas usam -- o bronze aqui e copia de
  # auditoria da resposta crua da API. Linhas e pontos nao entram: sao
  # pequenos e coletados 1x/dia.
  #
  # Duas regras porque o filtro do S3 aceita um prefixo literal, sem curinga,
  # e a praca vem antes da entidade no caminho. Fortaleza nao tem posicoes.
  dynamic "rule" {
    for_each = toset(["sp", "rio"])

    content {
      id     = "expirar-bronze-posicoes-${rule.value}"
      status = "Enabled"

      filter {
        prefix = "bronze/praca=${rule.value}/entidade=posicoes/"
      }

      expiration {
        days = 30
      }
    }
  }

  rule {
    id     = "expirar-resultados-athena"
    status = "Enabled"

    filter {
      prefix = "athena-results/"
    }

    # Resultado de consulta e descartavel: o Athena regrava em qualquer nova
    # execucao. Sem esta regra, cada SELECT deixa um CSV no bucket para
    # sempre -- lixo que ninguem lembra de limpar e que so aparece na fatura.
    expiration {
      days = 7
    }
  }
}
