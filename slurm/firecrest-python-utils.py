import firecrest as f7t
import os
import sys
import tarfile
import tempfile
import time


def download_mlruns(
    client,
    system_name,
    training_workdir,
    firecrest_account,
):
    mlruns_dir = os.path.join(training_workdir, "BrainBERT", "outputs", "mlruns")
    mlruns_zip_path = mlruns_dir + ".zip"
    local_zip_path = os.path.join(os.getcwd(), "mlruns.tar.gz")
    local_output_path = os.path.join(os.getcwd(), "BrainBERT", "outputs")

    for _ in range(20):
        print(f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}: "
              f"Syncing directory `{mlruns_dir}` to `{local_output_path}`...")
        num_attempts = 3
        for attempt in range(num_attempts):
            try:
                client.compress(
                    system_name=system_name,
                    source_path=mlruns_dir,
                    target_path=mlruns_zip_path,
                    account=firecrest_account,
                    blocking=True,
                )
            except f7t.FirecrestException as e:
                # We try a few times since compression can fail with error:
                # `Remote process failed with exit status:1 and error message:tar: <file_name>:
                # file changed as we read it`
                if attempt == num_attempts - 1:
                    raise e

                print(f"Compression attempt failed with error: {e}. Retrying...")
                time.sleep(5)

        # print(f"Compressed {mlruns_dir} to {mlruns_zip_path}")
        client.download(
            system_name=system_name,
            source_path=mlruns_zip_path,
            target_path=local_zip_path,
            account=firecrest_account,
            blocking=True,
        )
        # print(f"Downloaded {mlruns_zip_path} to {local_zip_path}")
        with tarfile.open(local_zip_path, "r:gz") as tar:
            tar.extractall(path=local_output_path)

        # print(f"Extracted {local_zip_path} to {local_output_path}")

        # print("Deleting local and remote zip files...")
        os.remove(local_zip_path)
        client.rm(
            system_name=system_name,
            path=mlruns_zip_path,
            account=firecrest_account,
            blocking=True,
        )

        print(f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}: Sync complete.")
        time.sleep(5)


def _read_last_push_timestamp(local_directory):
    marker_path = os.path.join(local_directory, ".firecrest_last_push")
    try:
        with open(marker_path, "r", encoding="utf-8") as f:
            return float(f.read().strip())
    except (FileNotFoundError, ValueError):
        return 0.0


def _write_last_push_timestamp(local_directory, ts=None):
    if ts is None:
        ts = time.time()
    marker_path = os.path.join(local_directory, ".firecrest_last_push")
    with open(marker_path, "w", encoding="utf-8") as f:
        f.write(str(ts))


def _collect_new_or_updated_files(local_directory, since_ts):
    local_directory = os.path.abspath(local_directory)
    marker_path = os.path.join(local_directory, ".firecrest_last_push")

    new_files = []
    for root, _dirs, files in os.walk(local_directory):
        for name in files:
            abs_path = os.path.join(root, name)

            # Skip the marker itself
            if abs_path == marker_path:
                continue

            try:
                mtime = os.path.getmtime(abs_path)
            except FileNotFoundError:
                # File disappeared between walk and stat; just skip it.
                continue

            if mtime <= since_ts:
                continue

            rel_path = os.path.relpath(abs_path, start=local_directory)
            new_files.append((abs_path, rel_path))

    return new_files


def firecrest_push_new_or_updated_files(
    client,
    system_name,
    local_directory,
    remote_directory,
    firecrest_account,
):
    local_directory = os.path.abspath(local_directory)

    last_push_ts = _read_last_push_timestamp(local_directory)
    files_to_upload = _collect_new_or_updated_files(local_directory, last_push_ts)

    if not files_to_upload:
        print("No new or updated files to upload.")
        return

    print(
        f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}: "
        f"Found {len(files_to_upload)} new/updated files in '{local_directory}'."
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        local_archive_path = os.path.join(tmpdir, "firecrest_sync.tar.gz")

        print(f"Creating archive {local_archive_path}...")
        with tarfile.open(local_archive_path, "w:gz") as tar:
            for abs_path, rel_path in files_to_upload:
                root_folder = os.path.basename(local_directory.rstrip(os.sep)) or "."
                arcname = os.path.join(root_folder, rel_path)
                tar.add(abs_path, arcname=arcname)

        remote_archive_name = ".firecrest_sync.tar.gz"
        remote_archive_dir = remote_directory.rstrip("/")
        print(
            f"Uploading archive to system '{system_name}': "
            f"{remote_archive_dir}/{remote_archive_name}"
        )

        client.upload(
            system_name=system_name,
            local_file=local_archive_path,
            directory=remote_archive_dir,
            filename=remote_archive_name,
            account=firecrest_account,
            blocking=True,
        )

        remote_archive_path = os.path.join(remote_archive_dir, remote_archive_name)

        print(f"Extracting archive on remote system into '{remote_directory}'...")
        client.extract(
            system_name=system_name,
            source_path=remote_archive_path,
            target_path=remote_directory,
            account=firecrest_account,
            blocking=True,
        )

        try:
            print(f"Removing remote archive {remote_archive_path}...")
            client.rm(
                system_name=system_name,
                path=remote_archive_path,
                account=firecrest_account,
                blocking=True,
            )
        except Exception as e:
            print(f"Warning: failed to delete remote archive {remote_archive_path}: {e}")

    _write_last_push_timestamp(local_directory)

    print(
        f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}: "
        f"Successfully pushed {len(files_to_upload)} files to '{remote_directory}'."
    )


def main():
    client_id = os.getenv("FIRECREST_CLIENT_ID")
    client_secret = os.getenv("FIRECREST_CLIENT_SECRET")
    token_uri = os.getenv("AUTH_TOKEN_URL")
    firecrest_url = os.getenv("FIRECREST_URL")
    system_name = os.getenv("FIRECREST_SYSTEM")
    training_workdir = os.getenv("FIRECREST_WORKDIR")
    firecrest_account = os.getenv("FIRECREST_ACCOUNT")
    remote_system_user = os.getenv("FIRECREST_USER")

    client = f7t.v2.Firecrest(
        firecrest_url=firecrest_url,
        authorization=f7t.ClientCredentialsAuth(
            client_id,
            client_secret,
            token_uri
        )
    )

    if len(sys.argv) == 1 or sys.argv[1] == "download_mlruns":
        download_mlruns(
            client,
            system_name,
            training_workdir,
            firecrest_account,
        )
    elif sys.argv[1] == "push_directory":
        local_dir = sys.argv[2]
        remote_dir = sys.argv[3]
        firecrest_push_new_or_updated_files(
            client,
            system_name,
            local_dir,
            remote_dir,
            firecrest_account,
        )
        return
    else:
        print("Usage: python firecrest-python-utils.py download_mlruns|push_directory <local_dir> <remote_dir>")


if __name__ == "__main__":
    main()
