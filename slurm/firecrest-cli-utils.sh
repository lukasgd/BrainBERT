# Firecrest utility functions for job submission, monitoring and data transfer

# Function to wait for job completion and extract status

function firecrest_job_wait_and_extract_status() {
    local f7t_job="$1"
    echo $f7t_job

    # global variables
    declare -g f7t_job_id
    declare -g f7t_job_name
    declare -g f7t_job_state
    declare -g f7t_job_exit_code

    # wait for job to complete
    f7t_job_id=$(echo $f7t_job | jq .jobId)
    f7t_job_wait=$(firecrest wait-for-job $f7t_job_id)
    echo $f7t_job_wait

    # extract job name, exit state and code
    f7t_job_name=$(echo $f7t_job_wait |  jq -r .[0].name)
    f7t_job_state=$(echo $f7t_job_wait |  jq -r .[0].status.state)
    f7t_job_exit_code=$(echo $f7t_job_wait |  jq -r .[0].status.exitCode)

    # alternatively: echo $f7t_job_wait | jq -e '.[0].status.exitCode != "0"'
    if [[ "${f7t_job_state}" != "COMPLETED" || "${f7t_job_exit_code}" -ne 0 ]]; then
        echo "ERROR: job ${f7t_job_name} (${f7t_job_id}) did not succeed."
        echo "Exit state ${f7t_job_state} and exit code ${f7t_job_exit_code}"
    else
        echo "SUCCESS: job ${f7t_job_name} (${f7t_job_id}) completed successfully."
    fi

    return ${f7t_job_exit_code}
}

# Functions to get, tail and download job stdout

function firecrest_job_stdout_path() {

    local f7t_job_name=${1:-$f7t_job_name}
    local f7t_job_id=${2:-$f7t_job_id}

    declare -g f7t_job_stdout

    local f7t_job_metadata=$(firecrest job-metadata $f7t_job_id)
    f7t_job_stdout=$(echo $f7t_job_metadata | jq -r .[0].standardOutput | sed -e "s/%x/${f7t_job_name}/" -e "s/%j/${f7t_job_id}/")

    echo $f7t_job_stdout
}

function firecrest_job_tail_stdout() {

    local f7t_job_stdout=$(firecrest_job_stdout_path "$@")

    while true; do
        firecrest tail --lines 100 \
            "$f7t_job_stdout"
        sleep 3
    done
}

function firecrest_job_download_stdout() {

    local f7t_job_stdout=$(firecrest_job_stdout_path "$@")
    local f7t_job_stdout_local="BrainBERT/outputs/logs/$(basename "$f7t_job_stdout")"

    mkdir -p $(dirname $f7t_job_stdout_local)

    firecrest download \
        --account ${FIRECREST_ACCOUNT:?} \
        "$f7t_job_stdout" \
        "$f7t_job_stdout_local"

    echo "$f7t_job_stdout_local"
}

#  Batch upload/download functions

function firecrest_batch_upload() {

    for filename in "$@"; do
        remote_dirname="${FIRECREST_WORKDIR:?}/$(dirname $filename)"
        firecrest mkdir -p \
            ${remote_dirname}
        set -x
        firecrest --debug upload \
            --account ${FIRECREST_ACCOUNT:?} \
            $filename ${remote_dirname} $(basename $filename)
        set +x

        if [[ "${filename}" == *.sh ]]; then
            set -x
            firecrest chmod \
                "${remote_dirname}/$(basename ${filename})" +x
            set +x
        fi

    done

}

# Batch download function not yet implemented (needs list of files)