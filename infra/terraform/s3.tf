data "aws_caller_identity" "atual" {}

resource "aws_s3_bucket" "dados" {
  # Nome de bucket e global entre todas as contas AWS -- inclui o account id
  # pra nao colidir com o de mais ninguem.
  bucket = "${var.project_name}-${var.ambiente}-${data.aws_caller_identity.atual.account_id}"
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
}
