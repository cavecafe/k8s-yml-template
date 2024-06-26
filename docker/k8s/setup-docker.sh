#!/bin/bash

function failed() {
   local error=${1:-Undefined error}
   echo "Failed: $error" >&2
   exit 1
}

templateType=""
function setTemplateType() {
    templateType=$1
    echo "templateType: $templateType"
}

templateDir=""
function setTemplateDir() {
    templateDir=$1
    echo "templateDir: $templateDir"
    mkdir -p "${templateDir}" || failed "failed to create template directory $templateDir"
}

env_path=""
function initEnvironment() {
  if [ -z "$1" ]; then
    env_file=".env"
    env_path=""
  else
    env_file=".env.$1"
    env_path="$1/"
  fi

  # Check if .env file exists
  if [ ! -f "$env_file" ]; then
    echo "No '$env_file' file found!"
    read -r -n 1 -p "Create '$env_file' file? (Press 'Y' to proceed)" confirm
    if [[ $confirm = "y" ]] || [[ $confirm = "Y" ]]; then
      touch "$env_file"
      echo "creating empty '$env_file' file, please refer to README.md to fill the values."
      cat <<EOF > "$env_file"
namespace=
project_name=
docker_username=
docker_password=
docker_email=
exposed_port=
target_port=
node_port=
host_name=
replicas=
image_repository=
image_tag=
run_as_user=
run_as_group=
memory_request=
cpu_request=
storage_capacity=
EOF
    else
      echo ""
      failed "confirmed do not to create '$env_file' file"
    fi
  fi
}

function addGitIgnore() {
   fileName=$1
   GITIGNORE=".gitignore"
   if [ -f "$GITIGNORE" ]; then
     echo "$GITIGNORE file exists"
   else
     echo "create $GITIGNORE for current directory"
     touch $GITIGNORE
   fi

   if grep -q "$fileName" "$GITIGNORE"; then
     echo "$fileName already exists in $GITIGNORE"
   else
     echo "$fileName" >> "$GITIGNORE"
     echo "$fileName entry to $GITIGNORE"
   fi
}

function downloadTemplate() {
   yml=${templateDir}/$1
   repo="https://raw.githubusercontent.com/cavecafe/k8s-template/main/${templateType}/k8s"
   if [ -f "$yml" ]; then
     echo "$yml exists"
   else
     echo "$yml does not exist, downloading from $repo/$yml"
     echo "curl -o $yml $repo/$yml"
     curl -o "$yml" "$repo/$yml"
   fi
}

function applyTemplateEnvironmentValues() {
  if [ -z "$1" ]; then
    env_file=".env"
  else
    env_file=".env.$1"
  fi

  # loop all *.yml files in the template directory
  for file in template/*.template.yml; do
    # Read YAML into a variable
    yaml=$(cat "$file")

    # search all keys in .env file and replace the placeholders
    while IFS= read -r line; do
      key=$(echo "$line" | cut -d'=' -f1)
      value=$(echo "$line" | cut -d'=' -f2)
      if [ -z "$value" ]; then
        echo "*** value for $key is empty, skipped"
        # check if yaml contains the key
        if [[ $yaml == *"$key"* ]]; then
          failed "*** value for $key is empty, please update '$env_file' file"
        fi
      else
        yaml=${yaml//\_\_\{$key\}\_\_/$value}
      fi
    done < "$env_file"

    # Write the output to a new file
    new_yml="${file//.template/}"
    new_yml="${new_yml//template\//}"

    if [ -z "$1" ]; then
      echo "$yaml" > "$new_yml"
      echo "created $new_yml"
    else
      echo "$yaml" > "$1/$new_yml"
      echo "created $1/$new_yml"
    fi

  done
}

function checkEnvironment() {
  if [ -z "$1" ]; then
    echo "ENV is empty, skip creating directory"
    env_file=".env"
  else
    mkdir -p "$1" || failed "failed to create $1 directory"
    env_file=".env.$1"
  fi

  # Fill the values of '$env_file' file
  while IFS= read -r line; do
    key=$(echo "$line" | cut -d'=' -f1)
    value=$(echo "$line" | cut -d'=' -f2)
    echo "key: '$key', value: '$value'"

    if [ -z "$value" ]; then
      echo "*** value for $key is empty, skipped"
    fi
  done < "$env_file"

  # Show the updated '$env_file' file
  echo ""
  echo "updated '$env_file' file:"
  echo ""
  while IFS= read -r line; do
    echo "$line"
  done < "$env_file"

  echo ""
  read -r -n 1 -p "write changes to $env_file? (Press 'Y' to proceed) " confirm
  if [[ $confirm = "y" ]] || [[ $confirm = "Y" ]]; then
    while IFS= read -r line; do
      echo "$line"
    done < "$env_file" > temp && mv temp "$env_file"
    echo "$env_file file updated!"
  else
    echo ""
    failed "confirmed not to update '$env_file' file"
  fi

  # get value of the key namespace from .env file
  NAMESPACE=$(grep namespace "$env_file" | cut -d'=' -f2)
  echo "Namespace: $NAMESPACE"
  if [ -z "$NAMESPACE" ]; then
    failed "namespace is empty, please update '$env_file' file"
  fi
}

function applyIngressController() {
  kubectl create namespace ingress-nginx
  latest_version=$(curl -s https://api.github.com/repos/kubernetes/ingress-nginx/releases/latest | grep "tag_name" | cut -d'"' -f4)
  cluster_version=$1
  echo "Latest version of ingress-nginx: $latest_version"
  echo "Cluster is using '$cluster_version', used it instead."
  echo "Installing ingress-nginx..."
  deploy_url="https://raw.githubusercontent.com/kubernetes/ingress-nginx/$cluster_version/deploy/static/provider/cloud/deploy.yaml"

  kubectl apply -f "$deploy_url" || failed "failed to apply ingress-nginx"
  echo "Waiting for ingress-nginx to be ready..."
  sleep 15
}


#### main entry
ENV=$1
echo "ENV: $ENV"

setTemplateType "docker"
setTemplateDir "template"

downloadTemplate namespace.template.yml
downloadTemplate network.template.yml
downloadTemplate secret.template.yml
downloadTemplate deployment.template.yml

initEnvironment "$ENV"
checkEnvironment "$ENV"
applyTemplateEnvironmentValues "$ENV"

addGitIgnore .env
addGitIgnore .env.*
addGitIgnore ${env_path}secret.yml
addGitIgnore .DS_Store

kubectl apply -f "${env_path}namespace.yml" || failed "failed to apply ${env_path}namespace.yml"
kubectl apply -f "${env_path}secret.yml" || failed "failed to apply ${env_path}secret.yml"

# (TODO) need to add the logic to find the installed version of ingress controller 'controller-v1.9.6'
CONTROLLER_VERSION=controller-v1.9.6
echo "CONTROLLER_VERSION: $CONTROLLER_VERSION"
applyIngressController $CONTROLLER_VERSION

kubectl apply -f "${env_path}network.yml" || failed "failed to apply ${env_path}network.yml"

# deployment.yml will be used to connected with CI/CD pipeline (i.e. GitHub Actions)
# kubectl apply -f "${env_path}deployment.yml || failed "failed to apply ${env_path}deployment.yml"
