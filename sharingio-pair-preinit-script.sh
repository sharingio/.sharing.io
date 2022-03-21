#!/bin/bash

cat << EOF >> $HOME/.gitconfig
[credential "https://github.com"]
  helper = "!f() { test \"\$1\" = get && echo \"password=\${GITHUB_TOKEN:-}\nusername=\${SHARINGIO_PAIR_USER:-}\";}; f"
EOF
git config --global commit.template $HOME/.git-commit-template
cat << EOF > $HOME/.git-commit-template



EOF
for GUEST_NAME in ${SHARINGIO_PAIR_GUEST_NAMES:-}; do
    echo "Co-Authored-By: $GUEST_NAME <$GUEST_NAME@users.noreply.github.com>" >> $HOME/.git-commit-template
done
(
    "$HOME"/.sharing.io/init || true
) &
if [ ! -d /home/ii/.doom.d ]; then
  git clone "https://github.com/$SHARINGIO_PAIR_USER/.doom.d" || \
    git clone https://github.com/humacs/.doom.d
fi

DOOM_CONFIG_FILE=ii.org
if [ -f "${HOME}/.doom.d/${SHARINGIO_PAIR_USER:-}.org" ]; then
    DOOM_CONFIG_FILE="${SHARINGIO_PAIR_USER:-}.org"
fi
if [ -f "${HOME}/.doom.d/${DOOM_CONFIG_FILE:-}" ]; then
    rm -f "${HOME}"/.doom.d/*.el
    org-tangle "${HOME}/.doom.d/${DOOM_CONFIG_FILE:-}"
    doom sync
fi

[ ! -e "$HOME/public_html" ] && \
  ln -s "$HOME/.sharing.io/public_html" "$HOME/public_html"
if [ ! -f "$HOME/public_html/index.html" ]; then
    echo "Welcome to this Pair instance! Add your site in '$HOME/public_html'" > "$HOME/.sharing.io/public_html/index.html"
fi
for repo in $(find ~ -type d -name ".git"); do
    repoName=$(basename $(dirname $repo))
    if [ -x $HOME/.sharing.io/$repoName/init ]; then
        cd $repo/..
        $HOME/.sharing.io/$repoName/init &
        continue
    fi
    if [ -x $repo/../.sharing.io/init ]; then
        cd $repo/..
        ./.sharing.io/init &
    fi
done

. <(sudo cat "/var/run/host/root/.sharing-io-pair-init.env" | tr -d '\r')
if [ -n "${SHARINGIO_PAIR_INIT_EXTRAS:-}" ]; then
    for EXTRA in ${SHARINGIO_PAIR_INIT_EXTRAS[@]:-}; do
        EXTRA_FILE="${HOME}/.sharing.io/cluster-api/manifests/extras/${EXTRA}.yaml"
        if [ ! -f "${EXTRA_FILE}" ]; then
            echo "Error: requested extra '$EXTRA' not found in ${HOME}/.sharing.io/cluster-api/manifests/extras/"
            continue
        fi
        envsubst < "${EXTRA_FILE}" | kubectl apply -f -
    done
fi

# do this later since the CRD won't exist in the initial knative-operator install
if echo "${SHARINGIO_PAIR_INIT_EXTRAS:-}" | grep -q -E "(^| )knative( |$)"; then
    kubectl delete -f "${HOME}"/.sharing.io/cluster-api/manifests/nginx-ingress.yaml
    envsubst < "${HOME}"/.sharing.io/cluster-api/manifests/extras/knative/serving.yaml | kubectl apply -f -
    kubectl -n contour-external patch svc/envoy -p "{\"spec\":{\"externalIPs\":[\"${KUBERNETES_CONTROLPLANE_ENDPOINT}\",\"${MACHINE_IP}\"]}}"
    kubectl label ns contour-external cert-manager-tls=sync
fi
