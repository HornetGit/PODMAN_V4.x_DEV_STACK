#!/bin/bash
# CREATED: 28MAY2025
# UPDATED: 21JUN2025
# OWNER: XCS HornetGit
# SETUP SCRIPT: Run from inside mini-app/ directory
# AUTO: launched from restart_application.sh
# PREREQUISITE: create a "dockeruser", as a podman rootless user and owner of the miniapp project dir

set -e

echo "SETTING UP containers and networks..."

# create miniapp directory structure if not existing
mkdir -p config backend backend/templates backend/app frontend frontend/templates pgadmin \
          traefik traefik/certs traefik/templates \
          logs db db/pgadmin db/templates instructions
echo "✅ Directories added"

# this code directory is the root of the miniapp
current_dir=$(pwd)
yaml_file="podman-compose-dev.yaml"

# check that this script directory is below any directory named version*** potentially on 2 digits and any chars after
# e.g. version01, version02, version03_arch etc.
if [[ ! "$current_dir" =~ /version[0-9]{1,2}.* ]]; then
    echo "❌ This script must be run from a directory below 'versionXX' (e.g. version01, version02, etc.)"
    exit 1
fi

# clean up files to be auto-generated from their templates
filename_list=(Dockerfile main.py db.py wait-for-db.sh nginx.conf index.html init.sql)
for filename in "${filename_list[@]}"; do
    find $current_dir -type f -name "$filename" -exec rm -f {} +
done

# check podman installation
if ! command -v podman &> /dev/null; then
    echo "❌ Podman is not installed. Please install Podman first."
    exit 1
fi

# check podman status
if ! podman info &> /dev/null; then
    echo "❌ Podman is not running. Please start Podman first."
    exit 1
fi

# check postgres repository
if ! podman search postgres &> /dev/null; then
    echo "❌ Postgres image not found in the available repositorie(s). Please check your Podman setup."
    echo "Hint: see .config/containers/registries.conf for the default registries to seek images"
    exit 1
fi

# check podman-compose installation
if ! command -v podman-compose &> /dev/null; then
    echo "❌ podman-compose is NOT installed. Please install podman-compose first (prefer from github)."
    exit 1
fi

echo "✅ Podman and podman-compose are installed and running."


# ####################
# ----- env file ----
# ####################
# Read env vars
source .env.dev

# ####################
# ----- backend -----
# ####################
# See : https://fastapi.tiangolo.com/bn/deployment/docker/#use-cmd-exec-form

# create an empty __init__.py file to make backend a package
touch backend/app/__init__.py

# create requirements.txt
cat > backend/requirements.txt <<'EOF'
fastapi
uvicorn[standard]
psycopg2-binary
EOF

# set db Dockerfile
sed \
  -e "s|%%POSTGRES_VERSION%%|${MINIAPP_SW_VERSION_TAG}|" \
  db/templates/Dockerfile.template > db/Dockerfile

# set db entrypoint.sh
cp db/templates/entrypoint.sh.template db/entrypoint.sh
chmod +x db/entrypoint.sh

# backend Dockerfile
sed \
  -e "s|%%BACKEND_PORT%%|${MINIAPP_BACKEND_PORT}|" \
  backend/templates/Dockerfile.template > backend/Dockerfile

# backend main.py
sed \
  -e "s|%%FRONTEND_DOMAIN%%|${MINIAPP_FRONTEND_DOMAIN}|g" \
  -e "s|%%API_DOMAIN%%|${MINIAPP_TRAEFIK_API_DOMAIN}|" \
  -e "s|%%FRONTEND_HTTPS%%|https://${MINIAPP_FRONTEND_DOMAIN}:${MINIAPP_TRAEFIK_HTTPS_PORT}|" \
  -e "s|%%API_HTTPS%%|https://${MINIAPP_TRAEFIK_API_DOMAIN}:${MINIAPP_TRAEFIK_HTTPS_PORT}|" \
  -e "s|%%TRAEFIK_HTTPS%%|https://traefik.${MINIAPP_FRONTEND_DOMAIN}:${MINIAPP_TRAEFIK_HTTPS_PORT}|" \
  -e "s|%%BACKENDPORT_ORIGIN%%|${MINIAPP_BACKEND_PORT}|" \
  backend/templates/main.py.template > backend/app/main.py

# db.py
# NOTE: MINIAPP_DB_HOST in .env.dev should better take the SAME name as its yml service 
sed \
  -e "s|%%DB_HOST%%|${MINIAPP_DB_HOST}|" \
  -e "s|%%DB_NAME%%|${MINIAPP_DB_NAME}|" \
  -e "s|%%DB_USER%%|${MINIAPP_DB_USER}|" \
  -e "s|%%DB_PASSWORD%%|${MINIAPP_DB_PASSWORD}|" \
  backend/templates/db.py.template > backend/app/db.py

# wait-for-db.sh (healthcheck)
sed \
  -e "s|%%DB_HOST%%|${MINIAPP_DB_HOST}|" \
  -e "s|%%DB_PORT%%|${MINIAPP_DB_PORT}|" \
  -e "s|%%DB_USER%%|${MINIAPP_DB_USER}|" \
  backend/templates/wait-for-db.sh.template > backend/wait-for-db.sh
chmod +x backend/wait-for-db.sh

# ####################
# ----- frontend -----
# ####################
# set index.html
sed \
  -e "s|%%BACKEND_API_URL_HTTPS%%|${MINIAPP_BACKEND_API_URL_TLS}|" \
  frontend/templates/index.html.template > frontend/index.html

# frontend/nginx.conf
cp frontend/templates/nginx.conf.template frontend/nginx.conf

# ###############
# ----- db -----
# ###############
# db/init.sql 
cat > db/init.sql <<'EOF'
CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  username TEXT UNIQUE NOT NULL,
  email TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS messages (
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES users(id),
  content TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
EOF


# ####################
# ----- Traefik -----
# ####################
# ----- Traefik service management -----
traefik_service_file="traefik/traefik-service.yaml"
if [ -f "$yaml_file" ]; then
    echo "✅ yaml_file found: $yaml_file"
else
    echo "❌ docker-compose file not found: $yaml_file"
    exit 1
fi

if [ "${MINIAPP_TRAEFIK_ENABLED}" = "true" ]; then
    echo "✅ Traefik enabled - processing service..."
    
    # create empty acme.json file (for TLS)
    touch traefik/acme.json
    chmod 600 traefik/acme.json

    # make sure the necessary templates exist
    if [ ! -f traefik/templates/traefik-service.yaml.template ]; then
        echo "❌ Traefik service template missing: traefik/templates/traefik-service.yaml.template"
        exit 1
    fi
    if [ ! -f traefik/templates/traefik.yml.template ]; then
        echo "❌ Traefik config template missing: traefik/templates/traefik.yml.template"
        exit 1
    fi
    if [ ! -f traefik/templates/traefik-service.yaml.template ]; then
        echo "❌ Traefik docker-compose template missing: traefik/templates/traefik-service.yaml.template"
        exit 1
    fi

  # enable traefik to use the podman user socket (rootless), and NOT the  docker socket (root)
    CURRENT_USER_ID=$(id -u)
    export MINIAPP_TRAEFIK_PODMAN_SOCK="/run/user/${CURRENT_USER_ID}/podman/podman.sock"
    if [ ! -S "$MINIAPP_TRAEFIK_PODMAN_SOCK" ]; then
        echo "❌ Podman user socket not found: $MINIAPP_TRAEFIK_PODMAN_SOCK"
        echo "Please make sure Podman is running and the user socket is available."
        exit 1
    fi
    echo "✅ Podman user socket found: $MINIAPP_TRAEFIK_PODMAN_SOCK"

    # generate the traefik-service.yaml from its template
    echo "Generating Traefik service file from template..."
    sed \
        -e "s|%%MINIAPP_TRAEFIK_HTTP_PORT%%|${MINIAPP_TRAEFIK_HTTP_PORT}|g" \
        -e "s|%%MINIAPP_TRAEFIK_HTTPS_PORT%%|${MINIAPP_TRAEFIK_HTTPS_PORT}|g" \
        -e "s|%%MINIAPP_TRAEFIK_DASHBOARD_PORT%%|${MINIAPP_TRAEFIK_DASHBOARD_PORT}|g" \
        -e "s|%%MINIAPP_TRAEFIK_PODMAN_SOCK%%|${MINIAPP_TRAEFIK_PODMAN_SOCK}|g" \
        traefik/templates/traefik-service.yaml.template > "$traefik_service_file"
    
    if [ ! -f "$traefik_service_file" ]; then
        echo "❌ Failed to generate $traefik_service_file"
        exit 1
    fi
    
    # Remove existing traefik service block from the podman-compose file if it exists
    # using awk to remove from 'traefik:' line to the next service or end of services section
    awk '
    BEGIN { in_services = 0; in_traefik = 0; skip_traefik = 0 }
    /^services:/ { in_services = 1; print; next }
    /^[a-zA-Z]/ && in_services && !/^  / { in_services = 0 }
    in_services && /^  traefik:/ { 
        in_traefik = 1; 
        skip_traefik = 1; 
        next 
    }
    in_services && in_traefik && /^  [a-zA-Z]/ && !/^    / { 
        in_traefik = 0; 
        skip_traefik = 0 
    }
    !skip_traefik { print }
    ' "$yaml_file" > "${yaml_file}.tmp"
    
    # Insert traefik service as the first service block after "services:" line
    awk -v traefik_file="$traefik_service_file" '
    /^services:/ { 
        print
        print ""
        # Read and insert traefik service with proper indentation
        while ((getline line < traefik_file) > 0) {
            if (line ~ /^[a-zA-Z]/) {
                # Service name line - add 2 spaces indentation
                print "  " line
            } else if (line ~ /^[[:space:]]/) {
                # Already indented lines - add 2 more spaces
                print "  " line
            } else if (line == "") {
                # Empty lines
                print line
            } else {
                # Other lines - add 2 spaces indentation
                print "  " line
            }
        }
        close(traefik_file)
        next
    }
    { print }
    ' "${yaml_file}.tmp" > "$yaml_file"

    # Clean up temporary file
    [ -f "${yaml_file}.tmp" ] && rm -f "${yaml_file}.tmp"
    
    echo "✅ Traefik service upserted as first service in $yaml_file"
    echo "📝 Note: Please manually check other service labels for Traefik routing if needed"
    
    # add the dynamic.yml (mounted in the compose file as a read-only volume)
    [ -f traefik/templates/dynamic.yml.template ] && cp traefik/templates/dynamic.yml.template traefik/dynamic.yml

    # set the config file for traefik (mounted as a r-o volume)
    sed \
      -e "s|%%TRAEFIK_HTTP_PORT%%|${MINIAPP_TRAEFIK_HTTP_PORT}|" \
      -e "s|%%TRAEFIK_HTTPS_PORT%%|${MINIAPP_TRAEFIK_HTTPS_PORT}|" \
      traefik/templates/traefik.yml.template > traefik/traefik.yml
      echo "✅ Traefik config file set to traefik/traefik.yml (mounted in the podman-compose file)"

else
    echo "🚫 Traefik disabled - removing service and files..."
    
    # Remove traefik service block from compose file
    awk '
    BEGIN { in_services = 0; in_traefik = 0; skip_traefik = 0 }
    /^services:/ { in_services = 1; print; next }
    /^[a-zA-Z]/ && in_services && !/^  / { in_services = 0 }
    in_services && /^  traefik:/ { 
        in_traefik = 1; 
        skip_traefik = 1; 
        next 
    }
    in_services && in_traefik && /^  [a-zA-Z]/ && !/^    / { 
        in_traefik = 0; 
        skip_traefik = 0 
    }
    !skip_traefik { print }
    ' "$yaml_file" > "${yaml_file}.tmp" && mv "${yaml_file}.tmp" "$yaml_file"
    
    # Remove generated traefik service file
    [ -f "$traefik_service_file" ] && rm -f "$traefik_service_file"
    [ -f traefik/traefik.yml ] && rm -f traefik/traefik.yml
    [ -f traefik/acme.json ] && rm -f traefik/acme.json
    [ -f traefik/dynamic.yml ] && rm traefik/dynamic.yml


    echo "✅ Traefik service and related files removed from $yaml_file"
fi

# ######################################
# ----- pgAdmin service management -----
# ######################################

if grep -q 'MINIAPP_PGADMIN_ENABLED=true' .env.dev; then
  echo "✅ pgAdmin service: enabled by .env.dev setup"

  # copy the service template to the pgadmin directory
  # no need to substitute environment variables in the pgadmin service template
  cp pgadmin/templates/pgadmin-service.yaml.template pgadmin/pgadmin-service.yaml
  
  # Remove existing pgadmin block if already present (for applying update if any)
  awk '
    BEGIN { skip=0 }
    /^  pgadmin:/ { skip=1 }
    skip && /^[^[:space:]]/ { skip=0 }
    !skip { print }
  ' podman-compose-dev.yaml > podman-compose-dev.yaml.tmp && mv podman-compose-dev.yaml.tmp podman-compose-dev.yaml

  # Re-insert updated pgadmin block before the "volumes:" section
  awk '
    /^volumes:/ {
      while ((getline line < "pgadmin/pgadmin-service.yaml") > 0) print line;
      close("pgadmin/pgadmin-service.yaml");
      print "";  # optional spacing
    }
    { print }
  ' podman-compose-dev.yaml > podman-compose-dev.yaml.tmp && mv podman-compose-dev.yaml.tmp podman-compose-dev.yaml


  # Declare/add the persistent volume even if commented
  if ! grep -Eq '^[[:space:]]*pgadmin_data:' podman-compose-dev.yaml; then
    sed -i '/^volumes:/a \ \ pgadmin_data:' podman-compose-dev.yaml
  fi


else
  echo "🚫 pgAdmin is disabled - removing from compose and related files"

  cp podman-compose-dev.yaml podman-compose-dev.yaml.bak

  awk '
    BEGIN { in_block = 0 }
    /^  pgadmin:/ { in_block = 1; next }
    /^[^[:space:]]/ && in_block { in_block = 0 }
    !in_block { print }
  ' podman-compose-dev.yaml.bak > podman-compose-dev.yaml

  sed -i '/pgadmin_data:/d' podman-compose-dev.yaml
  [ -f podman-compose-dev.yaml.bak ] && rm -f podman-compose-dev.yaml.bak
  [ -f pgadmin/pgadmin-service.yaml ] && rm -f pgadmin/pgadmin-service.yaml

  echo "✅ pgAdmin service and related files removed from podman-compose-dev.yaml"
fi


if [ -f "$yaml_file" ]; then
    echo "✅ yaml_file found: $yaml_file"
else
    echo "❌ docker-compose file not found"
    exit 1
fi

chmod 644 "$yaml_file"
if [ "$(id -u)" -eq 0 ]; then
    chown dockeruser:dockeruser "$yaml_file"
else
    echo "⚠️  Skipping chown: not running as root. If needed, run 'sudo chown dockeruser:dockeruser $yaml_file'"
fi


# #######################
# setup_certificates.sh
# #######################
echo "⚠️  NOTES about TLS self-certificates:"
echo "set local certs: see  'setup_certificates.sh'" 
echo "Firefox: if getting an https cert warning, adjust: 'about:preferences#privacy', 'Certificates', 'View Certificates', 'Authorities', 'Import'"

# ##########
# Clean exit
# ##########
echo "✅ All files successfully generated. Ready to run: podman-compose --env-file $env_dev -f $yaml_file up -d --build"
echo "✅ or to reset 1 specific container: podman-compose --env-file $env_dev -f $yaml_file up -d --build the_specific_yaml_SERVICE_NAME"