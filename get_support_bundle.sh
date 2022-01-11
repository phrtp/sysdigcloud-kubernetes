#!/bin/bash
set -euo pipefail

#generate sysdigcloud support bundle on kubernetes

NAMESPACE=${1:-sysdigcloud}
LABELS=""
CONTEXT=""
LOG_DIR=$(mktemp -d sysdigcloud-support-bundle-XXXX)

while getopts l:n:C:hced flag; do
  case "${flag}" in
    l) LABELS=${OPTARG:-};;
    n) NAMESPACE=${OPTARG:-sysdigcloud};;
    h) 

      echo "Usage: ./get_support_bundle.sh -n <NAMESPACE> -l <LABELS>"; printf "\n"; 
      echo "Example: ./get_support_bundle.sh -n sysdig -l api,collector,worker,cassandra,elasticsearch"; printf "\n"; 
      echo "Flags:"; printf "\n"
      echo "-n  Specify the Sysdig namespace. If not specified, "sysdigcloud" is assumed."; printf "\n";
      echo "-C  Specify the kubectl context. If not set, the current context will be used."; printf "\n";
      echo "-c  Include Cassandra storage information"; printf "\n";
      echo "-e  Include Elasticsearch storage information"; printf "\n";
      echo "-d  Include container density information"; printf "\n";     
      exit;;

    C) CONTEXT=${OPTARG:-};;

    c) echo "Fetching Cassandra storage info";

      # Executes a df -h in Cassandra pod, gets proxyhistograms, tpstats, and compactionstats

      printf "Pod#\tFilesystem\tSize\tUsed\tAvail\tUse\tMounted on\n" > ${LOG_DIR}/cassandra_storage.log
      for pod in $(kubectl get pods -l role=cassandra -n ${NAMESPACE} | grep -v "NAME" | awk '{print $1}')
      do
        #printf "$pod\t" > ${LOG_DIR}/cassandra_storage.log
        kubectl exec -it $pod -n ${NAMESPACE} -- df -Ph | grep cassandra | grep -v "tmpfs" | awk '{printf "%-13s %10s %6s %8s %6s %s\n",$1,$2,$3,$4,$5,$6}' > ${LOG_DIR}/cassandra_storage.log
      done

      for pod in $(kubectl get pods -l role=cassandra -n sysdig | grep -v "NAME" | awk '{print $1}'); do echo $pod; for cmd in proxyhistograms status tpstats compactionstats; do kubectl exec $pod -c cassandra -n sysdig -- nodetool $cmd > ${LOG_DIR}/cassandra_nodes_output.log;
      done; done;;

    e) echo "Fetching Elasticsearch storage info";

      printf "Pod#\tFilesystem\tSize\tUsed\tAvail\tUse\tMounted on\n" |tee -a elasticsearch_storage.log
      for pod in $(kubectl get pods -l role=elasticsearch -n ${NAMESPACE} | grep -v "NAME" | awk '{print $1}')
      do
        printf "$pod\t" |tee -a elasticsearch_storage.log
        kubectl exec -it $pod -n ${NAMESPACE} -- df -Ph | grep elasticsearch | grep -v "tmpfs" | awk '{printf "%-13s %10s %6s %8s %6s %s\n",$1,$2,$3,$4,$5,$6}' |tee -a elasticsearch_storage.log
      done;;

    d) echo "Fetching container density";

      num_nodes=0
      num_pods=0
      num_running_containers=0
      num_total_containers=0

	printf "%-30s %-10s %-10s %-10s %-10s\n" "Node" "Pods" "Running Containers" "Total Containers" >> ${LOG_DIR}/container_density.txt
	for node in $(kubectl get nodes --no-headers -o custom-columns=node:.metadata.name); do
		total_pods=$(kubectl get pods -A --no-headers -o wide | grep ${node} |wc -l |xargs)
			running_containers=$( kubectl get pods -A --no-headers -o wide |grep ${node} |awk '{print $3}' |cut -f 1 -d/ | awk '{ SUM += $1} END { print SUM }' |xargs)
			total_containers=$( kubectl get pods -A --no-headers -o wide |grep ${node} |awk '{print $3}' |cut -f 2 -d/ | awk '{ SUM += $1} END { print SUM }' |xargs)
			printf "%-30s %-15s %-20s %-10s\n" "${node}" "${total_pods}" "${running_containers}" "${total_containers}" >> ${LOG_DIR}/container_density.txt
			num_nodes=$((num_nodes+1))
			num_pods=$((num_pods+${total_pods}))
			num_running_containers=$((num_running_containers+${running_containers}))
			num_total_containers=$((num_total_containers+${total_containers}))
	done

	printf "\nTotals\n-----\n" >> ${LOG_DIR}/container_density.txt
	printf "Nodes: ${num_nodes}\n" >> ${LOG_DIR}/container_density.txt
	printf "Pods: ${num_pods}\n" >> ${LOG_DIR}/container_density.txt
	printf "Running Containers: ${num_running_containers}\n" >> ${LOG_DIR}/container_density.txt
	printf "Containers: ${num_total_containers}\n" >> ${LOG_DIR}/container_density.txt

    
  esac
done

if [[ -z ${NAMESPACE} ]]; then
  NAMESPACE=sysdigcloud
fi

if [[ -z ${CONTEXT} ]]; then
  CONTEXT=""
fi

#verify that the provided namespace exists
kubectl get namespace ${NAMESPACE} > /dev/null

KUBE_OPTS="--namespace ${NAMESPACE} --context=${CONTEXT}"


if [[ -z ${LABELS} ]]; then
  SYSDIGCLOUD_PODS=$(kubectl ${KUBE_OPTS} get pods | awk '{ print $1 }' | grep -v NAME)
else
  SYSDIGCLOUD_PODS=$(kubectl ${KUBE_OPTS} -l "role in (${LABELS})" get pods | awk '{ print $1 }' | grep -v NAME)
fi

echo "Using namespace ${NAMESPACE}";
echo "Using context ${CONTEXT}";

command='tar czf - /logs/ /opt/draios/ /var/log/sysdigcloud/ /var/log/cassandra/ /tmp/redis.log /var/log/redis-server/redis.log /var/log/mysql/error.log /opt/prod.conf 2>/dev/null || true'
for pod in ${SYSDIGCLOUD_PODS}; do
    echo "Getting support logs for ${pod}"
    mkdir -p ${LOG_DIR}/${pod}
    kubectl ${KUBE_OPTS} get pod ${pod} -o json > ${LOG_DIR}/${pod}/kubectl-describe.json
    containers=$(kubectl ${KUBE_OPTS} get pod ${pod} -o json | jq -r '.spec.containers[].name')
    for container in ${containers}; do
        kubectl ${KUBE_OPTS} logs ${pod} -c ${container} > ${LOG_DIR}/${pod}/${container}-kubectl-logs.txt
        kubectl ${KUBE_OPTS} exec ${pod} -c ${container} -- bash -c "${command}" > ${LOG_DIR}/${pod}/${container}-support-files.tgz || true
    done
done

for object in svc deployment sts pvc daemonset ingress replicaset; do
    items=$(kubectl ${KUBE_OPTS} get ${object} -o jsonpath="{.items[*]['metadata.name']}")
    mkdir -p ${LOG_DIR}/${object}
    for item in ${items}; do
        kubectl ${KUBE_OPTS} get ${object} ${item} -o json > ${LOG_DIR}/${object}/${item}-kubectl.json
    done
done

kubectl ${KUBE_OPTS} get configmap sysdigcloud-config -o yaml | grep -v password > ${LOG_DIR}/config.yaml

BUNDLE_NAME=$(date +%s)_sysdig_cloud_support_bundle.tgz
tar czf ${BUNDLE_NAME} ${LOG_DIR}
rm -rf ${LOG_DIR}

echo "Support bundle generated:" ${BUNDLE_NAME}
