# Orquestracao: TODAS as fontes passam pelo Step Functions.
#
# Um unico fluxo generico, dois agendamentos. O que muda entre eles e a
# LISTA DE FONTES que o agendamento passa como entrada -- nao ha fluxo
# separado por cadencia nem estado condicional dentro dele.
#
# O QUE ISTO RESOLVE:
#
#   1. Sinal de conclusao da carga. "A coleta das 14h32 terminou?" passou a
#      ter resposta: o historico de execucao do fluxo.
#   2. Falha parcial vira ESTADO, nao excecao. Qualquer fonte que falhe e
#      marcada como degradada e as demais seguem. Ja aconteceu de verdade:
#      o GTFS do Rio respondeu 403 por semanas, e o fluxo seguiu carregando
#      SP e Fortaleza ate a URL ser corrigida.
#   3. A silver e chamada EXPLICITAMENTE. O gatilho por evento do S3 parou
#      de funcionar (configuracao, permissao e funcao verificadas sem achar
#      causa) e foi removido. Chamada explicita tambem da o sinal de
#      conclusao que o evento nunca deu.
#   4. Dois agendamentos no lugar de cinco.
#
# CUSTO: ~9 transicoes por execucao. As posicoes rodam ~11.700 vezes/mes,
# o cadastro ~22. Sao ~105 mil transicoes/mes; 4.000 sao gratuitas, e o
# resto custa US$ 0,000025 cada -- cerca de US$ 2,54/mes. E a escolha
# deliberada de pagar por visibilidade: o tipo EXPRESS custaria ~US$ 0,14,
# mas sem historico visual de execucao, que e justamente o controle que se
# quer aqui.

locals {
  # Quais funcoes cada agendamento manda coletar. O fluxo nao sabe nada
  # sobre praca ou cadencia -- so recebe a lista e executa.
  grupos_de_coleta = {
    posicoes = {
      agenda  = var.agenda_posicoes
      funcoes = [for n, _ in local.funcoes : n if endswith(n, "_posicoes")]
    }
    cadastro = {
      agenda  = var.agenda_cadastro
      funcoes = [for n, _ in local.funcoes : n if endswith(n, "_cadastro")]
    }
  }
}

resource "aws_cloudwatch_log_group" "orquestracao" {
  name              = "/aws/vendedlogs/states/${var.project_name}-coleta"
  retention_in_days = 30
}

resource "aws_iam_role" "orquestracao" {
  name = "${var.project_name}-${var.ambiente}-orquestracao"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "orquestracao" {
  name = "invoca-ingestao-e-silver"
  role = aws_iam_role.orquestracao.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = concat(
          [for f in aws_lambda_function.funcoes : f.arn],
          [aws_lambda_function.silver.arn]
        )
      },
      {
        # Exigido pelo Step Functions pra gravar o historico de execucao.
        # Sem CreateLogDelivery a criacao do state machine falha.
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_sfn_state_machine" "coleta" {
  name     = "${var.project_name}-coleta"
  role_arn = aws_iam_role.orquestracao.arn
  type     = "STANDARD"

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.orquestracao.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  # A definicao em JSON proprio, e nao jsonencode() inline: ASL e JSON, e
  # mante-lo como JSON deixa o fluxo legivel, colavel no Workflow Studio do
  # console e validavel por qualquer parser.
  definition = templatefile("${path.module}/fluxos/coleta.asl.json", {
    arn_silver = aws_lambda_function.silver.arn
    bucket     = aws_s3_bucket.dados.bucket
  })
}

# Um agendamento por cadencia. A diferenca entre eles e so o "input".
resource "aws_scheduler_schedule" "coleta" {
  for_each = local.grupos_de_coleta

  name = "${var.project_name}-coleta-${each.key}"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = each.value.agenda
  schedule_expression_timezone = var.timezone_agendamento
  state                        = var.agendamento_habilitado ? "ENABLED" : "DISABLED"

  target {
    arn      = aws_sfn_state_machine.coleta.arn
    role_arn = aws_iam_role.scheduler_inicia_fluxo.arn

    # A lista de fontes vai aqui, nao no fluxo. Fonte nova entra em
    # local.funcoes e aparece sozinha na lista certa.
    input = jsonencode({
      fontes = [
        for nome in each.value.funcoes : {
          funcao = aws_lambda_function.funcoes[nome].function_name
        }
      ]
    })
  }
}

resource "aws_iam_role" "scheduler_inicia_fluxo" {
  name = "${var.project_name}-${var.ambiente}-scheduler-sfn"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_inicia_fluxo" {
  name = "inicia-state-machine"
  role = aws_iam_role.scheduler_inicia_fluxo.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.coleta.arn
    }]
  })
}

output "state_machine_coleta" {
  description = "Fluxo unico de coleta no Step Functions."
  value       = aws_sfn_state_machine.coleta.arn
}
