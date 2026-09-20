resource "aws_iam_role" "scheduler_invocacao" {
  name = "${var.project_name}-${var.ambiente}-scheduler-invoca-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_invoca_lambda" {
  name = "invoca-lambdas-ingestao"
  role = aws_iam_role.scheduler_invocacao.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [for f in aws_lambda_function.funcoes : f.arn]
    }]
  })
}

# Cada agendamento tem sua propria politica de retry no nivel do Scheduler
# -- diferente do retry do tenacity dentro do codigo (lambdas/common/retry.py).
# O tenacity cobre falha transitoria numa chamada HTTP especifica; isso aqui
# cobre a invocacao INTEIRA da Lambda falhar (ex: erro nao tratado, timeout).
resource "aws_scheduler_schedule" "funcoes" {
  for_each = local.funcoes

  name       = "${var.project_name}-${replace(each.key, "_", "-")}"
  group_name = "default"
  state      = var.agendamento_habilitado ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = each.value.agenda

  target {
    arn      = aws_lambda_function.funcoes[each.key].arn
    role_arn = aws_iam_role.scheduler_invocacao.arn

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 300
    }
  }
}
