#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
cluster=de-hw5
ns=de-hw5
mkdir -p logs
exec > >(tee logs/cluster.log) 2>&1
if kind get clusters | grep -Fxq "$cluster"; then echo 'Use a fresh de-hw5 cluster to isolate evidence'; exit 1; fi
kind create cluster --name "$cluster"
K=(kubectl --context "kind-$cluster" -n "$ns")
k(){ "${K[@]}" "$@"; }
docker build -t hw5-skills:local .
kind load docker-image hw5-skills:local --name "$cluster"
k create namespace "$ns"
apply(){ k apply -f "manifests/$1.json"; }
finish(){ k wait --for=condition=complete --timeout=180s "job/$1"; k logs "job/$1"; }
trap 'k get pods -o wide; k get events --sort-by=.metadata.creationTimestamp > logs/events.txt' EXIT
apply measure
finish measure
peak=$(k logs job/measure | awk '/^peak_bytes / {print $2}')
[[ "$peak" =~ ^[1-9][0-9]*$ ]]
limit=$(( (peak*125 + 104857600-1)/104857600 ))
echo "peak=$peak bytes; tuned limit=${limit}Mi"
apply oom
k wait --for=condition=failed --timeout=150s job/oom
k get pod -l job-name=oom -o json > logs/oom.json
python3 -c 'import json; assert json.load(open("logs/oom.json"))["items"][0]["status"]["containerStatuses"][0]["state"]["terminated"]["reason"]=="OOMKilled"'
python3 - "$limit" <<'PY' | k apply -f -
import json,sys
j=json.load(open('manifests/measure.json'))
j['metadata']['name']='tuned'
j['spec']['template']['spec']['containers'][0]['resources']['limits']['memory']=sys.argv[1]+'Mi'
print(json.dumps(j))
PY
finish tuned
apply storage
k rollout status deployment/rustfs --timeout=240s
for job in seed map reduce; do apply "$job"; finish "$job"; done
k get pods -l job-name=map -o json > logs/map-pods.json
k logs job/reduce > logs/cluster-top10.json
apply priorities
cpu=$(k get nodes -o jsonpath='{.items[0].status.allocatable.cpu}')
case "$cpu" in *m) milli=${cpu%m};; *) milli=$(( cpu*1000 ));; esac
request=$(( milli/2+1 ))
pod(){
  k run "$1" --image=hw5-skills:local --image-pull-policy=Never --restart=Never \
    --overrides="{\"spec\":{\"terminationGracePeriodSeconds\":0,\"priorityClassName\":\"hw5-$2\",\"containers\":[{\"name\":\"wait\",\"image\":\"hw5-skills:local\",\"imagePullPolicy\":\"Never\",\"command\":[\"sleep\",\"600\"],\"resources\":{\"requests\":{\"cpu\":\"${3}m\"}}}]}}"
}
pod low low "$request"
k wait --for=condition=Ready pod/low --timeout=100s
pod waiting low "$request"
for i in {1..60}; do k describe pod waiting > logs/waiting.txt; grep -q 'Insufficient cpu' logs/waiting.txt && break; sleep 1; done
grep 'Insufficient cpu' logs/waiting.txt
k delete pod waiting --wait=true
pod high high "$request"
k wait --for=condition=Ready pod/high --timeout=150s
k wait --for=delete pod/low --timeout=60s
k get events --field-selector involvedObject.name=low -o yaml > logs/preemption.yaml
grep -i preempt logs/preemption.yaml
k delete pod high
k create namespace de-hw5-quota
K=(kubectl --context "kind-$cluster" -n de-hw5-quota)
apply quota
pod first low 10
if pod second low 10 > logs/quota.txt 2>&1; then exit 1; fi
grep 'exceeded quota' logs/quota.txt
K=(kubectl --context "kind-$cluster" -n "$ns")
