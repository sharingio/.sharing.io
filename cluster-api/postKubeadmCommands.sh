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

export SHARINGIO_PAIR_INSTANCE_INGRESS_CLASS_NAME="contour-external"
export SHARINGIO_PAIR_INSTANCE_INGRESS_REAL_IP_HEADER="X-Envoy-External-Address"
export SHARINGIO_PAIR_INSTANCE_REGISTRY_USER=$SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE
export SHARINGIO_PAIR_INSTANCE_REGISTRY_PASSWORD="$(tr -cd '[:alnum:]' < /dev/urandom | fold -w"${DEFAULT_LENGTH:-32}" | head -n1)"

cat <<EOF >> "${ENV_FILE}"
export SHARINGIO_PAIR_INSTANCE_TOTAL_NODES=$SHARINGIO_PAIR_INSTANCE_TOTAL_NODES
export SHARINGIO_PAIR_INSTANCE_TOTAL_NODES_MAX_REPLICAS=$SHARINGIO_PAIR_INSTANCE_TOTAL_NODES_MAX_REPLICAS
export SHARINGIO_PAIR_INSTANCE_INGRESS_CLASS_NAME=$SHARINGIO_PAIR_INSTANCE_INGRESS_CLASS_NAME
export SHARINGIO_PAIR_INSTANCE_INGRESS_REAL_IP_HEADER=$SHARINGIO_PAIR_INSTANCE_INGRESS_REAL_IP_HEADER
export SHARINGIO_PAIR_INSTANCE_REGISTRY_USER=$SHARINGIO_PAIR_INSTANCE_REGISTRY_USER
export SHARINGIO_PAIR_INSTANCE_REGISTRY_PASSWORD=$SHARINGIO_PAIR_INSTANCE_REGISTRY_PASSWORD
EOF

NAMESPACES=(
  default
  external-dns
  metallb
  nginx-ingress
  helm-operator
  kube-prometheus
  pair-system
  knative-operator
  knative-serving
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
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml \
      | kubectl apply -f -
    kubectl label ns "${NAMESPACE}" cert-manager-tls=sync
done
# allow scheduling
kubectl taint node --all node-role.kubernetes.io/master-

# add packet-cloud-config for picking up some values later
kubectl -n kube-system create secret generic packet-cloud-config --from-literal=cloud-sa.json="{\"projectID\": \"$EQUINIX_METAL_PROJECT\"}" --dry-run=client -o yaml | \
  kubectl apply -f -
kubectl -n pair-system create configmap pair-init-config \
  --from-env-file=<(cat "${ENV_FILE}" | sort | uniq | sed 's/export //g' | sed 's/"//g' | grep -E '[A-Z]+=.*') --dry-run=client -o yaml |
  kubectl apply -f -

kubectl -n default create configmap pair-instance --from-literal=username="${SHARINGIO_PAIR_INSTANCE_SETUP_USER}" --dry-run=client -o yaml | \
  kubectl apply -f -

# setup host path storage
kubectl apply -f ./manifests/local-path-storage.yaml
kubectl patch storageclasses.storage.k8s.io local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# handy things
kubectl apply -f ./manifests/external-dns-crd.yaml
kubectl apply -f ./manifests/cert-manager.yaml
kubectl apply -f ./manifests/weavenet.yaml
kubectl apply -f ./manifests/helm-operator-crds.yaml
kubectl apply -f ./manifests/kubed.yaml
kubectl -n helm-operator apply -f ./manifests/helm-operator.yaml
kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e "s/strictARP: false/strictARP: true/" | kubectl apply -f - -n kube-system
kubectl apply -f ./manifests/metallb-namespace.yaml
kubectl apply -f ./manifests/metallb.yaml
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)" 2> /dev/null
envsubst < ./manifests/metallb-system-config.yaml | kubectl -n metallb-system apply -f -
kubectl -n kube-system apply -f ./manifests/metrics-server.yaml
kubectl -n pair-system create secret generic distribution-auth --from-literal=htpasswd="$(htpasswd -Bbn "$SHARINGIO_PAIR_INSTANCE_REGISTRY_USER" "$SHARINGIO_PAIR_INSTANCE_REGISTRY_PASSWORD")" 2> /dev/null
envsubst < ./manifests/distribution.yaml | kubectl apply -f -
envsubst < ./manifests/local-registry-hosting.yaml | kubectl apply -f -

# Environment
kubectl -n "${SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE}" create configmap environment-user-env \
  --from-env-file=/root/.sharing-io-pair-user.env --dry-run=client -o yaml \
  | kubectl apply -f -
envsubst < ./manifests/environment.yaml | kubectl apply -f -

# Environment Exposer
envsubst < ./manifests/environment-exposer.yaml | kubectl apply -f -

# prometheus + grafana
envsubst < ./manifests/kube-prometheus.yaml | kubectl apply -f -

# www
envsubst < ./manifests/go-http-server.yaml | kubectl apply -f -
envsubst < ./manifests/reveal-multiplex.yaml | kubectl apply -f -

# scale the ingress controller across all the nodes

# Instance managed DNS
envsubst < ./manifests/external-dns.yaml | kubectl apply -f -
envsubst < ./manifests/dnsendpoint.yaml | kubectl apply -f -

# PowerDNS
envsubst '${KUBERNETES_CONTROLPLANE_ENDPOINT} ${MACHINE_IP} ${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME} ${KUBERNETES_CONTROLPLANE_ENDPOINT}' < ./manifests/powerdns.yaml | kubectl apply -f -

# Contour ingress gateway
kubectl apply -f ./manifests/contour.yaml
kubectl -n contour-external patch svc/envoy -p "{\"spec\":{\"externalIPs\":[\"${KUBERNETES_CONTROLPLANE_ENDPOINT}\",\"${MACHINE_IP}\"]}}"

# Knative Operator
kubectl apply -f ./manifests/knative-operator.yaml

# Knative Serving
envsubst < ./manifests/knative-serving.yaml | kubectl apply -f -

time (
  until [ "$(dig A ${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME} +short)" = "${KUBERNETES_CONTROLPLANE_ENDPOINT}" ]; do
      echo "BaseDNSName does not resolve to Instance IP yet"
      sleep 1
  done
)
envsubst < ./manifests/certs.yaml | kubectl apply -f -

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
