locals {
  # module.function_name => (memoria, timeout, precisa_token, entidade)
  funcoes = {
    sp_posicoes = {
      handler       = "lambdas.sp_posicoes.handler.lambda_handler"
      memoria       = var.lambda_memory_mb.posicoes
      timeout       = var.lambda_timeout_segundos.posicoes
      precisa_token = true
      agenda        = var.agenda_posicoes
    }
    sp_cadastro = {
      handler       = "lambdas.sp_cadastro.handler.lambda_handler"
      memoria       = var.lambda_memory_mb.cadastro
      timeout       = var.lambda_timeout_segundos.cadastro_sp_rio
      precisa_token = true
      agenda        = var.agenda_cadastro
    }
    rio_posicoes = {
      handler       = "lambdas.rio_posicoes.handler.lambda_handler"
      memoria       = var.lambda_memory_mb.posicoes
      timeout       = var.lambda_timeout_segundos.posicoes
      precisa_token = false
      agenda        = var.agenda_posicoes
    }
    rio_cadastro = {
      handler       = "lambdas.rio_cadastro.handler.lambda_handler"
      memoria       = var.lambda_memory_mb.cadastro
      timeout       = var.lambda_timeout_segundos.cadastro_sp_rio
      precisa_token = false
      agenda        = var.agenda_cadastro
    }
    fortaleza_cadastro = {
      handler       = "lambdas.fortaleza_cadastro.handler.lambda_handler"
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
  retention_in_days = 30 # ver "Governanca de custo" na Proposta_inicial
}

resource "aws_lambda_function" "funcoes" {
  for_each = local.funcoes

  function_name = "${var.project_name}-${replace(each.key, "_", "-")}"
  role          = aws_iam_role.lambda_execucao.arn
  memory_size   = each.value.memoria
  timeout       = each.value.timeout

  # Imagem de container em vez de zip+layer -- as 5 funcoes compartilham a
  # MESMA imagem (infra/docker/Dockerfile), so o "command" muda entre elas.
  # A imagem precisa existir no ECR com essa tag antes do apply; ver
  # "deploy em 2 fases" no README.
  package_type = "Image"
  image_uri    = "${aws_ecr_repository.lambda.repository_url}:${var.image_tag}"

  image_config {
    command = [each.value.handler]
  }

  environment {
    variables = merge(
      { BUCKET_NAME = aws_s3_bucket.dados.bucket },
      each.value.precisa_token ? { SPTRANS_TOKEN_PARAM = aws_ssm_parameter.sptrans_token.name } : {}
    )
  }

  depends_on = [aws_cloudwatch_log_group.funcoes]
}
