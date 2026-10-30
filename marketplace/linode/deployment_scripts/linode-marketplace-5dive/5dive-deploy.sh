#!/bin/bash
# STACKSCRIPT_ID: (assigned by Akamai on acceptance)

# enable logging
exec > >(tee /dev/ttyS0 /var/log/stackscript.log) 2>&1

# BEGIN CI-MODE
# modes
#DEBUG="NO"
if [[ -n ${DEBUG} ]]; then
  if [ "${DEBUG}" == "NO" ]; then
    trap "cleanup $? $LINENO" EXIT
  fi
else
  trap "cleanup $? $LINENO" EXIT
fi

# cleanup will always happen. If DEBUG is passed and is anything
# other than NO, it will always trigger cleanup. This is useful for
# ci testing and passing vars to the instance.

if [ "${MODE}" == "staging" ]; then
  trap "provision_failed $? $LINENO" ERR
else
  set -e
fi
# END CI-MODE

## Linode/SSH security settings
#<UDF name="user_name" label="The limited sudo user to be created for the Linode: *No Capital Letters or Special Characters*">
#<UDF name="disable_root" label="Disable root access over SSH?" oneOf="Yes,No" default="No">

# BEGIN CI-ADDONS
## Addons
#<UDF name="add_ons" label="Optional data exporter Add-ons for your deployment" manyOf="node_exporter,mysqld_exporter,newrelic,none" default="none">
# END CI-ADDONS

#GH_USER=""
#BRANCH=""
# git user and branch
if [[ -n ${GH_USER} && -n ${BRANCH} ]]; then
        echo "[info] git user and branch set.."
        export GIT_REPO="https://github.com/${GH_USER}/marketplace-apps.git"

else
        export GH_USER="akamai-compute-marketplace"
        export BRANCH="main"
        export GIT_REPO="https://github.com/${GH_USER}/marketplace-apps.git"
fi

export WORK_DIR="/tmp/marketplace-apps" 
export MARKETPLACE_APP="apps/linode-marketplace-5dive"

function provision_failed {
  echo "[info] Provision failed. Sending status.."

  # dep
  apt install jq -y

  # set token
  local token=($(curl -ks -X POST ${KC_SERVER} \
     -H "Content-Type: application/json" \
     -d "{ \"username\":\"${KC_USERNAME}\", \"password\":\"${KC_PASSWORD}\" }" | jq -r .token) )

  # send pre-provision failure
  curl -sk -X POST ${DATA_ENDPOINT} \
     -H "Authorization: ${token}" \
     -H "Content-Type: application/json" \
     -d "{ \"app_label\":\"${APP_LABEL}\", \"status\":\"provision_failed\", \"branch\": \"${BRANCH}\", \
        \"gituser\": \"${GH_USER}\", \"runjob\": \"${RUNJOB}\", \"image\":\"${IMAGE}\", \
        \"type\":\"${TYPE}\", \"region\":\"${REGION}\", \"instance_env\":\"${INSTANCE_ENV}\" }"

  exit $?
}

function cleanup {
  if [ -d "${WORK_DIR}" ]; then
    rm -rf ${WORK_DIR}
  fi
}

function udf {
  local group_vars="${WORK_DIR}/${MARKETPLACE_APP}/group_vars/linode/vars"
  sed 's/  //g' <<EOF > ${group_vars}

  # sudo username
  username: ${USER_NAME}
  default_dns: $(hostname -I | awk '{print $1}'| tr '.' '-' | awk {'print $1 ".ip.linodeusercontent.com"'})
  # BEGIN CI-UDF-ADDONS
  # addons
  add_ons: [${ADD_ONS}]
  # END CI-UDF-ADDONS  
EOF

  if [ "$DISABLE_ROOT" = "Yes" ]; then
    echo "disable_root: yes" >> ${group_vars};
  else echo "Leaving root login enabled";
  fi

  # staging or production mode (ci)
  if [[ "${MODE}" == "staging" ]]; then
    echo "[info] running in staging mode..."
    echo "mode: ${MODE}" >> ${group_vars}
  else
    echo "[info] running in production mode..."
    echo "mode: production" >> ${group_vars}
  fi  
}

function run {
  # install dependencies
  apt-get update
  apt-get install -y git python3 python3-pip

  # clone repo and set up ansible environment
  git -C /tmp clone --recurse-submodules -b ${BRANCH} ${GIT_REPO}

  # set up python virtual environment
  cd ${WORK_DIR}/${MARKETPLACE_APP}
  apt install python3-venv -y
  python3 -m venv env
  source env/bin/activate
  pip install pip --upgrade
  pip install -r requirements.txt
  ansible-galaxy install -r collections.yml

  # populate group_vars
  udf
  # run playbooks
  ansible-playbook -v provision.yml && ansible-playbook -v site.yml
}

function installation_complete {
  echo "Installation Complete"
}

# main
run
installation_complete
