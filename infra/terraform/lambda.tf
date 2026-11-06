locals {
  # As 5 funcoes de ingestao. Todas rodam a MESMA imagem e o MESMO handler
  # (lambdas/ingestao/handler.py) -- o que diferencia uma da outra e a
  # variavel de ambiente FONTE, que seleciona a entrada correspondente em
  # lambdas/ingestao/fontes.py.
  funcoes = {
    sp_posicoes = {
      memoria       = var.lambda_memory_mb.posicoes
      timeout       = var.lambda_timeout_segundos.posicoes
      precisa_token = true
      agenda        = var.agenda_posicoes
    }
    sp_cadastro = {
      memoria       = var.lambda_memory_mb.cadastro
      timeout       = var.lambda_timeout_segundos.cadastro_sp_rio
      precisa_token = true
      agenda        = var.agenda_cadastro
    }
    rio_posicoes = {
      memoria       = var.lambda_memory_mb.posicoes
      timeout       = var.lambda_timeout_segundos.posicoes
      precisa_token = false
      agenda        = var.agenda_posicoes
    }
    rio_cadastro = {
      memoria       = var.lambda_memory_mb.cadastro
      timeout       = var.lambda_timeout_segundos.cadastro_sp_rio
      precisa_token = false
      agenda        = var.agenda_cadastro
    }
    fortaleza_cadastro = {
      memoria       = var.lambda_memory_mb.cadastro
      timeout       = var.lambda_timeout_segundos.cadastro_fortaleza
      precisa_token = false
      agenda        = var.agenda_cadastro
    }
  }
}

resource "aws_cloudwatch_log_group" "funcoes" {
  for_each = local.funcoes

  name              = "/aws/lambda/${var.project_name}-${replace(each.key, "_", "-")}"
  retention_in_days = 30 # ver "Governanca de custo" na proposta inicial
}

resource "aws_lambda_function" "funcoes" {
  for_each = local.funcoes

  function_name = "${var.project_name}-${replace(each.key, "_", "-")}"
  role          = aws_iam_role.lambda_execucao.arn
  memory_size   = each.value.memoria
  timeout       = each.value.timeout

  # Imagem de container em vez de zip+layer -- as 7 funcoes do projeto
  # compartilham a MESMA imagem (infra/docker/Dockerfile). A imagem precisa
  # existir no ECR com essa tag antes do apply; ver "deploy em 2 fases" no
  # README.
  package_type = "Image"
  image_uri    = "${aws_ecr_repository.lambda.repository_url}:${var.image_tag}"

  # Mesmo handler nas 5: o que muda e a variavel FONTE abaixo.
  image_config {
    command = ["lambdas.ingestao.handler.lambda_handler"]
  }

  environment {
    variables = merge(
      {
        BUCKET_NAME = aws_s3_bucket.dados.bucket
        FONTE       = each.key
      },
      each.value.precisa_token ? { SPTRANS_TOKEN_PARAM = aws_ssm_parameter.sptrans_token.name } : {}
    )
  }

  depends_on = [aws_cloudwatch_log_group.funcoes]
}
