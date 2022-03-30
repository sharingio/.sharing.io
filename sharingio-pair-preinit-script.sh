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
        if [ -d "${HOME}/.sharing.io/cluster-api/manifests/extras/${EXTRA}" ]; then
            for FILE in "${HOME}/.sharing.io/cluster-api/manifests/extras/${EXTRA}"/*; do
                envsubst < "${FILE}" | kubectl apply -f -
            done
        elif [ -f "${EXTRA_FILE}" ]; then
            envsubst < "${EXTRA_FILE}" | kubectl apply -f -
        else
            echo "Error: requested extra '$EXTRA' not found in ${HOME}/.sharing.io/cluster-api/manifests/extras/"
            continue
        fi
    done
fi

(
    until curl -s https://registry.${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME}; do
        sleep 1
    done
    echo "${SHARINGIO_PAIR_INSTANCE_REGISTRY_PASSWORD}" | \
        docker login \
        "registry.${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME}" \
        --username "${SHARINGIO_PAIR_INSTANCE_REGISTRY_USER}" \
        --password-stdin || true
)&

kubectl create secret docker-registry \
    registry \
    --docker-server="registry.${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME}" \
    --docker-username="${SHARINGIO_PAIR_INSTANCE_REGISTRY_USER}" \
    --docker-password="${SHARINGIO_PAIR_INSTANCE_REGISTRY_PASSWORD}" \
    --docker-email="${SHARINGIO_PAIR_INSTANCE_SETUP_EMAIL}" \
    --dry-run=client -o yaml \
    | kubectl apply -f -
kubectl patch serviceaccount default -p "{\"imagePullSecrets\": [{\"name\": \"registry\"}]}"
