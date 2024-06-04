#!/bin/bash

#-- START show_error
RED=$'\e[1;31m'
GREEN=$'\e[1;32m'
WHITE=$'\e[0m'
DOLLAR='$'

function show_error {
    echo "${RED}$1${WHITE}"
    exit -1
}
#-- END show_error

#-- START argparse
# Try to get IP address using hostname command
IP=$(hostname -I | awk '{print $1}')

# If hostname command failed, try ip command
if [ -z "$IP" ]; then
    IP=$(ip addr show eth0 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
fi

# If ip command failed, try ifconfig command
if [ -z "$IP" ]; then
    IP=$(ifconfig eth0 | grep 'inet ' | awk '{print $2}')
fi

# If ifconfig command failed, try nmcli command
if [ -z "$IP" ]; then
    IP=$(nmcli -g ip4.address device show eth0 | cut -d'/' -f1)
fi

# DEFAULT PARAMETERS
AIO_IMAGE=registry.baidubce.com/fd-maas/doc-ai-aio-encrypt:20240531-0
OCR_IMAGE=registry.baidubce.com/fd-maas/doc-ai-ocr-api:20240430-1
HOST=$IP
PORT=8080
INSTALL_ROOT=$1
VENDOR=26707
FORCED=0
DB_NAME=doc_ai
DB_USER=doc_ai
DB_PASSWORD=
CONCURRENCY=4

function show_help {
    echo ""
    echo "Usage: "
    echo "    ./install-aio.sh [OPTIONS] <install_root>"
    echo ""
    echo "    OPTIONS:"
    echo "        --help"
    echo "        -a|--aio-image <aio-image> | default $AIO_IMAGE | optional "
    echo "        -o|--ocr-image <ocr-image> | default $OCR_IMAGE | optional  "
    echo "        -h|--host <host> | default $HOST | optional  "
    echo "        -p|--port <port> | default $PORT | optional  "
    echo "        -c|--concurrency <concurrency> | default $CONCURRENCY | optional  "
    echo "        --db-name <db-name> | default $DB_NAME | optional  "
    echo "        --db-user <db-user> | default $DB_USER | optional  "
    echo "        --db-password <db-password> "
    echo "        -f|--force | optional  "
    echo ""
    exit -1
}

function handle_params {
    # Loop parameters
    while [[ $# -gt 0 ]]
    do
        if [[  $1 == "--help" ]] ; then
            show_help
            exit 0
        elif [[ $1 == "-a" || $1 == "--aio-image" ]] ; then
            AIO_IMAGE=$2
            shift
            shift
        elif [[ $1 == "-o" || $1 == "--ocr-image" ]] ; then
            OCR_IMAGE=$2
            shift
            shift
        elif [[ $1 == "-h" || $1 == "--host" ]] ; then
            OCR_IMAGE=$2
            shift
            shift
        elif [[ $1 == "-p" || $1 == "--port" ]] ; then
            PORT=$2
            shift
            shift
        elif [[ $1 == "-c" || $1 == "--concurrency" ]] ; then
            CONCURRENCY=$2
            shift
            shift
        elif [[ $1 == "--db-name" ]] ; then
            DB_NAME=$2
            shift
            shift
        elif [[ $1 == "--db-user" ]] ; then
            DB_USER=$2
            shift
            shift
        elif [[ $1 == "--db-password" ]] ; then
            DB_PASSWORD=$2
            shift
            shift
        elif [[ $1 == "-f" || $1 == "--force" ]] ; then
            FORCED=1
            shift
        elif [[ $1 == -* || $1 == --* ]] ; then
            OTHER_OPTS="$OTHER_OPTS $1"
            OTHER_OPTS="$OTHER_OPTS $2"
            shift
            shift
        else
            INSTALL_ROOT=$1
            break
        fi
    done
}
#-- END argparse

handle_params $@


if [[ ! -d $INSTALL_ROOT ]] ; then
    show_error "ERROR: $INSTALL_ROOT is not a dir."
fi

if [[ -z $HOST ]] ; then
    show_error "ERROR: failed to determinate host ip, please specify it with option -h|--host."
fi

if [[ -z $DB_PASSWORD ]] ; then
    show_error "ERROR: please specify db password with option --db-password."
fi

if [[ $FORCED == 0 && "$(docker ps -a -q -f name=doc-ai-aio)" ]]; then
    if [[ $FORCED == 0 ]] ; then
        show_error "WARNING: Container 'doc-ai-aio' exists. Please clean previous install first. Or use '-f' '--force' option to ignore."
    else
        docker rm -f doc-ai-aio
    fi
else
    echo "Container 'doc-ai-aio' does not exist."
fi

INSTALL_ROOT=$(realpath $INSTALL_ROOT)

echo "----------------------------------------------"
echo "INSTALL on $HOST:$INSTALL_ROOT..."
echo "----------------------------------------------"

if [[ $(whoami) == 'root' ]] ; then
  echo "User has sudo privileges"
else
  show_error "User does not have sudo privileges"
fi


echo "----------------------------------------------"
echo "Pulling all container images"
echo "----------------------------------------------"
docker pull $AIO_IMAGE
docker pull $OCR_IMAGE

echo "----------------------------------------------"
echo "Copy files"
echo "----------------------------------------------"
docker create --name temp-api-container $AIO_IMAGE
docker cp temp-api-container:/app/deploy/docker-compose.yml $INSTALL_ROOT/
docker cp temp-api-container:/app/deploy/application.yml $INSTALL_ROOT/
if [[ -d $INSTALL_ROOT/bin ]] ; then
    rm -rf $INSTALL_ROOT/bin
fi
docker cp temp-api-container:/app/deploy/bin/ $INSTALL_ROOT/bin
docker cp temp-api-container:/opt/sentinel/ $INSTALL_ROOT/sentinel/
docker rm temp-api-container

echo "----------------------------------------------"
echo "Install license service"
echo "----------------------------------------------"
if [[ $(which dpkg) != '' ]] ; then
    dpkg -i $INSTALL_ROOT/sentinel/runtime/aksusbd_8.51-1_amd64.deb
elif [[ $(which rpm) != '' ]] ; then
    rpm -i $INSTALL_ROOT/sentinel/runtime/aksusbd-8.51-1.x86_64.rpm 
else
    show_error "ERROR: rpm or dpkg required."
fi

cp $INSTALL_ROOT/sentinel/libs/haspvlib_* /var/hasplm/
{
  echo "accremote=1"
  echo "adminremote=1" 
} > /etc/hasplm/hasplm.ini
service aksusbd restart


echo "Prepare env"


if [[ ! -d  $INSTALL_ROOT/mysql ]] ; then
  mkdir -p $INSTALL_ROOT/mysql
fi

if [[ ! -d  $INSTALL_ROOT/docai-api ]] ; then
  mkdir -p $INSTALL_ROOT/docai-api/logs
  touch $INSTALL_ROOT/docai-api/logs/dummuy.log
fi

if [[ $FORCED == 1 || ! -f $INSTALL_ROOT/hasp_$VENDOR.ini ]] ; then
  {
    echo "errorlog=1"
    echo "requestlog=1" 
    echo "serveraddr=$HOST" 
    echo "broadcastsearch=1" 
  }> $INSTALL_ROOT/hasp_$VENDOR.ini
fi

if [[ $FORCED == 1 || ! -f $INSTALL_ROOT/.env ]] ; then
  {
    echo "# Env file for docai-api" 
    echo "DOC_AI_INSTALL_ROOT=$INSTALL_ROOT"
    echo "DOC_AI_INSTALL_VENDOR=$VENDOR" 
    echo "DOC_AI_AIO_IMAGE=$AIO_IMAGE" 
    echo "DOC_AI_OCR_IMAGE=$OCR_IMAGE"
    echo "DOC_AI_OCR_API_REPLICAS=$CONCURRENCY"
    echo "QUEUE_WORKER_NUM=$CONCURRENCY"
    echo "DOC_AI_MYSQL_DB_NAME=$DB_NAME" 
    echo "DOC_AI_MYSQL_USER=$DB_USER" 
    echo "DOC_AI_MYSQL_PASSWORD=$DB_PASSWORD" 
    echo "DOC_AI_HOST_IP=$HOST" 
    echo "DOC_AI_WEB_PORT=$PORT"
    echo "DOC_AI_VENDOR=$VENDOR"
    echo "docai_ocr_concurrency=$CONCURRENCY"
    echo "docai_ocr_accessKeyId=xxxx"
    echo "docai_ocr_accessKeySecret=yyyy"
    echo "docai_ocr_endpoint=ocr-api:9090"
    echo "DB_DATABASE=$DB_NAME"
    echo "DB_USERNAME=$DB_USER"
    echo "DB_PASSWORD=$DB_PASSWORD"
    echo "DOC_SERVICE_HOST=http://localhost:5000"
    echo "DOC_SERVICE_TIMEOUT=1800"
  } > $INSTALL_ROOT/.env
fi

cd $INSTALL_ROOT
docker compose -f docker-compose.yml down
docker compose -f docker-compose.yml up -d

# 容器名称
container_name="doc-ai-aio"

# 循环检查容器状态
while true; do
    # 使用docker ps命令检查容器状态
    container_status=$(docker ps -f "name=$container_name" --format "{{.Status}}")

    # 检查容器状态是否为"Up"，表示容器正在运行
    if [[ "$container_status" == *"Up"* ]]; then
        echo "容器 $container_name 状态为可用。"
        break
    else
        echo "容器 $container_name 状态为 $container_status，正在等待..."
    fi

    # 等待一段时间后再次检查，这里设置为5秒
    sleep 5
done

echo "容器检查完成。"

docker exec -ti $container_name /app/bin/create-db-and-migrate.sh

service aksusbd restart

docker exec -ti $container_name /app/bin/start-all-services.sh

