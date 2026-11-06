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
  description = <<-TEXTO
    Cron de SP e Rio (posicao). Formato AWS:
    cron(minuto hora dia-do-mes mes dia-da-semana ano).

    Padrao: a cada minuto, das 8h as 16h59, de segunda a sexta.

    A JANELA e horario comercial, por decisao de quem usa o dado -- nao por
    operacao do transporte. Onibus circulam todo dia e das 5h as 23h; a
    janela menor e uma escolha de custo e de foco no horario em que o time
    de marketing trabalha. "8-16" no cron cobre das 8h00 as 16h59, ou seja,
    termina AS 17h.

    Consequencia a ter em conta: pico da manha (6h-8h) e da tarde (17h-19h)
    ficam de fora. Se a analise precisar deles, a janela sobe pra "6-19".

    A CADENCIA: 1 minuto e o PISO do EventBridge Scheduler. Mas vale saber
    que o ganho real e menor do que parece -- medido, o GPS do veiculo so
    reporta a cada 45-90s, e a mediana da idade do ping na coleta e de 23s.
    Ir abaixo de 1 minuto exigiria um poller continuo em Fargate e traria
    sobretudo dado repetido. Ver docs/TEMPO-REAL.md.

    CUSTO: cada coleta das duas pracas grava 4,15 MB (bronze + silver,
    medido). Nesta janela sao ~11.700 coletas/mes (9h x 60min x ~21,7 dias
    uteis), ou ~47 GB/mes de armazenamento novo. Com a retencao de 30 dias
    em s3.tf isso estabiliza em ~US$ 1,10/mes em vez de crescer.

    A janela menor tambem resolveu um ponto de pressao: na janela anterior a
    Lambda consumia ~356 mil dos 400 mil GB-s gratuitos. Agora fica em
    ~129 mil, com folga real.
  TEXTO
  type        = string
  default     = "cron(* 8-16 ? * MON-FRI *)"
}

variable "agenda_cadastro" {
  description = <<-TEXTO
    Cron de linhas e pontos nas 3 pracas -- o pipeline LENTO.

    Padrao: 1x/dia as 7h, de segunda a sexta.

    Diario e nao de hora em hora porque e o que bate com a taxa real das
    origens: o GTFS do Rio e mensal, o da SPTrans muda algumas vezes ao dia,
    e o cadastro da ETUFOR muda em semanas. Coletar de hora em hora daria
    338 execucoes/mes (e 182 mil chamadas a API nao-oficial da ETUFOR) sem
    nenhum ganho de frescura.

    As 7h, e nao dentro da janela de 8h-17h, DE PROPOSITO: o cadastro precisa
    estar pronto ANTES das posicoes comecarem, senao a primeira hora do dia
    junta posicao nova com cadastro de ontem.

    Fim de semana fica de fora junto com as posicoes -- o cadastro muda em
    dias uteis, e a dim_data marca isso em tem_coleta_de_cadastro pra
    ninguem acusar lacuna onde nao ha.
  TEXTO
  type        = string
  default     = "cron(0 7 ? * MON-FRI *)"
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

variable "permitir_destruir_dados" {
  description = <<-TEXTO
    Se true, o "terraform destroy" consegue apagar o bucket S3 ainda com
    objetos dentro e o repositorio ECR ainda com imagem.

    Padrao FALSE de proposito: com ele desligado, um destroy acidental para
    no erro "bucket not empty" em vez de levar os dados junto. E uma rede de
    seguranca barata.

    O "make tf-destroy" passa -var para ligar na hora, depois de pedir
    confirmacao por escrito -- entao o ciclo destroy/apply de teste funciona
    sem deixar a protecao desligada no dia a dia.
  TEXTO
  type        = bool
  default     = false
}

variable "metabase_ligado" {
  description = <<-TEXTO
    Se a instancia do Metabase fica ligada. Padrao FALSE.

    O painel consulta dado que so e atualizado das 8h as 17h em dia util --
    fora disso nao ha novidade pra ver. Ligar sob demanda custa ~US$ 6,40/mes
    contra ~US$ 17 sempre ligado.

    Ligar e desligar NAO destroi nada: o disco EBS persiste, e com ele os
    dashboards, usuarios e conexoes.
  TEXTO
  type        = bool
  default     = false
}

variable "metabase_cidr_liberado" {
  description = <<-TEXTO
    Faixa de IP que pode acessar a porta 3000. Vazio (padrao) = NINGUEM.

    Metabase aberto pra internet com conta de administrador e pedido de
    invasao, e ele enxerga todo o data lake. O "make metabase-aws-ligar"
    descobre o seu IP publico do momento e libera so ele.
  TEXTO
  type        = string
  default     = ""
}
