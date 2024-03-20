# get_datacom_onu_status
Este script coleta informacões dos ONUs por SSH de forma otimizada em OLTs Datacom com firmware >= 9.4.0.
Os comandos de coleta dos dados detalhados de cada ONU são executados no OLT apenas se houver alteração nos status dos ONUs (quantidade Up/Down) ou se o tempo desde a última coleta estiver expirado (default 1200 s)
Os produtos suportados podem ser verificados no site https://datacom.com.br/pt/produtos/gpon

Uso: ./get_datacom_onu_status.sh [-u usuário] [-p senha] [-h endereço IP] [-P porta SSH] [-t período máximo entre atualizações] [-s] [-m] [-d]

Opções:
  -u <usuário>     Nome do usuário para autenticação SSH (obrigatório)
  -p <senha>       Senha do usuário para autenticação SSH (obrigatório)
  -h <endereço IP> Endereço IP do OLT (obrigatório)
  -P <porta SSH>   Porta SSH do servidor remoto (opcional, padrão: 22)
  -t <período>     Período máximo entre atualizações dos dados das interfaces PON em segundos (opcional, padrão: 1200 s)
  -s               Mostra o cabeçalho relativo aos campos das informacões (opcional)
  -m               Mostra os dados no formato de tabela (opcional)
  -d               Habilita o modo debug (opcional)

Exemplo de uso:
  ./get_datacom_onu_status.sh -u usuario -p senha -h 172.31.1.10 -P 2222 -t 600 -s -m -d

Exemplo de uso (apenas parâmetros obrigatórios):
 ./get_datacom_onu_status.sh -u usuario -p senha -h 172.31.1.10

