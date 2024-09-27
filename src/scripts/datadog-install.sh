#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

help()
{
    echo "Installs DataDog agent"
    echo ""
    echo "Options:"
    echo "    -k      DataDog API key"
    echo "    -n      Cluster name"
    echo "    -r      Node role: master, data, client"
    echo "    -h      view this help content"
}

# Custom logging with time so we can easily relate running times, also log to separate file so order is guaranteed.
# The Script extension output the stdout/err buffer in intervals with duplicates.
log()
{
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1"
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1" >> /var/log/datadog-install.log
}

#########################
# Parameter handling
#########################

API_KEY=""
CLUSTER_NAME=""
NODE_ROLE=""

#Loop through options passed
while getopts :k:n:r:h optname; do
  log "Option $optname set"
  case $optname in
    k) # DataDog API key
      API_KEY="${OPTARG}"
      ;;
    n) # Cluster Name
      CLUSTER_NAME="${OPTARG}"
      ;;  
    r) # Node role
      NODE_ROLE="${OPTARG}"
      ;;
    h) #show help
      help
      exit 2
      ;;
    \?) #unrecognized option - show help
      echo -e \\n"ERROR: unknown option -${BOLD}$OPTARG${NORM}" >&2
      help
      exit 2
      ;;
  esac
done

if [ "$API_KEY" == "" ]; then
    log "Must provide a DataDog API Key" >&2
    exit 1
fi

if [ "$NODE_ROLE" == "" ]; then
    log "Must provide a Node Type value: master, client, or data" >&2
    exit 1
fi

#########################
# Constants
#########################
DD_CONFIG_FILE=/etc/datadog-agent/datadog.yaml
ELASTIC_CONFIG_FILE=/etc/datadog-agent/conf.d/elastic.d/conf.yaml
DD_AGENT=/var/tmp/install_datadog_agent.sh
ELASTIC_LOG_DIR=/var/log/elasticsearch
VM_NAME=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/name?api-version=2021-02-01&format=text")
TAGS="elasticsearch_cluster:${CLUSTER_NAME}"
DATADOG_HOSTNAME="${VM_NAME}-${CLUSTER_NAME}"

#########################
# Execution
#########################

log "Installing DataDog plugin onto this machine using API Key [$API_KEY]"

wget -q https://raw.githubusercontent.com/DataDog/datadog-agent/master/cmd/agent/install_script.sh -O $DD_AGENT
chmod +x $DD_AGENT
DD_API_KEY=$API_KEY DD_AGENT_MAJOR_VERSION=7 DD_HOSTNAME=$DATADOG_HOSTNAME DD_TAGS=$TAGS $DD_AGENT 
rm /etc/datadog-agent/conf.d/elastic.d/auto_conf.yaml

echo "logs_enabled: true" >> $DD_CONFIG_FILE
chmod +rx $ELASTIC_LOG_DIR
echo "
init_config:

instances:
  - url: 'http://localhost:9200'
    pshard_stats: true
    index_stats: true
    cluster_stats: false
    pending_task_stats: true
    tags:
      - 'elasticsearch-role:$NODE_ROLE-node'
logs:
  - type: file
    path: $ELASTIC_LOG_DIR/*.log
    source: elasticsearch" >> $ELASTIC_CONFIG_FILE

systemctl restart datadog-agent

log "Finished installing DataDog plugin."
