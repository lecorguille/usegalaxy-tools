#!/usr/bin/env bash
set -euo pipefail

# Set this variable to 'true' to publish on successful installation
: ${PUBLISH:=false}

LOCAL_PORT=8080
REMOTE_PORT=8080
GALAXY_URL="http://127.0.0.1:${LOCAL_PORT}"
REMOTE_WORKDIR='.local/share/usegalaxy-tools'
SSH_MASTER_SOCKET_DIR="${HOME}/.cache/usegalaxy-tools"

GALAXY_DOCKER_IMAGE='galaxy/galaxy:19.05'
GALAXY_TEMPLATE_DB_URL='https://depot.galaxyproject.org/nate/galaxy-153.sqlite'
GALAXY_TEMPLATE_DB="${GALAXY_TEMPLATE_DB_URL##*/}"

# Should be set by Jenkins, so the default here is for development
: ${GIT_COMMIT:=$(git rev-parse HEAD)}

TOOL_YAMLS=()
REPO_USER=
REPO_STRATUM0=
CONDA_PATH=
INSTALL_DATABASE=
SHED_TOOL_CONFIG=
SHED_TOOL_DATA_TABLE_CONFIG=
SSH_MASTER_SOCKET=
GALAXY_TMPDIR=
OVERLAYFS_UPPER=
OVERLAYFS_LOWER=

SSH_MASTER_UP=false
CVMFS_TRANSACTION_UP=false
GALAXY_UP=false


function trap_handler() {
    { set +x; } 2>/dev/null
    $GALAXY_UP && stop_galaxy
    $CVMFS_TRANSACTION_UP && abort_transaction
    $SSH_MASTER_UP && stop_ssh_control
    return 0
}
trap "trap_handler" SIGTERM SIGINT ERR EXIT


function log() {
    echo "#" "$@"
}


function log_error() {
    log "ERROR:" "$@"
}


function log_debug() {
    echo "####" "$@"
}


function log_exec() {
    local rc
    set -x
    "$@"
    { rc=$?; set +x; } 2>/dev/null
    return $rc
}


function log_exit_error() {
    log_error "$@"
    exit 1
}


function log_exit() {
    echo "$@"
    exit 0
}


function exec_on() {
    log_exec ssh -S "$SSH_MASTER_SOCKET" -l "$REPO_USER" "$REPO_STRATUM0" -- "$@"
}


function copy_to() {
    local file="$1"
    exec_on mkdir -p "$REMOTE_WORKDIR"
    log_exec scp -o "ControlPath=$SSH_MASTER_SOCKET" "$file" "${REPO_USER}@${REPO_STRATUM0}:${REMOTE_WORKDIR}/${file##*/}"
}


function check_bot_command() {
    log 'Checking for Github PR Bot commands'
    log_debug "Value of \$ghprbCommentBody is: ${ghprbCommentBody:-UNSET}"
    case "${ghprbCommentBody:-UNSET}" in
        "@galaxybot deploy"*)
            PUBLISH=true
            ;;
    esac
    $PUBLISH && log_debug "Changes will be published" || log_debug "Test installation, changes will be discarded"
}


function load_repo_configs() {
    log 'Loading repository configs'
    . ./.ci/repos.conf
}


function detect_changes() {
    log 'Detecting changes to tool files...'
    log_exec git remote set-branches --add origin master
    log_exec git fetch origin
    COMMIT_RANGE=origin/master...

    log 'Change detection limited to toolset directories:'
    for d in "${!TOOLSET_REPOS[@]}"; do
        echo "${d}/"
    done

    TOOLSET= ;
    while read op path; do
        if [ -n "$TOOLSET" -a "$TOOLSET" != "${path%%/*}" ]; then
            log_exit_error "Changes to tools in multiple toolsets found: ${TOOLSET} != ${path%%/*}"
        elif [ -z "$TOOLSET" ]; then
            TOOLSET="${path%%/*}"
        fi
        case "${path##*.}" in
            lock)
                ;;
            *)
                continue
                ;;
        esac
        case "$op" in
            A|M)
                echo "$op $path"
                TOOL_YAMLS+=("${path}")
                ;;
        esac
    done < <(git diff --color=never --name-status "$COMMIT_RANGE" -- $(for d in "${!TOOLSET_REPOS[@]}"; do echo "${d}/"; done))

    log 'Change detection results:'
    declare -p TOOLSET TOOL_YAMLS

    [ ${#TOOL_YAMLS[@]} -gt 0 ] || log_exit 'No tool changes, terminating'

    log "Getting repo for toolset: ${TOOLSET}"
    # set -u will force exit here if $TOOLSET is invalid
    REPO="${TOOLSET_REPOS[$TOOLSET]}"
    declare -p REPO
}


function set_repo_vars() {
    REPO_USER="${REPO_USERS[$REPO]}"
    REPO_STRATUM0="${REPO_STRATUM0S[$REPO]}"
    CONDA_PATH="${CONDA_PATHS[$REPO]}"
    INSTALL_DATABASE="${INSTALL_DATABASES[$REPO]}"
    SHED_TOOL_CONFIG="${SHED_TOOL_CONFIGS[$REPO]}"
    SHED_TOOL_DIR="${SHED_TOOL_DIRS[$REPO]}"
    SHED_TOOL_DATA_TABLE_CONFIG="${SHED_TOOL_DATA_TABLE_CONFIGS[$REPO]}"
    CONTAINER_NAME="galaxy-${REPO_USER}"
    OVERLAYFS_UPPER="/var/spool/cvmfs/${REPO}/scratch/current"
    OVERLAYFS_LOWER="/var/spool/cvmfs/${REPO}/rdonly"
}


function setup_ephemeris() {
    log "Setting up Ephemeris"
    log_exec python3 -m venv ephemeris
    . ./ephemeris/bin/activate
    log_exec pip install --index-url https://wheels.galaxyproject.org/simple/ --extra-index-url https://pypi.org/simple/ "${EPHEMERIS:=ephemeris}" #"${PLANEMO:=planemo}"
}


function start_ssh_control() {
    log "Starting SSH control connection to Stratum 0"
    SSH_MASTER_SOCKET="${SSH_MASTER_SOCKET_DIR}/ssh-tunnel-${REPO_USER}-${REPO_STRATUM0}.sock"
    log_exec mkdir -p "$SSH_MASTER_SOCKET_DIR"
    log_exec ssh -S "$SSH_MASTER_SOCKET" -M -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" -Nfn -l "$REPO_USER" "$REPO_STRATUM0"
    SSH_MASTER_UP=true
}


function stop_ssh_control() {
    log "Stopping SSH control connection to Stratum 0"
    log_exec ssh -S "$SSH_MASTER_SOCKET" -O exit -l "$REPO_USER" "$REPO_STRATUM0"
    rm -f "$SSH_MASTER_SOCKET"
    SSH_MASTER_UP=false
}


function begin_transaction() {
    log "Opening transaction on $REPO"
    exec_on cvmfs_server transaction "$REPO"
    CVMFS_TRANSACTION_UP=true
}


function abort_transaction() {
    log "Aborting transaction on $REPO"
    exec_on cvmfs_server abort -f "$REPO"
    CVMFS_TRANSACTION_UP=false
}


function publish_transaction() {
    log "Publishing transaction on $REPO"
    exec_on "cvmfs_server publish -a 'tools-${GIT_COMMIT:0:7}' -m 'Automated tool installation for commit ${GIT_COMMIT}' ${REPO}"
    CVMFS_TRANSACTION_UP=false
}


function run_cloudve_galaxy() {
    log "Copying configs to Stratum 0"
    log_exec curl -o ".ci/${GALAXY_TEMPLATE_DB}" "$GALAXY_TEMPLATE_DB_URL"
    copy_to ".ci/${GALAXY_TEMPLATE_DB}"
    log "Fetching latest Galaxy image"
    exec_on docker pull "$GALAXY_DOCKER_IMAGE"
    log "Updating database"
    exec_on docker run --rm --user '$(id -u)' --name="${CONTAINER_NAME}-setup" \
        -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////${GALAXY_TEMPLATE_DB}" \
        -v "\$(pwd)/${REMOTE_WORKDIR}/${GALAXY_TEMPLATE_DB}:/${GALAXY_TEMPLATE_DB}" \
        "$GALAXY_DOCKER_IMAGE" ./.venv/bin/python ./scripts/manage_db.py upgrade
    log "Starting Galaxy on Stratum 0"
    GALAXY_TMPDIR=$(exec_on mktemp -d -t usegalaxy-tools.XXXXXX)
    exec_on docker run -d -p 127.0.0.1:${REMOTE_PORT}:8080 --user '$(id -u)' --name="${CONTAINER_NAME}" \
        -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////${GALAXY_TEMPLATE_DB}" \
        -e "GALAXY_CONFIG_OVERRIDE_INTEGRATED_TOOL_PANEL_CONFIG=/tmp/integrated_tool_panel.xml" \
        -e "GALAXY_CONFIG_OVERRIDE_TOOL_CONFIG_FILE=${SHED_TOOL_CONFIG}" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_TOOL_DATA_TABLE_CONFIG=${SHED_TOOL_DATA_TABLE_CONFIG}" \
        -e "GALAXY_CONFIG_TOOL_DATA_PATH=/tmp/tool-data" \
        -e "GALAXY_CONFIG_INSTALL_DATABASE_CONNECTION=sqlite:///${INSTALL_DATABASE}" \
        -e "GALAXY_CONFIG_MASTER_API_KEY=${API_KEY:=deadbeef}" \
        -e "GALAXY_CONFIG_CONDA_PREFIX=${CONDA_PATH}" \
        -e "CONDARC=${CONDA_PATH}rc" \
        -v "\$(pwd)/${REMOTE_WORKDIR}/${GALAXY_TEMPLATE_DB}:/${GALAXY_TEMPLATE_DB}" \
        -v "/cvmfs/${REPO}:/cvmfs/${REPO}" \
        -v "${GALAXY_TMPDIR}:/galaxy/server/database" \
        "$GALAXY_DOCKER_IMAGE" ./.venv/bin/uwsgi --yaml config/galaxy.yml
    GALAXY_UP=true
}


function run_bgruening_galaxy() {
    log "Copying configs to Stratum 0"
    copy_to ".ci/job_conf.xml"
    copy_to ".ci/nginx.conf"
    log "Fetching latest Galaxy image"
    exec_on docker pull "$GALAXY_DOCKER_IMAGE"
    log "Starting Galaxy on Stratum 0"
    exec_on docker run -d -p 127.0.0.1:${REMOTE_PORT}:80 --name="${CONTAINER_NAME}" \
        -e "GALAXY_CONFIG_INSTALL_DATABASE_CONNECTION=sqlite:///${INSTALL_DATABASE}" \
        -e "GALAXY_CONFIG_TOOL_CONFIG_FILE=${SHED_TOOL_CONFIG}" \
        -e "GALAXY_CONFIG_MASTER_API_KEY=${API_KEY:=deadbeef}" \
        -e "GALAXY_CONFIG_CONDA_PREFIX=${CONDA_PATH}" \
        -e "GALAXY_HANDLER_NUMPROCS=0" \
        -e "CONDARC=${CONDA_PATH}rc" \
        -v "/cvmfs/${REPO}:/cvmfs/${REPO}" \
        -v "\$(pwd)/${REMOTE_WORKDIR}/job_conf.xml:/job_conf.xml" \
        -v "\$(pwd)/${REMOTE_WORKDIR}/nginx.conf:/etc/nginx/nginx.conf" \
        -e "GALAXY_CONFIG_JOB_CONFIG_FILE=/job_conf.xml" \
        "$GALAXY_DOCKER_IMAGE"
    GALAXY_UP=true
}


function run_galaxy() {
    case "$GALAXY_DOCKER_IMAGE" in
        galaxy/galaxy*)
            run_cloudve_galaxy
            ;;
        bgruening/galaxy-stable*)
            run_bgruening_galaxy
            ;;
        *)
            log_exit_error "Unknown Galaxy Docker image: ${GALAXY_DOCKER_IMAGE}"
            ;;
    esac
}


function stop_galaxy() {
    log "Stopping Galaxy on Stratum 0"
    exec_on docker kill "$CONTAINER_NAME" || true  # probably failed to start, don't prevent the rest of cleanup
    exec_on docker rm -v "$CONTAINER_NAME"
    [ -n "$GALAXY_TMPDIR" ] && exec_on rm -rf "$GALAXY_TMPDIR"
    GALAXY_UP=false
}


function wait_for_galaxy() {
    log "Waiting for Galaxy connection"
    log_exec galaxy-wait -v -g "$GALAXY_URL" --timeout 120 || {
        log_error "Timed out waiting for Galaxy"
        log_debug "contents of docker log";
        exec_on docker logs "$CONTAINER_NAME"
        # bgruening log paths
        #for f in /var/log/nginx/error.log /home/galaxy/logs/uwsgi.log; do
        #    log_debug "contents of ${f}";
        #    exec_on docker exec "$CONTAINER_NAME" cat $f;
        #done
        log_debug "response from ${GALAXY_URL}";
        curl "$GALAXY_URL";
        log_exit_error "Terminating build due to previous errors"
    }
}


function show_logs() {
    local lines
    if [ -n "$1" ]; then
        lines="--tail ${1}"
        log_debug "tail ${lines} of server log";
    else
        log_debug "contents of server log";
    fi
    exec_on docker logs $lines "$CONTAINER_NAME"
    # bgruening log paths
    #for f in /var/log/nginx/error.log /var/log/nginx/access.log /home/galaxy/logs/uwsgi.log; do
    #    log_debug "tail of ${f}";
    #    exec_on docker exec "$CONTAINER_NAME" tail -500 $f;
    #done;
}


function show_paths() {
    log_debug "contents of \$GALAXY_TMPDIR (will be discarded)"
    exec_on ls -lR "$GALAXY_TMPDIR"
    log_debug "contents of OverlayFS upper mount (will be published)"
    exec_on ls -lR "$OVERLAYFS_UPPER"
}


function install_tools() {
    local tool_yaml
    log "Installing tools"
    for tool_yaml in "${TOOL_YAMLS[@]}"; do
        log "Installing tools in ${tool_yaml}"
        log_exec shed-tools install -v -g "$GALAXY_URL" -a "$API_KEY" -t "$tool_yaml" || {
            log_error "Tool installation failed"
            show_logs
            show_paths
            log_exit_error "Terminating build due to previous errors"
        }
        #shed-tools install -v -a deadbeef -t "$tool_yaml" --test --test_json "${tool_yaml##*/}"-test.json || {
        #    # TODO: test here if test failures should be ignored (but we can't separate test failures from install
        #    # failures at the moment) and also we can't easily get the job stderr
        #    [ "$TRAVIS_PULL_REQUEST" == "false" -a "$TRAVIS_BRANCH" == "master" ] || {
        #        log_error "Tool install/test failed";
        #        show_logs
        #        show_paths
        #        log_exit_error "Terminating build due to previous errors"
        #    };
        #}
    done
}



function check_for_repo_changes() {
    local stc="${SHED_TOOL_CONFIG%,*}"
    log "Checking for changes to repo"
    show_paths
    log_debug "diff of shed_tool_conf.xml"
    exec_on diff -u "${OVERLAYFS_LOWER}${stc##*${REPO}}" "$stc" || true
    log_debug "diff of shed_tool_data_table_conf.xml"
    exec_on diff -u "${OVERLAYFS_LOWER}${SHED_TOOL_DATA_TABLE_CONFIG##*${REPO}}" "$SHED_TOOL_DATA_TABLE_CONFIG" || true
    exec_on "[ -d '${OVERLAYFS_UPPER}${CONDA_PATH##*${REPO}}' -o -d '${OVERLAYFS_UPPER}${SHED_TOOL_DIR##*${REPO}}' ]" || {
        log_error "Tool installation failed";
        show_logs
        log_exit_error "Terminating build: expected changes to ${OVERLAYFS_UPPER} not found!";
    }
}


function post_install() {
    log "Running post-installation tasks"
    exec_on "find '$OVERLAYFS_UPPER' -perm -u+r -not -perm -o+r -not -type l -print0 | xargs -0 --no-run-if-empty chmod go+r"
    exec_on "find '$OVERLAYFS_UPPER' -perm -u+rx -not -perm -o+rx -not -type l -print0 | xargs -0 --no-run-if-empty chmod go+rx"
    exec_on ${CONDA_PATH}/bin/conda clean --tarballs --yes
    # we're fixing the links for everything here not just the new stuff in $OVERLAYFS_UPPER
    exec_on "for env in '${CONDA_PATH}/envs/'*; do for link in conda activate deactivate; do [ -h "\${env}/bin/\${link}" ] || ln -s '${CONDA_PATH}/bin/'"\${link}" "\${env}/bin/\${link}"; done; done"
}


function main() {
    check_bot_command
    load_repo_configs
    detect_changes
    set_repo_vars
    setup_ephemeris
    start_ssh_control
    begin_transaction
    run_galaxy
    wait_for_galaxy
    install_tools
    check_for_repo_changes
    stop_galaxy
    post_install
    $PUBLISH && publish_transaction || abort_transaction
    stop_ssh_control
    return 0
}


main
