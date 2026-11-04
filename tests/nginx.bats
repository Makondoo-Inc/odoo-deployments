#!/usr/bin/env bats
# Behaviour tests for nginx/autodeploy-nginx.sh: settings from a config file,
# --yes, --dry-run, piped answers, and the generated project. Hardware is
# pinned with ODOO_TUNE_CORES/ODOO_TUNE_RAM_MB so the expected numbers are
# stable on any machine (4 cores, 8 GB: 2 workers, db_maxconn 64).

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO/nginx/autodeploy-nginx.sh"

setup() {
    export ODOO_TUNE_CORES=4 ODOO_TUNE_RAM_MB=8192 TERM=dumb
    cd "$BATS_TEST_TMPDIR"
    cat > site.env <<'EOF'
PROJECT_NAME=auto
ODOO_EDITION=community
ODOO_VERSIONS=20
ADMIN_PASSWD=secret
BAKE_IMAGE=true
USE_NGINX=true
DOMAIN_MODE=custom
DOMAIN=odoo.example.com
PG_VERSION=18
USE_PGBOUNCER=false
TIMEZONE=UTC
EOF
}

@test "--dry-run prints the plan and creates nothing" {
    run bash "$SCRIPT" --config site.env --yes --dry-run < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"workers=2 per version"* ]]
    [[ "$output" == *"PROJECT_NAME=auto"* ]]
    [ ! -d auto ]
}

@test "config file + --yes generates the project without prompting" {
    run bash "$SCRIPT" --config site.env --yes < /dev/null
    [ "$status" -eq 0 ]
    [ -f auto/docker-compose.yml ]
    grep -q '^workers = 2$' auto/20-config/odoo.conf
    grep -q '^db_maxconn = 64$' auto/20-config/odoo.conf
    grep -q '^admin_passwd = secret$' auto/20-config/odoo.conf
    grep -q '^proxy_mode = True$' auto/20-config/odoo.conf
    grep -q '^FROM odoo:20.0$' auto/20-build/Dockerfile
    grep -q 'context: ./20-build' auto/docker-compose.yml
    grep -q 'TZ: UTC' auto/docker-compose.yml
    grep -q '^export TZ=UTC$' auto/20-config/entrypoint.sh
    grep -q 'server_name odoo.example.com;' auto/conf/nginx/conf.d/odoo.conf
    grep -q '^max_connections = 100$' auto/conf/postgresql/postgresql.conf
    [ ! -d auto/conf/pgbouncer ]
    [ -f auto/conf/tuning.sh ]
    [ -x auto/manage.sh ]
}

@test "an existing project directory is refused unless OVERWRITE=true" {
    mkdir auto
    run bash "$SCRIPT" --config site.env --yes < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"OVERWRITE=true"* ]]
    run env OVERWRITE=true bash "$SCRIPT" --config site.env --yes < /dev/null
    [ "$status" -eq 0 ]
    [ -f auto/docker-compose.yml ]
}

@test "environment variables work like the config file; --yes fills the rest with defaults" {
    run env PROJECT_NAME=envproj ODOO_VERSIONS=19 ADMIN_PASSWD=x bash "$SCRIPT" --yes < /dev/null
    [ "$status" -eq 0 ]
    [ -f envproj/19-config/odoo.conf ]
    # defaults: no nginx (direct ports), pgbouncer on, PG 18, community
    grep -q '"8072:8069"' envproj/docker-compose.yml   # host port = base + version - 16
    [ -f envproj/conf/pgbouncer/pgbouncer.ini ]
    grep -q 'image: postgres:18' envproj/docker-compose.yml
    grep -q '^proxy_mode = False$' envproj/19-config/odoo.conf
}

@test "piped answers still drive the interactive prompts" {
    run bash -c "printf '%s\n' piped 2 '18,19' pw 1 n 18069 17 n | bash '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ -f piped/18-config/odoo.conf ] && [ -f piped/19-config/odoo.conf ]
    [ -d piped/19-addons/enterprise ]
    grep -q 'image: postgres:17' piped/docker-compose.yml
    grep -q '"18071:8069"' piped/docker-compose.yml
    grep -q '"18072:8069"' piped/docker-compose.yml
    [ ! -f piped/conf/pgbouncer/pgbouncer.ini ]
}

@test "unsupported versions are rejected" {
    run env PROJECT_NAME=bad ODOO_VERSIONS=14 ADMIN_PASSWD=x bash "$SCRIPT" --yes < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"No valid versions"* ]]
    [ ! -d bad ]
}

@test "the generated performance tuner agrees with the deployed config" {
    bash "$SCRIPT" --config site.env --yes < /dev/null > /dev/null
    run bash auto/conf/performance-tuner.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"matches the current hardware recommendation"* ]]
    [ -f auto/performance-config.conf ]
}
