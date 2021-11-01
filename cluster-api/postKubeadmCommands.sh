#!/bin/bash

# Variables
# KUBERNETES_CONTROLPLANE_ENDPOINT
# KUBERNETES_VERSION
# EQUINIX_METAL_APIKEY
# EQUINIX_METAL_PROJECT
# SHARINGIO_PAIR_INSTANCE_NAME
# SHARINGIO_PAIR_INSTANCE_SETUP_EMAIL
# SHARINGIO_PAIR_INSTANCE_SETUP_USER
# SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE
# SHARINGIO_PAIR_INSTANCE_SETUP_GUESTS
# SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME
# SHARINGIO_PAIR_INSTANCE_HUMACS_REPOSITORY
# SHARINGIO_PAIR_INSTANCE_HUMACS_VERSION
# SHARINGIO_PAIR_INSTANCE_SETUP_TIMEZONE
# SHARINGIO_PAIR_INSTANCE_SETUP_FULLNAME
# SHARINGIO_PAIR_INSTANCE_SETUP_EMAIL
# SHARINGIO_PAIR_INSTANCE_SETUP_GITHUBOAUTHTOKEN
# SHARINGIO_PAIR_INSTANCE_SETUP_REPOS_EXPANDED
# SHARINGIO_PAIR_INSTANCE_SETUP_ENV_EXPANDED
# MACHINE_IP

if sudo [ -f /root/.sharing-io-pair-init.env ]; then
  ENV_FILE=/root/.sharing-io-pair-init.env
elif sudo [ -f /var/run/host/root/.sharing-io-pair-init.env ]; then
  ENV_FILE=/var/run/host/root/.sharing-io-pair-init.env
fi
. <(sudo cat "${ENV_FILE}" | tr -d '\r')

NAMESPACES=(
  pair-system
  external-dns
  metallb
  nginx-ingress
  helm-operator
  kube-prometheus
  $SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE
)

# use kubeconfig
mkdir -p /root/.kube
cp -if /etc/kubernetes/admin.conf /root/.kube/config
export KUBECONFIG=/root/.kube/config

# ensure correct directory
pwd
cd $(dirname $0)

# ensure ii user has sufficient capabilities and access
mkdir -p /etc/sudoers.d
echo "%sudo    ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/sudo
cp -a /root/.ssh /etc/skel/.ssh
useradd -m -G users,sudo -u 1000 -s /bin/bash ii
cp -a /root/.kube /home/ii/.kube
chown ii:ii -R /home/ii/.kube

# add SSH keys
sudo -iu ii ssh-import-id "gh:$SHARINGIO_PAIR_INSTANCE_SETUP_USER"
for GUEST in $SHARINGIO_PAIR_INSTANCE_SETUP_GUESTS; do
    sudo -iu ii ssh-import-id "gh:$GUEST"
done

# create namespaces
for NAMESPACE in ${NAMESPACES[*]}; do
    kubectl create namespace $NAMESPACE
done
# allow scheduling
kubectl taint node --all node-role.kubernetes.io/master-

# add packet-cloud-config for picking up some values later
kubectl create secret generic -n kube-system packet-cloud-config --from-literal=cloud-sa.json="{\"projectID\": \"$EQUINIX_METAL_PROJECT\"}" --dry-run=client -o yaml | \
  kubectl apply -f-

# setup host path storage
kubectl apply -f ./manifests/local-path-storage.yaml
kubectl patch storageclasses.storage.k8s.io local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# handy things
kubectl apply -f ./manifests/cert-manager.yaml
kubectl apply -f ./manifests/weavenet.yaml
kubectl apply -f ./manifests/helm-operator-crds.yaml
kubectl -n helm-operator apply -f ./manifests/helm-operator.yaml
kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e "s/strictARP: false/strictARP: true/" | kubectl apply -f - -n kube-system
kubectl apply -f ./manifests/metallb-namespace.yaml
kubectl apply -f ./manifests/metallb.yaml
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)" 2> /dev/null
envsubst < ./manifests/metallb-system-config.yaml | kubectl -n metallb-system apply -f -
envsubst < ./manifests/metrics-server.yaml | kubectl apply -f -
envsubst < ./manifests/kubed.yaml | kubectl apply -f -

# Humacs
kubectl label ns "$SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE" cert-manager-tls=sync
envsubst < ./manifests/humacs-pvc.yaml | kubectl apply -f -
envsubst < ./manifests/humacs.yaml | kubectl apply -f -

(
  echo "Waiting until Humacs is ready"
  until kubectl -n "${SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE}" wait pod --for=condition=Ready --selector=app.kubernetes.io/name=humacs --timeout=10s; do
    sleep 1s
  done
  echo "Waiting until nginx-ingress admission webhook is available"
  until kubectl -n "${SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE}" exec -it "statefulset/${SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE}-humacs" -- nc -zv nginx-ingress-ingress-nginx-controller-admission.nginx-ingress.svc 443; do
    sleep 1s
  done

  # prometheus + grafana
  envsubst < ./manifests/kube-prometheus.yaml | kubectl apply -f -
  kubectl label ns kube-prometheus cert-manager-tls=sync

  # www
  envsubst < ./manifests/go-http-server.yaml | kubectl apply -f -
  envsubst < ./manifests/reveal-multiplex.yaml | kubectl apply -f -
) &

# scale the ingress controller across all the nodes
export SHARINGIO_PAIR_INSTANCE_TOTAL_NODES=$((1 + ${__SHARINGIO_PAIR_KUBERNETES_WORKER_NODES:-0}))
export SHARINGIO_PAIR_INSTANCE_TOTAL_NODES_MAX_REPLICAS=$((SHARINGIO_PAIR_INSTANCE_TOTAL_NODES * SHARINGIO_PAIR_INSTANCE_TOTAL_NODES))
# nginx-ingress-controller
envsubst < ./manifests/nginx-ingress.yaml | kubectl apply -f -
(
  time (
    until kubectl -n nginx-ingress get deployment nginx-ingress-ingress-nginx-controller; do
        echo "waiting for nginx-ingress deployment"
        sleep 5s
    done
  )
  time (
    until kubectl -n nginx-ingress get svc nginx-ingress-ingress-nginx-controller; do
      sleep 1s
    done
  )
  echo true > /tmp/.sharingio-pair-init-ready-nginx-ingress
  kubectl -n nginx-ingress patch svc nginx-ingress-ingress-nginx-controller -p "{\"spec\":{\"externalIPs\":[\"${KUBERNETES_CONTROLPLANE_ENDPOINT}\",\"${MACHINE_IP}\"]}}"
) &

# Instance managed DNS
kubectl apply -f ./manifests/external-dns-crd.yaml
envsubst < ./manifests/external-dns.yaml | kubectl apply -f -
kubectl -n external-dns create secret generic external-dns-pdns \
    --from-literal=domain-filter="$SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME" \
    --from-literal=txt-owner-id="$SHARINGIO_PAIR_INSTANCE_SETUP_USER"
envsubst < ./manifests/dnsendpoint.yaml | kubectl apply -f -

envsubst < ./manifests/coredns-etcd.yaml | kubectl apply -f -
envsubst < ./manifests/coredns.yaml | kubectl apply -f -

time (
  until [ "$(dig A ${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME} +short)" = "${KUBERNETES_CONTROLPLANE_ENDPOINT}" ]; do
      echo "BaseDNSName does not resolve to Instance IP yet"
      sleep 1
  done
)
envsubst < ./manifests/certs.yaml | kubectl apply -f -

until (
    [ "$(cat /tmp/.sharingio-pair-init-ready-dns 2> /dev/null)" = "true" ] && [ "$(cat /tmp/.sharingio-pair-init-ready-nginx-ingress 2> /dev/null)" = "true" ] \
      || [ "$(cat /tmp/.sharingio-pair-init-force-ready 2> /dev/null)" = "true" ]
  ); do
  echo "Waiting for DNS and nginx-ingress to be ready"
  sleep 1s
done

kubectl -n default create configmap sharingio-pair-init-complete 2> /dev/null

time (
  while true; do
      conditions=$(kubectl -n "${SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE}" get cert letsencrypt-prod -o=jsonpath='{.status.conditions[0]}')
      if [ "$(echo $conditions | jq -r .type)" = "Ready" ] && [ "$(echo $conditions | jq -r .status)" = "True" ]; then
        break
      fi
      echo "Waiting for valid TLS cert"
      sleep 1
  done
)
kubectl -n "${SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE}" annotate secret letsencrypt-prod kubed.appscode.com/sync=cert-manager-tls --overwrite

