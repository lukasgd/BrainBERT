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
    f7t_job_id=$(echo $f7t_job | jq ".jobId")
    f7t_job_wait=$(firecrest wait-for-job $f7t_job_id)
    echo $f7t_job_wait

    # extract job name, exit state and code
    f7t_job_name=$(echo $f7t_job_wait |  jq -r ".[0].name")
    f7t_job_state=$(echo $f7t_job_wait |  jq -r ".[0].status.state")
    f7t_job_exit_code=$(echo $f7t_job_wait |  jq -r ".[0].status.exitCode")

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
    f7t_job_stdout=$(echo $f7t_job_metadata | jq -r ".[0].standardOutput" | sed -e "s/%x/${f7t_job_name}/" -e "s/%j/${f7t_job_id}/")

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

# TODO

# Repeatedly download stdout until it can extract the working directory

function firecrest_job_wait_workdir() {

    local f7t_job_stdout
    f7t_job_stdout=$(firecrest_job_stdout_path "$@")

    local f7t_job_stdout_local="BrainBERT/outputs/logs/$(basename "$f7t_job_stdout")"
    mkdir -p "$(dirname "$f7t_job_stdout_local")"

    declare -g train_workdir=""

    while true; do
        # Try to download the file; capture any error output
        if ! dl_err=$(firecrest download \
                --account "${FIRECREST_ACCOUNT:?}" \
                "$f7t_job_stdout" \
                "$f7t_job_stdout_local" 2>&1); then
            echo "Could not download '$f7t_job_stdout' yet. Will retry in 5s..."
            #TODO: make sure that the error is because file does not exist yet??
            # echo "    Error: $dl_err"
            sleep 5
            continue
        fi

        if [[ -s "$f7t_job_stdout_local" ]]; then
            # Prints the last whitespace-separated field, wont match file names
            # with spaces
            train_workdir=$(awk '/Working directory/ {print $NF; exit}' "$f7t_job_stdout_local")
        else
            train_workdir=""
        fi

        if [[ -n "$train_workdir" ]]; then
            echo "Found working directory: $train_workdir"
            break
        else
            echo "Working directory not found yet in '$f7t_job_stdout_local'. Retrying in 5s..."
            sleep 5
        fi
    done

    echo "$f7t_job_stdout_local"
}

# Continuously sync new/updated files from a FirecREST workdir.

function firecrest_sync_new_or_updated_files() {
    local train_workdir="${1:-$f7t_workdir}"

    if [[ -z "$train_workdir" ]]; then
        echo "ERROR: No train_workdir provided or found in \$f7t_workdir."
        return 1
    fi

    local local_dir="BrainBERT/outputs/$(basename "$train_workdir")"
    mkdir -p "$local_dir"

    # declare -gA f7t_tracked_mtime=()

    local state_file="$local_dir/.tracked_mtime.tsv"  # format: <name>\t<lastModified>
    [[ -f "$state_file" ]] || : > "$state_file"

    echo "Starting sync loop from '$train_workdir' -> '$local_dir'"

    while true; do
        local listing
        if ! listing=$(firecrest ls -a --recursive "$train_workdir" 2>&1); then
            echo "ERROR: firecrest ls failed for '$train_workdir': $listing"
            return 1
        fi

        # Iterate over all regular files
        while IFS=$'\t' read -r fname mtime; do
            [[ -z "$fname" || -z "$mtime" ]] && continue

            # local prev="${f7t_tracked_mtime[$fname]}"

            # echo "Found file: $fname (mtime: $mtime), previous mtime: $prev"

            # Lookup previous mtime from the state file (portable on macOS)
            local prev
            prev=$(awk -F '\t' -v f="$fname" '$1==f{print $2; exit}' "$state_file")

            local need_download=0
            local reason=""

            if [[ -z "$prev" ]]; then
                need_download=1
                reason="new"
            elif [[ "$mtime" != "$prev" ]]; then
                need_download=1
                reason="updated"
            fi

            if (( need_download )); then
                local remote_path="$train_workdir/$fname"
                local local_path="$local_dir/$fname"
                mkdir -p "$(dirname "$local_path")"

                echo "Attempting to download ($reason): $fname"
                if firecrest download \
                        --account "${FIRECREST_ACCOUNT:?}" \
                        "$remote_path" \
                        "$local_path"; then
                    echo "Downloaded ($reason): $fname"

                    # f7t_tracked_mtime["$fname"]="$mtime"

                    awk -F '\t' -v OFS='\t' -v f="$fname" -v m="$mtime" '
                        BEGIN{updated=0}
                        $1==f{ $2=m; updated=1 }
                        { print }
                        END{ if(!updated) print f, m }
                    ' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"

                else
                    echo "ERROR: Failed to download '$remote_path' -> '$local_path'"
                    echo "Skipping this file. Will not retry until lastModified changes."
                fi
            fi
        done < <(jq -r '.[] | select(.type == "-") | [.name, .lastModified] | @tsv' <<<"$listing")

        sleep 5
    done
}
