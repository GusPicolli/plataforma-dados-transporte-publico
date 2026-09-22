# Heartbeat: detecta "o pipeline parou de entregar".
#
# Por que uma funcao inteira so pra isso, em vez de um alarme sobre a
# metrica Invocations da Lambda: Invocations e ESPARSA -- so ganha ponto
# quando a funcao roda. Alarme sobre ausencia de ponto nao funciona, porque
# o CloudWatch procura datapoint para tras ate achar algum. Foi implementado,
# testado contra a conta real, e o alarme ficou OK com a funcao 26h parada.
# FILL(m,0) tambem nao salva: sem ponto na janela, nao ha lacuna a preencher.
#
# Esta funcao roda de hora em hora e SEMPRE publica um ponto por pipeline.
# Metrica densa, alarme confiavel. E mede diretamente o que importa -- ha
# quanto tempo nao chega dado -- em vez de um proxy disso.

locals {
  # Horas sem dado novo ainda toleradas, por pipeline. MESMOS valores de
  # PIPELINES em scripts/status_pipeline.py: o criterio do alarme e o do
  # terminal precisam ser o mesmo, senao um diz OK e o outro diz problema.
  #
  # Posicao tem tolerancia de 8 dias porque roda em JANELA semanal -- entre
  # uma janela e outra o dado fica legitimamente velho. Cadastro e diario,
  # entao 26h = 24h + folga pra atraso.
  tolerancia_idade_h = {
    sp_posicoes        = 192
    rio_posicoes       = 192
    sp_cadastro        = 26
    rio_cadastro       = 26
    fortaleza_cadastro = 26
  }
}

resource "aws_cloudwatch_log_group" "heartbeat" {
  name              = "/aws/lambda/${var.project_name}-heartbeat"
  retention_in_days = 30
}

resource "aws_iam_role" "heartbeat" {
  name = "${var.project_name}-${var.ambiente}-heartbeat"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "heartbeat_logs_basicos" {
  role       = aws_iam_role.heartbeat.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# So LISTA o bucket e publica metrica. Nao le nem escreve objeto -- pra
# saber a idade do dado basta o LastModified, que vem no list.
resource "aws_iam_role_policy" "heartbeat" {
  name = "lista-bronze-publica-metrica"
  role = aws_iam_role.heartbeat.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.dados.arn
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = local.metricas_ns }
        }
      }
    ]
  })
}

resource "aws_lambda_function" "heartbeat" {
  function_name = "${var.project_name}-heartbeat"
  role          = aws_iam_role.heartbeat.arn

  memory_size = 256
  timeout     = 120

  package_type = "Image"
  image_uri    = "${aws_ecr_repository.lambda.repository_url}:${var.image_tag}"

  image_config {
    command = ["lambdas.heartbeat.handler.lambda_handler"]
  }

  environment {
    variables = {
      BUCKET_NAME             = aws_s3_bucket.dados.id
      METRICAS_NAMESPACE      = local.metricas_ns
      POWERTOOLS_SERVICE_NAME = "heartbeat"
    }
  }

  depends_on = [aws_cloudwatch_log_group.heartbeat]
}

resource "aws_scheduler_schedule" "heartbeat" {
  name = "${var.project_name}-heartbeat"

  flexible_time_window {
    mode = "OFF"
  }

  # De hora em hora. Nao precisa ser mais fino: a tolerancia mais apertada e
  # de 26h, entao medir a cada hora ja da resolucao de sobra -- e cada
  # execucao a mais e custo sem ganho de deteccao.
  schedule_expression          = "rate(1 hour)"
  schedule_expression_timezone = var.timezone_agendamento

  # Segue o mesmo interruptor dos pipelines: com a coleta desligada de
  # proposito, o dado envelhece porque assim foi decidido, e alarmar sobre
  # isso seria ruido garantido.
  state = var.agendamento_habilitado ? "ENABLED" : "DISABLED"

  target {
    arn      = aws_lambda_function.heartbeat.arn
    role_arn = aws_iam_role.scheduler_invocacao.arn
  }
}

resource "aws_iam_role_policy" "scheduler_invoca_heartbeat" {
  name = "invoca-heartbeat"
  role = aws_iam_role.scheduler_invocacao.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.heartbeat.arn
    }]
  })
}

resource "aws_cloudwatch_metric_alarm" "dado_velho" {
  for_each = local.tolerancia_idade_h

  alarm_name        = "${var.project_name}-${replace(each.key, "_", "-")}-dado-velho"
  alarm_description = "O pipeline ${each.key} nao entrega dado novo ha mais de ${each.value}h. Pode ser agendamento desligado, cron/fuso errado, ou a origem fora do ar."

  namespace   = local.metricas_ns
  metric_name = "idade_horas_${each.key}"

  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = each.value
  comparison_operator = "GreaterThanThreshold"

  # Se o proprio heartbeat parar de publicar, isso tambem e problema --
  # e justamente o vigia tendo morrido em silencio.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alertas.arn]
  ok_actions    = [aws_sns_topic.alertas.arn]
}

resource "aws_cloudwatch_metric_alarm" "heartbeat_erro" {
  alarm_name        = "${var.project_name}-heartbeat-erro"
  alarm_description = "O proprio heartbeat falhou. Enquanto isso durar, os alarmes de dado velho nao sao confiaveis."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions  = { FunctionName = aws_lambda_function.heartbeat.function_name }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alertas.arn]
  ok_actions    = [aws_sns_topic.alertas.arn]
}
