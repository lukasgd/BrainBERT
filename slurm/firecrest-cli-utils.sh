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

function firecrest_batch_download() {

    for filename in "$@"; do
        mkdir -p "$(dirname $filename)"
        set -x
        firecrest --debug download \
            --account ${FIRECREST_ACCOUNT:?} \
            "${FIRECREST_WORKDIR:?}/$filename" $filename
        set +x

    done

}


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


# Run srun-like commands via Firecrest
# Examples:
# firecrest_run_cmd -N 2 -n 4 -- echo \$\(hostname\): \"Hello world!\"
# FIRECREST_USE_CONTAINER=1 firecrest_run_cmd --nodes 2 --ntasks-per-node 4 -- 'echo "Running nccl-tests on $(hostname)"; all_reduce_perf -b 8 -e 8G -f 2 -g 1 -c 1 -n 20 -w 5'

function firecrest_run_cmd() {

    local script_name=$(mktemp run_cmd-XXXXXX.sh)

    cat > "$script_name" <<'EOF'
#!/bin/bash -l

#SBATCH --job-name brainbert-cmd
#SBATCH --time 1:00:00
#SBATCH --output outputs/logs/%x-%j.out
#SBATCH --gpus-per-node 4
EOF

    while [[ "$#" -gt 1 ]]; do  # don't consume the command
        case $1 in
            --) shift; break ;;
            -*)
                # Add SBATCH parameters to the script
                # If the next argument doesn't start with --, it's a key-value pair
                if [[ "$2" != -* && -n "$2" && "$#" -gt 2 ]]; then
                    echo "#SBATCH $1 $2" >> "$script_name"

                    shift
                else
                    # flags without a value
                    echo "#SBATCH $1" >> "$script_name"
                fi
                ;;
            *) break ;;
        esac
        shift
    done

    cat >> "$script_name" <<'EOF'

set -euxo pipefail

srun -u \
EOF
    echo "${FIRECREST_USE_CONTAINER:+--environment ./env/ngc-brainbert-25.06.toml} \\" >> "$script_name"
    echo "$@" >> "$script_name"

    chmod u+x "$script_name"

    cat $script_name

    f7t_job=$(firecrest submit \
        --account ${FIRECREST_ACCOUNT:?} \
        --working-dir ${FIRECREST_WORKDIR:?}/BrainBERT \
        --env-var CE_IMAGES=${FIRECREST_WORKDIR:?}/ce-images \
        $script_name)

    firecrest_job_wait_and_extract_status "${f7t_job}"

    f7t_job_stdout_local=$(firecrest_job_download_stdout "${f7t_job_name}" "${f7t_job_id}")

    cat $f7t_job_stdout_local

    echo "--- stdout saved to ${f7t_job_stdout_local} ---"

    rm $script_name
}


# Override sbatch options in script
# Usage: firecrest_submit_sbatch_override [--sbatch-option value]... -- [firecrest-options]... <script>
# Example:
# firecrest_submit_sbatch_override --nodes 4 --time 24:00:00 -- --env-var CE_IMAGES=${FIRECREST_WORKDIR:?}/ce-images slurm/submit-train-prod.sh
firecrest_submit_sbatch_override() {
    local -a sbatch_args=()
    local -a firecrest_args=()

    # SBATCH options must be separated from firecrest options by --
    [[ " $* " == *" -- "* ]] || \
    { echo "Error: Missing '--' separator between sbatch and firecrest options" >&2; return 1; }

    # Parse SBATCH options
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        sbatch_args+=("${1#--}" "$2")
        shift 2
    done

    # Skip the -- separator
    [[ "$1" == "--" ]] && shift

    # Remaining args go to firecrest (options + script at the end)
    firecrest_args=("$@")

    local script="${firecrest_args[-1]}"
    [[ -n "$script" ]] || { echo "Error: No script specified" >&2; return 1; }
    [[ -f "$script" ]] || { echo "Error: Script '$script' not found" >&2; return 1; }

    local tmpscript
    tmpscript=$(mktemp --suffix=.sh)
    cp "$script" "$tmpscript"

    local i=0
    while [[ $i -lt ${#sbatch_args[@]} ]]; do
        local key="${sbatch_args[$i]}"
        local val="${sbatch_args[$((i+1))]}"
        if grep -q "^#SBATCH --${key}" "$tmpscript"; then  # override existing option
            sed -i "s|^#SBATCH --${key}.*|#SBATCH --${key} ${val}|" "$tmpscript"
        else  # add new option
            sed -i "/^#SBATCH/a #SBATCH --${key} ${val}" "$tmpscript"
        fi
        ((i+=2))
    done

    firecrest_args[-1]="$tmpscript"  # submit the modified script

    firecrest submit "${firecrest_args[@]}"
    local rc=$?
    rm -f "$tmpscript"
    return $rc
}
