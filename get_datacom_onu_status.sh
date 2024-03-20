#!/bin/bash

# Função para verificar se o sshpass está instalado
check_sshpass() {
    if ! command -v sshpass &> /dev/null; then
        echo ""
        echo "O sshpass não está instalado e o script depende desse programa. Deseja instala-lo agora? (sim/não) (yes/no)"
        echo ""
        read answer
        case "$answer" in
            [SsYy]|[Ss][Ii][Mm]|[Yy][Ee][Ss])
                echo "Tentando instalar via apt..."
                sudo apt update
                sudo apt install -y sshpass
                ;;
            [Nn]|[Nn][Aa][Oo]|[Nn][Oo])
                echo "Você optou por não instalar o sshpass."
                ;;
            *)
                echo "Entrada inválida. Por favor, responda 'sim' ou 'não'."
                ;;
        esac
    fi
}

# Chamada da função
check_sshpass

# Definindo valores padrão
PORT=22
MAX_REFRESH_PERIOD=1200
HEADER=0
TABLE=0
DEBUG=0


# Função para exibir a mensagem de uso
function usage() {
  echo ""
  echo "Este script coleta informacões dos ONUs por SSH de forma otimizada em OLTs Datacom com firmware >= 9.4.0."
  echo "Os comandos de coleta dos dados detalhados de cada ONU são executados no OLT apenas se houver alteração nos status dos ONUs (quantidade Up/Down) ou se o tempo desde a última coleta estiver expirado (default $MAX_REFRESH_PERIOD s)" 
  echo "Os produtos suportados podem ser verificados no site https://datacom.com.br/pt/produtos/gpon"
  echo ""
  echo "Uso: $0 [-u usuário] [-p senha] [-h endereço IP] [-P porta SSH] [-t período máximo entre atualizações] [-s] [-m] [-d]"
  echo ""
  echo "Opções:"
  echo "  -u <usuário>     Nome do usuário para autenticação SSH (obrigatório)"
  echo "  -p <senha>       Senha do usuário para autenticação SSH (obrigatório)"
  echo "  -h <endereço IP> Endereço IP do OLT (obrigatório)"
  echo "  -P <porta SSH>   Porta SSH do servidor remoto (opcional, padrão: $PORT)"
  echo "  -t <período>     Período máximo entre atualizações dos dados das interfaces PON em segundos (opcional, padrão: $MAX_REFRESH_PERIOD s)"
  echo "  -s               Mostra o cabeçalho relativo aos campos das informacões (opcional)"
  echo "  -m               Mostra os dados no formato de tabela (opcional)"
  echo "  -d               Habilita o modo debug (opcional)"
  echo ""
  echo "Exemplo de uso:"
  echo "  $0 -u usuario -p senha -h 172.31.1.10 -P 2222 -t 600 -s -m -d"
  echo ""
  echo "Exemplo de uso (apenas parâmetros obrigatórios):"
  echo " $0 -u usuario -p senha -h 172.31.1.10"
  echo ""
  exit 1
}

# Parse das flags
while getopts ":u:p:h:P:t:smd" opt; do
  case $opt in
    u) USER=$OPTARG ;;
    p) PASS=$OPTARG ;;
    h) IP=$OPTARG ;;
    P) PORT=$OPTARG ;;
    t) MAX_REFRESH_PERIOD=$OPTARG ;;
    s) HEADER=1 ;;
    m) TABLE=1 ;;
    d) DEBUG=1 ;;
    *) usage ;;
  esac
done

# Validação dos parâmetros obrigatórios
if [ -z "$USER" ] || [ -z "$PASS" ] || [ -z "$IP" ]; then
  echo ""
  echo "Erro: Os parâmetros -u, -p e -h são obrigatórios."
  echo ""
  usage
fi

# Validação da porta SSH
if ! [[ $PORT =~ ^[0-9]+$ ]]; then
  echo ""
  echo "Erro: A porta SSH (-P) deve ser um número inteiro."
  echo ""
  usage
fi

# Validação do período máximo entre atualizações
if ! [[ $MAX_REFRESH_PERIOD =~ ^[0-9]+$ ]]; then
  echo ""
  echo "Erro: O período máximo entre atualizações (-t) deve ser um número inteiro."
  echo ""
  usage
fi

# Exibir informações de debug
if [ $DEBUG -eq 1 ]; then
  echo "------- Parâmetros -------"
  echo "Usuário: $USER"
  echo "Senha: $PASS"
  echo "Endereço IP: $IP"
  echo "Porta SSH: $PORT"
  echo "Período máximo entre atualizações: $MAX_REFRESH_PERIOD"
  echo "Modo debug: ativado"
  echo "-----------------------"
fi

# Nome do diretório para armazenar os arquivos
data_dir="olt_data_${IP//./_}"

# Nome do arquivo para armazenar os status dos ONUs
data_file_old="$data_dir/onu_interface_count_old.txt"
data_file_current="$data_dir/onu_interface_count_current.txt"
data_file_alarms="$data_dir/alarms.txt"

# Função para checar a conectividade e autenticação com o OLT
check_ssh_connectivity() {

    # Verifica se há conectividade IP
    if ping -c 1 $IP >/dev/null; then
        echo "$(date "+%Y-%m-%d %T") - A conectividade IP está OK."
        # Tenta autenticar via SSH
        if sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$PORT" "$USER"@"$IP" true >/dev/null 2>&1; then
            echo "$(date "+%Y-%m-%d %T") - SSH autenticado com sucesso."
        else
            echo "Falha na autenticação SSH. Verifique usuario e senha."
            exit 1  # Interrompe o script se a autenticação SSH falhar
        fi
    else
        echo "Falha na conectividade IP."
        exit 1  # Interrompe o script se a conectividade IP falhar
    fi
}

# Função para verificar a versão de Firmware
check_firmware_version() {
    # Comando SSH para obter o firmware do equipamento
    firmware=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$PORT" "$USER"@"$IP" "show firmware | include Active" 2>/dev/null | awk -F '-' '{print $1}')
    # Verifica se o firmware é menor que 9.4.0
    if [[ "$(echo $firmware)" < "9.4.0" ]]; then
        echo "$(date "+%Y-%m-%d %T") - Erro! O firmware do equipamento deve ser maior ou igual a 9.4.0. A versão instalada é $firmware".
        exit 1  # Interrompe o script se o firmware for menor que 9.4.0
    else
       echo "$(date "+%Y-%m-%d %T") - O firmware do equipamento é $firmware, que é compatível com o script."
    fi
}

# Função para obter dados de quantidade de ONUs Up e Down por porta PON
get_onu_interface_count() {
    # Conecta ao OLT via SSH e obtém os dados de quantidade de ONUs Up e Down por porta PON
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$PORT" "$USER"@"$IP" "show onu-interface-count" 2>/dev/null | grep "pon-" | awk -v timestamp=$(date +%s) '{print $2 ";" $3 ";" $4 ";" $5 ";" $6 ";" timestamp}' > "$1"
}

# Função para obter dados de alarmes do OLT
get_alarms() {
    # Conecta ao OLT via SSH e obtém a lista de alarmes presentes no sistema
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$PORT" "$USER"@"$IP" "show alarm | begin ---- | exclude --- | nomore" 2>/dev/null | awk '{print $5 ";" $7}' > "$1"
}

# Função para obter a consulta completa de uma porta PON
get_complete_port_data() {
    # Conecta ao OLT via SSH e obtém a consulta completa da porta PON especificada
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$PORT" "$USER"@"$IP" "show interface \\$1 onu | tab | csv | exclude ,,,,,,,,,, | exclude ID,VERSION" 2>/dev/null | sed '/^$/d' > "$2"
}

# Função para calcular o REGISTER_TIME e o LAST_DEREGISTER_TIME
calculate_date() {
    # Extrair informações de dias, horas e minutos do "Last Seen Online" ou "Uptime"
    if [[ $1 == *"days"* ]]; then
        days=$(echo "$1" | grep -oE '[0-9]+ days' | awk '{print $1}')
     else
        days=0
    fi
    if [[ $1 == *":"* ]]; then
        hours=$(echo "$1" | grep -oE '[0-9]+:[0-9]+' | awk -F: '{print $1}')
        hours=$(expr "$hours" + 0)
     else
        hours=0
    fi
    if [[ $1 == *"min"* ]]; then
        minutes=$(echo "$1" | grep -oE '[0-9]+ min' | awk '{print $1}')
        minutes=$(expr "$minutes" + 0)
     else
        minutes=$(echo "$1" | grep -o ':[0-9]\{2\}' | sed 's#:##g')
        minutes=$(expr "$minutes" + 0)
    fi

    # Converter dias, horas e minutos para minutos totais
    total_minutes=$((days * 24 * 60 + hours * 60 + minutes))

    # Calcular a data baseado no "Last Updated" menos o "Last Seen Online" ou "Uptime"
    DATE=$(date -d "$2 - $total_minutes minutes" +"%Y-%m-%d %H:%M:%S")
}

# Função para descobrir a razão do ONU Down
check_offline_reason() {
  onu_id_alarm=$(echo $1 | sed 's#:#/#g')
  dgi_alarm=$(cat "$data_file_alarms" | grep "$onu_id_alarm" | grep "DGi")
  losi_alarm=$(cat "$data_file_alarms" | grep "$onu_id_alarm" | grep "LOSi")
  if [[ "$losi_alarm" =~ "LOSi" ]] && [[ "$dgi_alarm" =~ "DGi" ]]; then
      LAST_DEREGISTER_REASON="Power Off";
  else
     if [[ "$losi_alarm" =~ "LOSi" ]]; then
         LAST_DEREGISTER_REASON="Onu Los"
         echo "$LAST_DEREGISTER_REASON"
     else LAST_DEREGISTER_REASON="N/A"
     fi
  fi
}

# Função para apresentar os dados armazenados dos ONUs
show_onu_data() {
   #Faz o parse dos dados contidos no arquivo .csv da interface PON e imprime na tela
   onu_count=$(cat "$1" | wc -l)
   j=1;
   if [ $DEBUG -eq 1 ]; then
      #Imprime o cabeçalho por interface PON caso o modo debug habilitado
      if [ $TABLE -eq 1 ]; then
         echo "ONU ID;Admin State;OMCC State;Phase State;Description;Last Register Time;Last Deregister Time;Last Deregister Reason;Alive Time;RX Power(ONU);TX Power(ONU);RX Power(OLT)" | awk 'BEGIN { FS=";" } { printf "%-16s %-12s %-12s %-12s %-26s %-20s %-20s %-25s %-15s %-15s %-15s %-15s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }';
       else
         echo "ONU ID;Admin State;OMCC State;Phase State;Description;Last Register Time;Last Deregister Time;Last Deregister Reason;Alive Time;RX Power(ONU);TX Power(ONU);RX Power(OLT)"
      fi
   fi
   while [ $j -le $onu_count ]; do
     if [[ $2 =~ "xgs" ]]; then
        #Leitura dos campos quando o OLT é XGSPON
        IFS=';' read -r ID VERSION OPTICAL_INFO RSSI_VALUE OPER_STATE PRIMARY_STATUS SERIAL_NUMBER_STATUS DHCP_STATUS_IPV4_CIDR DHCP_STATUS_DEFAULT_GATEWAY SOFTWARE_DOWNLOAD_STATE SOFTWARE_DOWNLOAD_PROGRESS VENDOR_ID EQ_ID VERSION_CODE ACTIVE_FW STANDBY_FW VALID_ACTIVE_FW COMM_ACTIVE_FW VALID_STANDBY_FW COMM_STANDBY_FW RX_OPTICAL_PW TX_OPTICAL_PW SUM_FIXED SUM_FIXED_ASSURED UPTIME LAST_UPDATED LAST_SEEN_ONLINE RG_PROFILE DISTANCE SERIAL_NUMBER NAME ETHERNET LINK NEGOTIATED_SPEED NEGOTIATED_DUPLEX GEM GEM_PORT_ID OPERATIONAL_STATUS_ETH ALLOC_ID TCONT ENCRYPTION_STATUS <<< $(sed -n "${j}p" "$1" | awk -F ';' '{print $1 ";" $2 ";" $3 ";" $4 ";" $5 ";" $6 ";" $7 ";" $8 ";" $9 ";" $10 ";" $11 ";" $12 ";" $13 ";" $14 ";" $15 ";" $16 ";" $17 ";" $18 ";" $19 ";" $20 ";" $21 ";" $22 ";" $23 ";" $24 ";" $25 ";" $26 ";" $27 ";" $28 ";" $29 ";" $30 ";" $31 ";" $32 ";" $33 ";" $34 ";" $35 ";" $36 ";" $37 ";" $38 ";" $39 ";" $40 ";" $41}')
      else
        #Leitura dos campos quando o OLT é GPON
        IFS=';' read -r ID VERSION OPTICAL_INFO RSSI RSSI_VALUE OPER_STATE PRIMARY_STATUS SERIAL_NUMBER_STATUS DHCP_STATUS_IPV4_CIDR DHCP_STATUS_DEFAULT_GATEWAY SOFTWARE_DOWNLOAD_STATE SOFTWARE_DOWNLOAD_PROGRESS VENDOR_ID EQ_ID VERSION_CODE ACTIVE_FW STANDBY_FW VALID_ACTIVE_FW COMM_ACTIVE_FW VALID_STANDBY_FW COMM_STANDBY_FW RX_OPTICAL_PW TX_OPTICAL_PW SUM_FIXED SUM_FIXED_ASSURED UPTIME LAST_UPDATED LAST_SEEN_ONLINE RG_PROFILE DISTANCE SERIAL_NUMBER NAME ETHERNET LINK NEGOTIATED_SPEED NEGOTIATED_DUPLEX GEM GEM_PORT_ID OPERATIONAL_STATUS_ETH ALLOC_ID TCONT ENCRYPTION_STATUS <<< $(sed -n "${j}p" "$1" | awk -F ';' '{print $1 ";" $2 ";" $3 ";" $4 ";" $5 ";" $6 ";" $7 ";" $8 ";" $9 ";" $10 ";" $11 ";" $12 ";" $13 ";" $14 ";" $15 ";" $16 ";" $17 ";" $18 ";" $19 ";" $20 ";" $21 ";" $22 ";" $23 ";" $24 ";" $25 ";" $26 ";" $27 ";" $28 ";" $29 ";" $30 ";" $31 ";" $32 ";" $33 ";" $34 ";" $35 ";" $36 ";" $37 ";" $38 ";" $39 ";" $40 ";" $41 ";" $42}')
     fi
     ONU_ID=$ID
     if [[ ! $ONU_ID =~ "entries" ]]; then
        if [[ $PRIMARY_STATUS =~ "Unknown" ]]; then ADMIN_STATE="disable"; else ADMIN_STATE="enable"; fi
        if [[ $PRIMARY_STATUS =~ "Active" ]]; then OMCC_STATE="enable"; else OMCC_STATE="disable"; fi
        if [[ $OPER_STATE =~ "Up" ]]; then PHASE_STATE="working"; else PHASE_STATE="offline"; fi
        DESCRIPTION=$NAME
        if [[ $OPER_STATE =~ "Down" ]]; then LAST_REGISTER_TIME="N/A"; else calculate_date "$UPTIME" "$LAST_UPDATED"; LAST_REGISTER_TIME="$DATE"; fi
        if [[ $LAST_SEEN_ONLINE =~ "N/A" ]]; then LAST_DEREGISTER_TIME="N/A"; else calculate_date "$LAST_SEEN_ONLINE" "$LAST_UPDATED"; LAST_DEREGISTER_TIME="$DATE"; fi
        if [[ $OPER_STATE =~ "Up" ]]; then LAST_DEREGISTER_REASON="N/A"; else check_offline_reason $ONU_ID; fi
        ALIVE_TIME=$(echo "$UPTIME" | sed 's#"##g' | sed 's#,##g')
        if [[ $RX_OPTICAL_PW = "0.00" ]]; then RX_POWER_ONU="NULL"; else RX_POWER_ONU=$RX_OPTICAL_PW;fi
        if [[ $TX_OPTICAL_PW = "0.00" ]]; then TX_POWER_ONU="NULL"; else TX_POWER_ONU=$TX_OPTICAL_PW;fi
        if [[ $RSSI_VALUE =~ "Unable" ]]; then RX_POWER_OLT="NULL"; else RX_POWER_OLT=$RSSI_VALUE;fi
        if [ $TABLE -eq 1 ]; then
           echo "$ONU_ID;$ADMIN_STATE;$OMCC_STATE;$PHASE_STATE;$DESCRIPTION;$LAST_REGISTER_TIME;$LAST_DEREGISTER_TIME;$LAST_DEREGISTER_REASON;$ALIVE_TIME;$RX_POWER_ONU;$TX_POWER_ONU;$RX_POWER_OLT" | awk 'BEGIN { FS=";" } { printf "%-16s %-12s %-12s %-12s %-26s %-20s %-20s %-25s %-15s %-15s %-15s %-15s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }'
         else
           echo "$ONU_ID;$ADMIN_STATE;$OMCC_STATE;$PHASE_STATE;$DESCRIPTION;$LAST_REGISTER_TIME;$LAST_DEREGISTER_TIME;$LAST_DEREGISTER_REASON;$ALIVE_TIME;$RX_POWER_ONU;$TX_POWER_ONU;$RX_POWER_OLT"
        fi
      else
        echo "$ONU_ID"
     fi
    ((j++))
   done
}

# Testa a conectividade e versao do Firmware caso o modo debug esteja habilitado
if [ $DEBUG -eq 1 ]; then
 check_ssh_connectivity
 check_firmware_version
 echo ""
fi

# Verifica se o diretório de dados existe, se não, cria um novo
if [ ! -d "$data_dir" ]; then
    mkdir "$data_dir"
fi

# Obtém os dados de quantidade de ONUs Up e Down por porta PON
get_onu_interface_count "$data_file_current"

# Obtém a lista de alarmes presente no sistema
get_alarms "$data_file_alarms"

# Verifica se o arquivo de dados antigos existe, se não, cria um com os dados atuais
if [ ! -f "$data_file_old" ]; then
    cp "$data_file_current" "$data_file_old"
fi

# Verifica quantidade de portas a serem verificadas
pon_count=$(cat "$data_file_current" | wc -l)

# Loop para verificar as interfaces que tiveram alteracao de status e atualizar o arquivo de dados por porta PON
if [ $HEADER -eq 1 ]; then
   if [ $TABLE -eq 1 ]; then
      echo "ONU ID;Admin State;OMCC State;Phase State;Description;Last Register Time;Last Deregister Time;Last Deregister Reason;Alive Time;RX Power(ONU);TX Power(ONU);RX Power(OLT)" | awk 'BEGIN { FS=";" } { printf "%-16s %-12s %-12s %-12s %-26s %-20s %-20s %-25s %-15s %-15s %-15s %-15s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }';
    else
      echo "ONU ID;Admin State;OMCC State;Phase State;Description;Last Register Time;Last Deregister Time;Last Deregister Reason;Alive Time;RX Power(ONU);TX Power(ONU);RX Power(OLT)";
   fi
fi
i=1
while [ $i -le $pon_count ]; do
    pon_onus_old=$(sed "${i}q;d" "$data_file_old" | cut -d ';' -f 1-5 | tr -d '\n')
    pon_onus_current=$(sed "${i}q;d" "$data_file_current" | cut -d ';' -f 1-5 | tr -d '\n')
    pon_onus_current_timestamp=$(sed "${i}q;d" "$data_file_current" | cut -d ';' -f 1-6 | tr -d '\r')
    timestamp_current=$(sed "${i}q;d" "$data_file_current" | cut -d ';' -f 6 | tr -d '\r')
    timestamp_old=$(sed "${i}q;d" "$data_file_old" | cut -d ';' -f 6 | tr -d '\r')
    timestamp_diff=$(($timestamp_current - $timestamp_old))
    IFS=';' read -r slot_port_dash total non_provisioned up down timestamp <<< "$pon_onus_current_timestamp"
    if [[ "$pon_onus_current" != "$pon_onus_old" ]] || [[ "$timestamp_diff" -ge "$MAX_REFRESH_PERIOD" ]] || [[ ! -f "$data_dir/${slot_port_dash//\//-}.csv" ]]; then
        slot_port=$(echo $slot_port_dash | sed 's#-# #')
        if [ $DEBUG -eq 1 ]; then
           if [[ "$pon_onus_current" != "$pon_onus_old" ]]; then
           echo "$(date "+%Y-%m-%d %T") - ${slot_port_dash}: os ONUs da porta ${slot_port_dash} mudaram o status de $pon_onus_current para $pon_onus_old, consultando o OLT..."
           fi
           if [[ "$timestamp_diff" -ge "$MAX_REFRESH_PERIOD" ]]; then
           echo "$(date "+%Y-%m-%d %T") - ${slot_port_dash}: o periodo entre máximo entre consultas expirou ($timestamp_diff s de $MAX_REFRESH_PERIOD s), consultando o OLT..."
           fi
           if [[ ! -f "$data_dir/${slot_port_dash//\//-}.csv" ]]; then
           echo "$(date "+%Y-%m-%d %T") - ${slot_port_dash}: primeira consulta completa, criando o arquivo $data_dir/${slot_port_dash//\//-}.csv e consultando o OLT..."
           fi
        fi
        get_complete_port_data "$slot_port" "$data_dir/${slot_port_dash//\//-}.csv"
        cmd="sed -i 's#^#${slot_port_dash}:#' $data_dir/${slot_port_dash//\//-}.csv; sed -i 's#,#;#g' $data_dir/${slot_port_dash//\//-}.csv; sed -i 's#day;#day,#g' $data_dir/${slot_port_dash//\//-}.csv; sed -i 's#days;#days,#g' $data_dir/${slot_port_dash//\//-}.csv"; eval $cmd
        timestamp_new=$(date +%s)
        cmd="sed -i '${i}s#.*#${pon_onus_current};${timestamp_new}#' $data_file_old"; eval $cmd
        show_onu_data "$data_dir/${slot_port_dash//\//-}.csv" "$slot_port_dash"
        if [ $DEBUG -eq 1 ]; then echo ""; fi
    else
        if [ $DEBUG -eq 1 ]; then
           echo "$(date "+%Y-%m-%d %T") - ${slot_port_dash}: os ONUs não mudaram o status desde a última consulta. Atual: $pon_onus_current. Anterior: $pon_onus_old";
           echo "$(date "+%Y-%m-%d %T") - ${slot_port_dash}: o periodo maximo entre consultas ainda não expirou ($timestamp_diff s de $MAX_REFRESH_PERIOD s)";
        fi
     show_onu_data "$data_dir/${slot_port_dash//\//-}.csv" "$slot_port_dash"
     if [ $DEBUG -eq 1 ]; then echo ""; fi
    fi
    ((i++))
done
