# Run shell commands via Firecrest, e.g.
# firecrest_run_cmd echo \$\(hostname\): \"Hello world!\"
# INSIDE_CONTAINER=1 firecrest_run_cmd 'echo $(hostname): "Hello world!"'

function firecrest_run_cmd() {

    local script_name=$(mktemp run_cmd-XXXXXX.sh)

    cat > "$script_name" <<'OUTER_EOF'
#!/bin/bash

#SBATCH --job-name brainbert-cmd
#SBATCH --time 1:00:00
#SBATCH --output outputs/logs/%x-%j.out
#SBATCH --nodes 2
#SBATCH --ntasks-per-node 1
#SBATCH --gpus-per-node 4
##SBATCH -w nid007671

set -euxo pipefail

CMD=$(cat <<'INNER_EOF'
OUTER_EOF

    # Append command to script (escape quotation/$/() to be executed remotely)
    echo "$@" >> "$script_name"

    # close both inner and outer heredocs in the script
    cat >> "$script_name" <<'OUTER_EOF'
INNER_EOF
)

srun -ul ${INSIDE_CONTAINER:+--environment ./env/ngc-brainbert-25.06.toml} bash -c "$CMD"
OUTER_EOF

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
