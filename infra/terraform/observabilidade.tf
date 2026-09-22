# Observabilidade: alarme e painel.
#
# Os log groups nao estao aqui -- ja nascem junto de cada funcao (lambda.tf e
# silver.tf), um por Lambda, com retencao de 30 dias. O que falta e alguem
# ser AVISADO, que e o buraco real: sem isto, uma funcao pode parar de rodar
# as 3h da manha e so se descobre quando alguem lembra de olhar.
#
# Tres classes de falha, porque exigem deteccoes diferentes:
#   1. a funcao quebrou            -> metrica Errors da Lambda
#   2. a funcao nem rodou          -> idade do dado (heartbeat.tf)
#   3. a funcao rodou, sem erro,
#      e o dado veio ruim          -> metrica extraida do proprio log JSON
# A terceira e a que mais escapa: nada falha, o alarme fica quieto e o dado
# apodrece. E o motivo de a ingestao logar total_valido/total_invalido.

locals {
  # Todas as funcoes que merecem alarme de erro -- as 5 de ingestao mais a
  # silver, que nao esta em local.funcoes por nao ser agendada.
  funcoes_com_alarme = merge(
    { for nome, _ in local.funcoes : nome => aws_lambda_function.funcoes[nome].function_name },
    { silver = aws_lambda_function.silver.function_name }
  )

  # Piso de volume por praca. Nao e "quantos onibus esperamos" -- e o ponto
  # abaixo do qual so pode ser fonte vazia ou resposta degradada. Medido:
  # SP entregou 8.047 e 5.049 veiculos em coletas reais; Rio, 1.962.
  # Frouxo de proposito: alarme de volume que grita por variacao normal
  # vira ruido e para de ser lido.
  piso_volume = {
    sp_posicoes  = 200
    rio_posicoes = 50
  }

  metricas_ns = "${var.project_name}/qualidade"
}

# ---------------------------------------------------------------------------
# Para onde o alarme vai
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alertas" {
  name = "${var.project_name}-${var.ambiente}-alertas"
}

# A inscricao so e criada se houver e-mail configurado -- sem isso os alarmes
# ainda funcionam e ficam visiveis no console, so nao empurram aviso.
# ATENCAO: a AWS manda um e-mail de confirmacao; enquanto ninguem clicar no
# link, a inscricao fica "pending confirmation" e NAO entrega nada.
resource "aws_sns_topic_subscription" "alertas_email" {
  count = var.email_alertas == "" ? 0 : 1

  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "email"
  endpoint  = var.email_alertas
}

# ---------------------------------------------------------------------------
# 1. A funcao quebrou
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "erro_execucao" {
  for_each = local.funcoes_com_alarme

  alarm_name        = "${var.project_name}-${replace(each.key, "_", "-")}-erro"
  alarm_description = "A funcao ${each.value} falhou. Ver o log group /aws/lambda/${each.value}."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions  = { FunctionName = each.value }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  # Sem invocacao no periodo nao e erro -- as de posicao passam a maior parte
  # do tempo fora da janela, e "missing" ali e o estado normal.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alertas.arn]
  ok_actions    = [aws_sns_topic.alertas.arn]
}

# ---------------------------------------------------------------------------
# 2. A funcao nem rodou  -> ver heartbeat.tf
#
# Ficou em arquivo separado porque a deteccao exigiu uma funcao propria. A
# tentativa obvia -- alarme sobre a metrica Invocations da Lambda -- foi
# implementada, testada contra a conta real e DESCARTADA: Invocations e
# esparsa, o CloudWatch procura datapoint para tras ate achar, e o alarme
# ficou OK com a funcao 26h parada. O historico dessa tentativa esta no
# comentario de lambdas/heartbeat/handler.py.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 3. Rodou, nao deu erro, e o dado veio ruim
# ---------------------------------------------------------------------------

# Os 6 filtros escrevem na MESMA metrica, sem dimensao. E uma troca
# consciente: cada metrica customizada custa por mes, e uma metrica por
# funcao seria 6x o custo pra responder "qual?" -- pergunta que o log
# responde de graca. O alarme aqui serve pra dizer "va olhar", nao pra
# diagnosticar.
resource "aws_cloudwatch_log_metric_filter" "registros_invalidos" {
  for_each = merge(
    { for nome, _ in local.funcoes : nome => aws_cloudwatch_log_group.funcoes[nome].name },
    { silver = aws_cloudwatch_log_group.silver.name }
  )

  name           = "${var.project_name}-${replace(each.key, "_", "-")}-invalidos"
  log_group_name = each.value

  # Casa com o warning que validar_lote() emite quando descarta registro.
  # O campo total_invalido vem achatado no JSON pelo Powertools (extra=...).
  pattern = "{ $.level = \"WARNING\" && $.total_invalido > 0 }"

  metric_transformation {
    name          = "registros_invalidos"
    namespace     = local.metricas_ns
    value         = "$.total_invalido"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "qualidade_registros_invalidos" {
  alarm_name        = "${var.project_name}-registros-invalidos"
  alarm_description = "Alguma fonte comecou a devolver registro que nao passa na validacao de schema. Provavel mudanca de contrato na origem. Ver qual no log das funcoes."

  namespace   = local.metricas_ns
  metric_name = "registros_invalidos"

  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alertas.arn]
  ok_actions    = [aws_sns_topic.alertas.arn]
}

# Volume: so pras funcoes de posicao. O cadastro tem volume estavel por
# natureza (linha e ponto mudam em semanas); posicao e o que despenca quando
# a origem devolve lista vazia -- e a coleta grava o vazio sem reclamar,
# porque zero registro valido nao e erro de execucao.
resource "aws_cloudwatch_log_metric_filter" "volume_coletado" {
  for_each = local.piso_volume

  name           = "${var.project_name}-${replace(each.key, "_", "-")}-volume"
  log_group_name = aws_cloudwatch_log_group.funcoes[each.key].name

  # Casa so com a linha INFO de conclusao, que carrega entidade e totais.
  pattern = "{ $.entidade = \"posicoes\" && $.total_valido = * }"

  metric_transformation {
    name      = "volume_${each.key}"
    namespace = local.metricas_ns
    value     = "$.total_valido"
  }
}

resource "aws_cloudwatch_metric_alarm" "volume_abaixo_do_piso" {
  for_each = local.piso_volume

  alarm_name        = "${var.project_name}-${replace(each.key, "_", "-")}-volume-baixo"
  alarm_description = "A coleta de ${each.key} terminou com menos de ${each.value} veiculos validos. Execucao bem-sucedida com dado vazio -- suspeitar da origem, nao do codigo."

  namespace   = local.metricas_ns
  metric_name = "volume_${each.key}"

  # Minimum, nao Average: uma unica coleta vazia no meio de uma janela cheia
  # some na media e e exatamente o que se quer pegar.
  statistic           = "Minimum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = each.value
  comparison_operator = "LessThanThreshold"

  # Fora da janela nao ha coleta -- ausencia aqui nao e dado ruim.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alertas.arn]
  ok_actions    = [aws_sns_topic.alertas.arn]
}

# ---------------------------------------------------------------------------
# Painel
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "principal" {
  dashboard_name = "${var.project_name}-${var.ambiente}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 2
        properties = {
          markdown = join("", [
            "# Ingestao de onibus -- ${var.ambiente}\n",
            "Bronze (NDJSON, como veio) -> evento do S3 -> silver (Parquet, schema canonico). ",
            "Alarme chega em **${var.email_alertas == "" ? "nenhum e-mail configurado" : var.email_alertas}**. ",
            "Para o estado consolidado num terminal: `make status`."
          ])
        }
      },
      {
        type = "metric", x = 0, y = 2, width = 12, height = 6
        properties = {
          title  = "Execucoes por funcao"
          view   = "timeSeries"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            for nome, funcao in local.funcoes_com_alarme :
            ["AWS/Lambda", "Invocations", "FunctionName", funcao, { label = nome }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 2, width = 12, height = 6
        properties = {
          title  = "Erros por funcao"
          view   = "timeSeries"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          yAxis  = { left = { min = 0 } }
          metrics = [
            for nome, funcao in local.funcoes_com_alarme :
            ["AWS/Lambda", "Errors", "FunctionName", funcao, { label = nome }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 12, height = 6
        properties = {
          title  = "Duracao (p95) -- proximidade do timeout"
          view   = "timeSeries"
          region = var.aws_region
          stat   = "p95"
          period = 300
          yAxis  = { left = { label = "ms", min = 0 } }
          metrics = [
            for nome, funcao in local.funcoes_com_alarme :
            ["AWS/Lambda", "Duration", "FunctionName", funcao, { label = nome }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 8, width = 12, height = 6
        properties = {
          title  = "Veiculos coletados por execucao"
          view   = "timeSeries"
          region = var.aws_region
          stat   = "Minimum"
          period = 300
          yAxis  = { left = { min = 0 } }
          metrics = [
            for nome, _ in local.piso_volume :
            [local.metricas_ns, "volume_${nome}", { label = nome }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 14, width = 12, height = 6
        properties = {
          title   = "Registros descartados na validacao"
          view    = "timeSeries"
          region  = var.aws_region
          stat    = "Sum"
          period  = 3600
          yAxis   = { left = { min = 0 } }
          metrics = [[local.metricas_ns, "registros_invalidos", { label = "todas as fontes" }]]
        }
      },
      {
        # Numero mais direto do painel: ha quantas horas cada pipeline nao
        # entrega. Em barra e nao em serie temporal porque a pergunta aqui e
        # "como esta AGORA", nao "como evoluiu".
        type = "metric", x = 0, y = 20, width = 24, height = 6
        properties = {
          title  = "Horas desde o ultimo dado (o pipeline esta entregando?)"
          view   = "bar"
          region = var.aws_region
          stat   = "Maximum"
          period = 3600
          yAxis  = { left = { label = "horas", min = 0 } }
          metrics = [
            for nome, _ in local.tolerancia_idade_h :
            [local.metricas_ns, "idade_horas_${nome}", { label = nome }]
          ]
          annotations = {
            horizontal = [
              { label = "tolerancia do cadastro (26h)", value = 26, fill = "above" }
            ]
          }
        }
      },
      {
        type = "log", x = 12, y = 14, width = 12, height = 6
        properties = {
          title  = "Ultimos avisos e erros"
          region = var.aws_region
          query = join("", [
            "SOURCE '${aws_cloudwatch_log_group.silver.name}'",
            join("", [for nome, _ in local.funcoes : " | SOURCE '${aws_cloudwatch_log_group.funcoes[nome].name}'"]),
            " | fields @timestamp, service, level, message, total_invalido",
            " | filter level in ['WARNING', 'ERROR']",
            " | sort @timestamp desc | limit 20"
          ])
        }
      }
    ]
  })
}
