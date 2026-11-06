# Proteções no nível da conta.
#
# O que NAO esta aqui, porque so pode ser feito no console: MFA no usuario
# IAM e rotacao da chave de acesso. Ver "Seguranca" no README deste modulo.

# ---------------------------------------------------------------------------
# 1. Bloqueio de acesso publico ao S3, na CONTA
# ---------------------------------------------------------------------------
# O bucket de dados ja tem o bloqueio, mas isso e por bucket. No nivel da
# conta, qualquer bucket criado depois -- por um colega, por um tutorial, por
# engano -- ja nasce bloqueado. Vazamento de S3 e a falha mais comum em
# conta AWS, e essa e a protecao de maior retorno por esforco que existe.
resource "aws_s3_account_public_access_block" "conta" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# 2. Criptografia de disco por padrao
# ---------------------------------------------------------------------------
# O disco da EC2 do Metabase ja e criptografado explicitamente. Isto garante
# que QUALQUER volume criado depois tambem seja, sem ninguem precisar lembrar.
resource "aws_ebs_encryption_by_default" "conta" {
  enabled = true
}

# ---------------------------------------------------------------------------
# 3. Exigir TLS no bucket de dados
# ---------------------------------------------------------------------------
# Sem isto, uma requisicao por HTTP simples e aceita, e credencial e dado
# trafegam em claro. O custo de negar e zero -- todo cliente AWS moderno ja
# usa HTTPS, entao nada quebra.
resource "aws_s3_bucket_policy" "exigir_tls" {
  bucket = aws_s3_bucket.dados.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "NegarSemTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.dados.arn,
        "${aws_s3_bucket.dados.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.dados]
}

# ---------------------------------------------------------------------------
# 4. Trilha de auditoria
# ---------------------------------------------------------------------------
# Sem CloudTrail nao existe resposta pra "quem fez isso, e quando". Se a
# chave de acesso vazar, e a unica forma de saber o que foi feito com ela.
#
# A primeira trilha de eventos de gerenciamento e GRATUITA; o custo e so o
# armazenamento no S3, que a regra de 90 dias abaixo mantem em centavos.
#
# NUMA CONTA DE VERDADE a trilha moraria FORA do projeto, em conta separada:
# aqui ela e destruida junto no "make tf-destroy", o que derrota parte do
# proposito. Fica assim de proposito, pra nao quebrar o ciclo de teste.

resource "aws_s3_bucket" "auditoria" {
  bucket        = "${var.project_name}-${var.ambiente}-auditoria-${data.aws_caller_identity.atual.account_id}"
  force_destroy = var.permitir_destruir_dados
}

resource "aws_s3_bucket_public_access_block" "auditoria" {
  bucket = aws_s3_bucket.auditoria.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "auditoria" {
  bucket = aws_s3_bucket.auditoria.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "auditoria" {
  bucket = aws_s3_bucket.auditoria.id

  rule {
    id     = "expirar-logs-de-auditoria"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "auditoria" {
  bucket = aws_s3_bucket.auditoria.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudTrailLeAcl"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.auditoria.arn
      },
      {
        Sid       = "CloudTrailEscreve"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.auditoria.arn}/AWSLogs/${data.aws_caller_identity.atual.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid       = "NegarSemTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.auditoria.arn,
          "${aws_s3_bucket.auditoria.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.auditoria]
}

resource "aws_cloudtrail" "principal" {
  name                          = "${var.project_name}-${var.ambiente}"
  s3_bucket_name                = aws_s3_bucket.auditoria.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.auditoria]
}

# ---------------------------------------------------------------------------
# 5. Orcamento com alerta
# ---------------------------------------------------------------------------
# Consulta no Athena e execucao de Lambda sao os vetores de custo de uma
# credencial comprometida. Sem alerta, a descoberta vem pela fatura.
#
# Os limites vem do plano de contingencia em docs/DECISOES.md: 10 e atencao,
# 25 e acao. O projeto custa ~US$ 5/mes, entao o primeiro gatilho e ~2x o
# atual -- folga suficiente pra nao disparar por ruido.
resource "aws_budgets_budget" "mensal" {
  name         = "${var.project_name}-${var.ambiente}"
  budget_type  = "COST"
  limit_amount = "25"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    # 40% de 25 = US$ 10 (atencao); 100% = US$ 25 (acao). O terceiro avisa
    # sobre a PREVISAO, nao o gasto -- chega antes de estourar.
    for_each = var.email_alertas == "" ? [] : [
      { limite = 40, tipo = "ACTUAL" },
      { limite = 100, tipo = "ACTUAL" },
      { limite = 100, tipo = "FORECASTED" },
    ]

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.limite
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.tipo
      subscriber_email_addresses = [var.email_alertas]
    }
  }
}
