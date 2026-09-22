variable "aws_region" {
  description = "Regiao AWS onde tudo e criado."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixo usado no nome de todo recurso (bucket, funcoes, parametro)."
  type        = string
  default     = "onibus-tempo-real"
}

variable "ambiente" {
  description = "dev | prod -- so afeta tags e o sufixo do bucket."
  type        = string
  default     = "dev"
}

variable "sptrans_token" {
  description = "Token da API Olho Vivo. Vai pro SSM Parameter Store (SecureString), nunca pro codigo. Cadastro gratuito em https://www.sptrans.com.br/desenvolvedores/"
  type        = string
  sensitive   = true
}

variable "lambda_memory_mb" {
  description = "Memoria por tipo de funcao. Posicao e leve (1 request); cadastro processa GTFS/varre linhas, precisa de mais."
  type = object({
    posicoes = number
    cadastro = number
  })
  default = {
    posicoes = 256
    cadastro = 512
  }
}

variable "lambda_timeout_segundos" {
  description = "Timeout por tipo de funcao. Fortaleza itera ~540 linhas a ~0.4s cada (~3-4min medidos) -- timeout com folga real, nao um numero redondo chutado."
  type = object({
    posicoes           = number
    cadastro_sp_rio    = number
    cadastro_fortaleza = number
  })
  default = {
    posicoes           = 30
    cadastro_sp_rio    = 60
    cadastro_fortaleza = 420
  }
}

variable "agenda_posicoes" {
  description = "Cron pra SP/Rio (posicao). Formato AWS: cron(minuto hora dia-do-mes mes dia-da-semana ano). Padrao: a cada 1 minuto, durante 1 hora, so aos sabados -- janela curta pra exercitar a 'simulacao de tempo real' sem deixar rodando a semana toda. 1 minuto e o PISO do EventBridge Scheduler: pra ir abaixo disso (ex: 5s como no exercicio local) seria preciso um poller continuo em Fargate, que custa ordens de grandeza a mais."
  type        = string
  default     = "cron(* 14 ? * SAT *)"
}

variable "agenda_cadastro" {
  description = "Cron pra linhas/pontos (as 3 pracas) -- o pipeline LENTO. Padrao: 1x/dia as 7h, seg-sab. Diario e nao de hora em hora porque e o que bate com a taxa real das origens: GTFS do Rio e mensal, o da SPTrans muda algumas vezes ao dia, e o cadastro da ETUFOR muda em semanas. Coletar de hora em hora daria 338 execucoes/mes (e 182 mil chamadas a API nao-oficial da ETUFOR) sem nenhum ganho de frescura."
  type        = string
  default     = "cron(0 7 ? * MON-SAT *)"
}

variable "timezone_agendamento" {
  description = "Fuso usado pelos crons. Sem isso o EventBridge assume UTC -- foi o que fez a janela documentada como '5h-22h' rodar de fato das 2h as 19h no horario de Brasilia."
  type        = string
  default     = "America/Sao_Paulo"
}

variable "agendamento_habilitado" {
  description = "Se false, os 5 schedules sobem DESLIGADOS -- criados, mas sem disparar sozinhos. Default false de proposito: ligar automaticamente a coleta recorrente (e o custo/tráfego que vem junto) deve ser uma escolha explicita, nao um efeito colateral do apply."
  type        = bool
  default     = false
}

variable "image_tag" {
  description = "Tag da imagem no ECR que as 5 funcoes devem rodar. Precisa ja existir no repositorio antes do apply -- ver 'deploy em 2 fases' no README."
  type        = string
  default     = "latest"
}

variable "email_alertas" {
  description = "E-mail que recebe os alarmes. Vazio (padrao) cria os alarmes mesmo assim -- eles ficam visiveis no console e no painel, so nao empurram aviso. Ao preencher, a AWS manda um e-mail de confirmacao: enquanto ninguem clicar no link, a inscricao fica 'pending confirmation' e nao entrega nada."
  type        = string
  default     = ""
}
