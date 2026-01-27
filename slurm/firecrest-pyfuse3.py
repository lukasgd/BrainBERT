#!/usr/bin/env python3
import os
import sys
import time
import errno
import stat
import logging
import tempfile
import trio
import pyfuse3
import firecrest
from firecrest import FirecrestException


logger = logging.getLogger("FirecrestFS")


class FirecrestFS(pyfuse3.Operations):
    def __init__(self, client, machine, remote_root, account=None):
        super().__init__()
        self.client = client
        self.machine = machine
        self.remote_root = remote_root.rstrip('/')
        self.account = account
        
        # Inode Management
        # Inode 1 is reserved for Root
        self.inode_map = {pyfuse3.ROOT_INODE: self.remote_root}
        logging.debug(f"Initialized inode_map {self.inode_map}")      
        self.path_to_inode = {self.remote_root: pyfuse3.ROOT_INODE}
        self.next_inode = pyfuse3.ROOT_INODE + 1
        
        # File Handle Management (Write Buffers)
        self.open_files = {}
        self.next_fh = 1

    def _inode_to_path(self, inode):
        # TODO: Remove after debugging
        if inode == 0:
            logger.error(f"!!! BUG in _get_path: File has Inode 0")
        if inode not in self.inode_map:
            raise pyfuse3.FUSEError(errno.ENOENT)
        return self.inode_map[inode]

    def _get_inode(self, path):
        if path in self.path_to_inode:
            return self.path_to_inode[path]

        inode = self.next_inode
        self.next_inode += 1
        self.inode_map[inode] = path
        self.path_to_inode[path] = inode
        return inode

    def _firecrest_stat_to_attr(self, fc_stat, inode):
        """
        Convert FirecREST v2 FileStat object to pyfuse3 EntryAttributes.
        v2 objects usually have attributes like .mode, .size, etc.
        """
        entry = pyfuse3.EntryAttributes()
        
        # Helper to handle both object attributes and dictionary keys
        def get_val(obj, key, default=0):
            if isinstance(obj, dict):
                return obj.get(key, default)
            return getattr(obj, key, default)

        entry.st_ino = inode
        entry.generation = 0
        # High timeouts so kernel trusts READDIRPLUS data
        entry.entry_timeout = 1.0 
        entry.attr_timeout = 1.0

        entry.st_mode = int(get_val(fc_stat, 'mode'))
        entry.st_nlink = int(get_val(fc_stat, 'nlink', 1))
        entry.st_uid = int(get_val(fc_stat, 'uid', os.environ.get('SUDO_UID', os.getuid())))
        entry.st_gid = int(get_val(fc_stat, 'gid', os.environ.get('SUDO_GID', os.getgid())))
        entry.st_rdev = int(get_val(fc_stat, 'dev', 0))
        entry.st_size = int(get_val(fc_stat, 'size', 0))
        
        # Handle timestamps (FirecREST usually sends seconds, pyfuse3 needs ns)
        entry.st_atime_ns = int(get_val(fc_stat, 'atime', 0)) * 10**9
        entry.st_mtime_ns = int(get_val(fc_stat, 'mtime', 0)) * 10**9
        entry.st_ctime_ns = int(get_val(fc_stat, 'ctime', 0)) * 10**9
        
        # Fallback for file type if mode is missing/zero
        if entry.st_mode == 0:
            entry.st_mode = (stat.S_IFREG | 0o644)

        assert entry.st_ino != 0, "Inode cannot be 0"

        return entry

   # --- STATFS (Fixes the -38 error) ---
    async def statfs(self, ctx):
        
        # TODO: client.submit statfs job and read output (cache result with timeout)
        # firecrest_run_cmd 'read t s b f a c d i l S <<< $(stat -f -c "%t %s %b %f %a %c %d %i %l %S" /vast) && printf "f_type=%d\nf_bsize=%s\nf_blocks=%s\nf_bfree=%s\nf_bavail=%s\nf_files=%s\nf_ffree=%s\nf_fsid=%d\nf_namelen=%s\nf_frsize=%s\n" "0x$t" "$s" "$b" "$f" "$a" "$c" "$d" "0x$i" "$l" "$S"'

        stats = pyfuse3.StatvfsData()

        if "/vast" in os.getenv("FIRECREST_WORKDIR"):
            # stats.f_type = 26985
            stats.f_bsize = 1048576       # Optimal transfer block size
            stats.f_frsize = 1048576      # Fragment size
            stats.f_blocks = 2253403136   # Total data blocks in filesystem
            stats.f_bfree = 1737810737    # Free blocks in filesystem
            stats.f_bavail = 1737810737   # Free blocks available
            stats.f_files = 7616634880    # Total inodes in filesystem
            stats.f_ffree = 7404691382    # Free inodes in filesystem
            stats.f_namemax = 255         # Maximum filename length

        elif "/iopsstor" in os.getenv("FIRECREST_WORKDIR"):
            # stats.f_type = 2035054128
            stats.f_bsize = 65536
            stats.f_frsize = 65536
            stats.f_blocks = 3903165
            stats.f_bfree = 3814236
            stats.f_bavail = 3814236
            stats.f_files = 3903165
            stats.f_ffree = 3823715
            stats.f_namemax = 256

        else:
            raise pyfuse3.FUSEError(errno.EIO)

        return stats


    # --- Core Metadata Operations ---

    async def lookup(self, parent_inode, name, ctx=None):
        name = name.decode('utf-8')
        parent_path = self._inode_to_path(parent_inode)
        path = os.path.join(parent_path, name)
        
        logger.debug(f"lookup: {path}")

        try:
            # v2: client.stat returns a typed object
            # We run the synchronous v2 client in a thread to avoid blocking the loop
            fc_stat = await trio.to_thread.run_sync(
                self.client.stat, self.machine, path
            )
            
            inode = self._get_inode(path)
            attr = self._firecrest_stat_to_attr(fc_stat, inode)

            return self._validate_attr(attr, "lookup")
 
        except FirecrestException:
            raise pyfuse3.FUSEError(errno.ENOENT)
        except Exception as e:
            logger.error(f"lookup unexpected error: {e}")
            raise pyfuse3.FUSEError(errno.EIO)

    async def getattr(self, inode, ctx=None):
        path = self._inode_to_path(inode)
        logger.debug(f"getattr: {path}")
        
        # Check if open for writing (return local stats from buffer)
        for fh, data in self.open_files.items():
            if data['path'] == path and data['dirty']:
                entry = pyfuse3.EntryAttributes()
                entry.st_ino = inode
                entry.st_mode = (stat.S_IFREG | 0o644)
                entry.st_size = os.fstat(data['buffer'].fileno()).st_size
                entry.st_mtime_ns = int(time.time() * 10**9)
                entry.st_atime_ns = entry.st_mtime_ns
                entry.st_ctime_ns = entry.st_mtime_ns
                entry.st_uid = os.environ.get('SUDO_UID', os.getuid())
                entry.st_gid = os.environ.get('SUDO_GID', os.getgid())
                return entry

        try:
            fc_stat = await trio.to_thread.run_sync(
                self.client.stat, self.machine, path
            )
            attr = self._firecrest_stat_to_attr(fc_stat, inode)

            return self._validate_attr(attr, "getattr")
        except FirecrestException:
            raise pyfuse3.FUSEError(errno.ENOENT)

    # async def readdir(self, inode, start_id, token):
    #     path = self._get_path(inode)
    #     logger.debug(f"readdir: {path}")

    #     try:
    #         # v2: list_files returns a list of objects
    #         files = await trio.to_thread.run_sync(
    #             self.client.list_files, self.machine, path, True
    #         )
            
    #         for i, file_obj in enumerate(files[start_id:], start_id):
    #             # Handle v2 object attribute access with dict fallback
    #             name = getattr(file_obj, 'name', None)
    #             if name is None:
    #                 name = file_obj.get('name')

    #             if name == '.' or name == '..':
    #                 continue
                    
    #             child_path = os.path.join(path, name)
    #             child_inode = self._get_inode(child_path)
                
    #             attr = pyfuse3.EntryAttributes()
    #             attr.st_ino = child_inode
                
    #             if not pyfuse3.readdir_reply(token, name.encode('utf-8'), attr, i + 1):
    #                 break
                    
    #     except Exception as e:
    #         logger.error(f"readdir error: {e}")
    #         raise pyfuse3.FUSEError(errno.EIO)


    async def opendir(self, inode, ctx):
        return inode


    async def readdir(self, inode, start_id, token):
        path = self._inode_to_path(inode)
        logger.debug('reading %s', path)

        try:
            # 1. Fetch list from FirecREST
            files_raw = await trio.to_thread.run_sync(
                self.client.list_files, self.machine, path, True
            )
        except Exception as e:
            logger.error(f"readdir API error on {path}: {e}")
            raise pyfuse3.FUSEError(errno.EIO)

        entries = []

        # 2. MANUALLY ADD '.' (Current Dir) with VALID INODE
        attr_dot = pyfuse3.EntryAttributes()
        attr_dot.st_ino = inode  # <--- CRITICAL: Must match the directory's own inode
        attr_dot.st_mode = stat.S_IFDIR | 0o755
        entries.append((b'.', attr_dot))

        # 3. MANUALLY ADD '..' (Parent Dir) with VALID INODE
        attr_dotdot = pyfuse3.EntryAttributes()
        # Compute actual parent inode
        if inode == pyfuse3.ROOT_INODE:
            parent_inode = pyfuse3.ROOT_INODE
        else:
            parent_path = os.path.dirname(path)
            parent_inode = self.path_to_inode.get(parent_path, pyfuse3.ROOT_INODE)
        attr_dotdot.st_ino = parent_inode
        attr_dotdot.st_mode = stat.S_IFDIR | 0o755
        entries.append((b'..', attr_dotdot))

        # 4. Process Remote Files
        for f in files_raw:
            # Handle v2 object vs dict safely
            if isinstance(f, dict):
                name = f.get('name')
                ftype = f.get('type')
            else:
                name = getattr(f, 'name', None)
                ftype = getattr(f, 'type', None)
            
            if not name or name in ('.', '..'):
                continue
            
            # Map FirecREST type to POSIX Mode
            mode = stat.S_IFREG | 0o644 # Default to file
            if ftype == 'd':
                mode = stat.S_IFDIR | 0o755
            elif ftype == 'l':
                mode = stat.S_IFLNK | 0o777
            
            child_path = os.path.join(path, name)
            child_inode = self._get_inode(child_path)

            attr = pyfuse3.EntryAttributes()
            attr.st_ino = child_inode # <--- Ensure this is never 0
            attr.st_mode = mode       # <--- Ensure this has type bits (S_IFDIR etc)
            
            entries.append((name.encode('utf-8'), attr))

        # 5. Send Reply
        for i, (name_bytes, attr) in enumerate(entries[start_id:], start_id):
            # Safety check to catch bugs before they hit the kernel
            if attr.st_ino == 0:
                logger.error(f"Skipping invalid entry '{name_bytes}' with Inode 0")
                continue
                
            if not pyfuse3.readdir_reply(token, name_bytes, attr, i + 1):
                break
  
    # --- File Creation / Removal / Moving ---

    async def mkdir(self, parent_inode, name, mode, ctx):
        path = os.path.join(self._inode_to_path(parent_inode), name.decode('utf-8'))
        try:
            # ops/mkdir usually doesn't take account
            await trio.to_thread.run_sync(self.client.mkdir, self.machine, path)
            
            inode = self._get_inode(path)
            entry = pyfuse3.EntryAttributes()
            entry.st_ino = inode
            entry.generation = 0
            entry.entry_timeout = 1.0
            entry.attr_timeout = 1.0
            entry.st_mode = (stat.S_IFDIR | mode)
            entry.st_nlink = 2  # Standard for directories (. and ..)
            entry.st_uid = ctx.uid
            entry.st_gid = ctx.gid
            entry.st_rdev = 0
            entry.st_size = 0
            
            now = int(time.time() * 10**9)
            entry.st_atime_ns = now
            entry.st_mtime_ns = now
            entry.st_ctime_ns = now

            return self._validate_attr(entry, "mkdir")
        except Exception as e:
            logger.error(f"mkdir failed for {path}: {e}")
            raise pyfuse3.FUSEError(errno.EIO)

    async def unlink(self, parent_inode, name, ctx):
        path = os.path.join(self._inode_to_path(parent_inode), name.decode('utf-8'))
        try:
            await trio.to_thread.run_sync(
                 self.client.rm,
                 self.machine,
                 path
            )

            # Cleanup inode maps
            if path in self.path_to_inode:
                inode = self.path_to_inode.pop(path)
                self.inode_map.pop(inode, None)

        except Exception as e:
             logger.error(f"Unlink failed: {e}")
             raise pyfuse3.FUSEError(errno.EIO)

    async def rename(self, parent_inode_old, name_old, parent_inode_new, name_new, flags, ctx):
        if flags != 0:
            # RENAME_NOREPLACE is common, might want to handle it or return specific error
            raise pyfuse3.FUSEError(errno.EINVAL)
    
        # Use fsdecode to handle non-strict UTF-8 safely
        try:
            s_name_old = os.fsdecode(name_old)
            s_name_new = os.fsdecode(name_new)
        except Exception:
            raise pyfuse3.FUSEError(errno.EINVAL)
    
        old_path = os.path.join(self._inode_to_path(parent_inode_old), s_name_old)
        new_path = os.path.join(self._inode_to_path(parent_inode_new), s_name_new)
    
        try:
            await trio.to_thread.run_sync(
                self.client.mv, 
                self.machine, 
                old_path, 
                new_path,
                self.account
            )
            
            # 1. Handle Overwrite: Remove existing target from cache if present
            if new_path in self.path_to_inode:
                old_target_inode = self.path_to_inode.pop(new_path)
                if old_target_inode in self.inode_map:
                    del self.inode_map[old_target_inode]
    
            # 2. Handle Source Move
            if old_path in self.path_to_inode:
                inode = self.path_to_inode.pop(old_path)
                self.path_to_inode[new_path] = inode
                self.inode_map[inode] = new_path
    
                # 3. Handle Directory Children (Naive implementation)
                # If this is a directory, we must update all paths starting with old_path
                # Note: This can be expensive if the cache is large.
                keys_to_update = [k for k in self.path_to_inode if k.startswith(old_path + os.sep)]
                for k in keys_to_update:
                    child_inode = self.path_to_inode.pop(k)
                    # Replace prefix
                    new_k = new_path + k[len(old_path):]
                    self.path_to_inode[new_k] = child_inode
                    self.inode_map[child_inode] = new_k
    
                # 4. Non-blocking sleep
                await trio.sleep(1.0)
    
        except Exception as e:
            logger.error(f"Rename failed: {e}")
            # Ideally, inspect 'e' to return ENOENT, EACCES, etc.
            raise pyfuse3.FUSEError(errno.EIO)

    # --- File Data Operations (Read/Write) ---

    async def open(self, inode, flags, ctx):
        path = self._inode_to_path(inode)
        fh = self.next_fh
        self.next_fh += 1
        
        # If O_TRUNC is set, we start with a dirty (empty) buffer.
        # This ensures flush() uploads the empty file even if no writes occur,
        # and prevents write() from downloading the old content.
        is_truncated = bool(flags & os.O_TRUNC)

        self.open_files[fh] = {
            'path': path,
            'dirty': is_truncated,
            'buffer': tempfile.NamedTemporaryFile(delete=False)
        }
        return pyfuse3.FileInfo(fh=fh, direct_io=True)

    async def read(self, fh, offset, length):
        if fh not in self.open_files:
            raise pyfuse3.FUSEError(errno.EBADF)

        data = self.open_files[fh]
        if data['dirty']:
            f = data['buffer']
            f.seek(offset)
            return f.read(length)
            
        try:
            # view is an 'ops' endpoint
            resp = await trio.to_thread.run_sync(
                self.client.view_with_offset, self.machine, data['path'], offset, length
            )
            
            # Handle generic response extraction
            content = resp
            if hasattr(resp, 'output'):
                content = resp.output
            elif isinstance(resp, dict) and 'output' in resp:
                content = resp['output']
            
            # Ensure bytes
            if content is None:
                return b''
            if isinstance(content, str):
                return content.encode('utf-8')
            return content
            
        except Exception as e:
            logger.error(f"Read error: {e}")
            raise pyfuse3.FUSEError(errno.EIO)

    async def write(self, fh, offset, buf):
        if fh not in self.open_files:
            raise pyfuse3.FUSEError(errno.EBADF)
            
        data = self.open_files[fh]
        
        # If writing to a clean file (existing remote file), we must download it first
        # to ensure we have the full content before modifying and eventually uploading.
        if not data['dirty']:
            logger.info(f"First write to {data['path']}, downloading original content...")
            try:
                # Close the temp handle to allow safe overwrite
                data['buffer'].close()
                tmp_path = data['buffer'].name
                
                await trio.to_thread.run_sync(
                    self.client.download,
                    self.machine,
                    data['path'],
                    tmp_path
                )
                
                # Re-open the buffer in update mode
                data['buffer'] = open(tmp_path, 'rb+')
                data['dirty'] = True
                
            except Exception as e:
                logger.error(f"Failed to download file for writing: {e}")
                raise pyfuse3.FUSEError(errno.EIO)

        f = data['buffer']
        
        try:
            f.seek(offset)
            f.write(buf)
            data['dirty'] = True
            return len(buf)
        except ValueError:
            # Handle case where file might have been closed unexpectedly
            raise pyfuse3.FUSEError(errno.EIO)

    async def flush(self, fh):
        # Called on every close() or fsync(). 
        # We must upload, but KEEP THE FILE OPEN.
        if fh not in self.open_files:
            return

        data = self.open_files[fh]
        if data['dirty']:
            logger.info(f"Uploading {data['path']}")
            try:
                # 1. Sync Python buffer to disk so external upload tool can read it
                f = data['buffer']
                f.flush()
                os.fsync(f.fileno()) 

                # 2. Prepare paths
                path = data['path']
                target_dir = os.path.dirname(path)
                filename = os.path.basename(path)
                
                # Use a temporary directory to avoid filename collisions in /tmp
                with tempfile.TemporaryDirectory() as tmpdir:
                    stage_path = os.path.join(tmpdir, filename)

                    # Copy open file to stage path to avoid messing with the open handle
                    # Use chunked copy to avoid loading full file into RAM
                    with open(stage_path, 'wb') as stage:
                        f.seek(0)
                        while True:
                            chunk = f.read(1024 * 1024)
                            if not chunk:
                                break
                            stage.write(chunk)
                    
                    # Mark clean BEFORE yielding to upload.
                    # If a write happens during upload, it will set dirty=True again.
                    data['dirty'] = False

                    # 4. Upload
                    await trio.to_thread.run_sync(
                        self.client.upload,
                        self.machine,
                        stage_path,
                        target_dir,
                        filename,
                        self.account
                    )
                
            except Exception as e:
                logger.error(f"Upload failed for {data['path']}: {e}")
                # Restore dirty flag so we retry later
                data['dirty'] = True
                # Return EIO so the app knows the save failed
                raise pyfuse3.FUSEError(errno.EIO)
        return

    async def release(self, fh):
        # Called when the last file descriptor is closed.
        # This is where we actually close and delete the temp file.
        if fh in self.open_files:
            data = self.open_files[fh]
            try:
                # Close the Python file object
                data['buffer'].close()
                # Remove the temp file from local disk
                if os.path.exists(data['buffer'].name):
                    os.remove(data['buffer'].name)
            except Exception as e:
                logger.warning(f"Error cleaning up release fh {fh}: {e}")
            
            del self.open_files[fh]


    def _validate_attr(self, attr, source_method):
        """Helper to catch Inode 0 before it leaves Python"""
        if attr.st_ino == 0:
            logger.error(f"!!! BUG DETECTED in {source_method} !!!")
            logger.error("Attempted to return an EntryAttributes with st_ino=0.")
            import traceback
            traceback.print_stack()
            raise pyfuse3.FUSEError(errno.EIO)
        return attr

    async def create(self, parent_inode, name, mode, flags, ctx):
        name_str = name.decode('utf-8')
        path = os.path.join(self._inode_to_path(parent_inode), name_str)
        
        logger.info(f"Creating new file: {path}")

        # 1. Assign internal handle and inode
        fh = self.next_fh
        self.next_fh += 1
        inode = self._get_inode(path)

        # 2. Setup Write Buffer (Mark as dirty so it uploads on close)
        self.open_files[fh] = {
            'path': path,
            'dirty': True, # Critical: Forces flush() to upload this new file
            'buffer': tempfile.NamedTemporaryFile(delete=False)
        }

        # 3. Create Entry Attributes (The kernel needs to know what we just created)
        entry = pyfuse3.EntryAttributes()
        entry.st_ino = inode
        entry.generation = 0
        entry.entry_timeout = 1.0
        entry.attr_timeout = 1.0
        
        entry.st_mode = (stat.S_IFREG | mode)
        entry.st_nlink = 1
        entry.st_uid = ctx.uid
        entry.st_gid = ctx.gid
        entry.st_rdev = 0
        entry.st_size = 0 # New files are empty
        
        now = int(time.time() * 10**9)
        entry.st_atime_ns = now
        entry.st_mtime_ns = now
        entry.st_ctime_ns = now

        # 4. Return Tuple (FileInfo, EntryAttributes)
        return (pyfuse3.FileInfo(fh=fh, direct_io=True), entry)

    async def setattr(self, inode, attr, fields, fh, ctx):
        # This handles chmod, chown, truncate, etc.
        path = self._inode_to_path(inode)
        
        # 1. Handle Truncate (Size change)
        if fields.update_size:
            # If we have the file open (fh is provided or found), resize the buffer
            target_fh = fh
            
            # If fh not provided, try to find it in open_files
            if target_fh is None:
                for open_fh, data in self.open_files.items():
                    if data['path'] == path:
                        target_fh = open_fh
                        break
            
            if target_fh is not None and target_fh in self.open_files:
                data = self.open_files[target_fh]
                data['buffer'].truncate(attr.st_size)
                data['dirty'] = True
                logger.debug(f"Truncated local buffer for {path} to {attr.st_size}")
            else:
                # File not open locally. We must download, truncate, and upload.
                logger.info(f"Truncating closed file {path} to {attr.st_size}")
                tmp_path = None
                try:
                    with tempfile.NamedTemporaryFile(delete=False) as tmp:
                        tmp_path = tmp.name
                    
                    # Optimization: If truncating to 0, no need to download
                    if attr.st_size > 0:
                        # Download
                        await trio.to_thread.run_sync(
                            self.client.download, self.machine, path, tmp_path
                        )
                    
                    # Truncate locally
                    os.truncate(tmp_path, attr.st_size)
                    
                    # Upload back
                    target_dir = os.path.dirname(path)
                    filename = os.path.basename(path)
                    await trio.to_thread.run_sync(
                        self.client.upload, self.machine, tmp_path, target_dir, filename, self.account
                    )
                    
                except Exception as e:
                    logger.error(f"Remote truncate failed: {e}")
                    raise pyfuse3.FUSEError(errno.EIO)
                finally:
                    if tmp_path and os.path.exists(tmp_path):
                        os.remove(tmp_path)

        # 2. Handle Mode (chmod)
        if fields.update_mode:
            # Convert mode to octal string for FirecREST
            mode_octal = f"{stat.S_IMODE(attr.st_mode):03o}"
            await trio.to_thread.run_sync(self.client.chmod, self.machine, path, mode_octal)

        # 3. Handle Ownership (chown)
        if fields.update_uid or fields.update_gid:
            owner = str(attr.st_uid) if fields.update_uid else None
            group = str(attr.st_gid) if fields.update_gid else None
            try:
                await trio.to_thread.run_sync(
                    self.client.chown, self.machine, path, owner, group
                )
            except Exception as e:
                logger.warning(f"chown failed for {path}: {e}")
                # Raise EPERM so the caller knows it failed
                raise pyfuse3.FUSEError(errno.EPERM)

        # 4. Return updated attributes
        # We must return a valid EntryAttributes object reflecting the changes
        return await self.getattr(inode, ctx)

  
    async def releasedir(self, fh):
        # No cleanup needed for stateless REST directory listings
        return

    async def rmdir(self, parent_inode, name, ctx):
        path = os.path.join(self._inode_to_path(parent_inode), name.decode('utf-8'))
        logger.info(f"Removing directory: {path}")
        
        # 1. Safety Check: Verify Directory is Empty (POSIX Compliance)
        try:
            # Fetch contents to see if it has children
            files = await trio.to_thread.run_sync(
                self.client.list_files, self.machine, path, True
            )
            
            # Check if there are any real files (ignoring self/parent pointers if API sends them)
            for f in files:
                child_name = getattr(f, 'name', None) or f.get('name')
                if child_name and child_name not in ('.', '..'):
                    logger.warning(f"Refusing to rmdir non-empty directory: {path}")
                    raise pyfuse3.FUSEError(errno.ENOTEMPTY)

        except FirecrestException as e:
            # If we can't list it (e.g. 404 or 403), we cannot safely proceed 
            # because the backend rm is recursive.
            logger.warning(f"rmdir emptiness check failed: {e}")
            raise pyfuse3.FUSEError(errno.ENOENT)
        except pyfuse3.FUSEError:
            raise
        except Exception as e:
            logger.error(f"Unexpected error checking directory emptiness: {e}")
            raise pyfuse3.FUSEError(errno.EIO)

        # 2. Perform delete
        try:
            # FirecREST 'rm' is recursive, but we only reach here if empty
            await trio.to_thread.run_sync(
                 self.client.rm, 
                 self.machine,
                 path
            )
            
            # 3. Cleanup internal inode cache
            if path in self.path_to_inode:
                inode = self.path_to_inode.pop(path)
                self.inode_map.pop(inode, None)
                
        except Exception as e:
            logger.error(f"rmdir failed for {path}: {e}")
            raise pyfuse3.FUSEError(errno.EIO)
  

def main():
    # import debugpy

    # # 5678 is the default attach port in the VS Code debug configurations. Unless a host and port are specified, host defaults to 127.0.0.1
    # debugpy.listen(5678)
    # print("Waiting for debugger attach")
    # debugpy.wait_for_client()
    # debugpy.breakpoint()
    # print('break on this line')
    

    import argparse
    parser = argparse.ArgumentParser(description="Mount FirecREST v2 as a FUSE filesystem.")
    parser.add_argument("mountpoint", help="Directory to mount")
    parser.add_argument("--url", default=os.getenv("FIRECREST_URL"), help="FirecREST API URL")
    parser.add_argument("--client-id", default=os.getenv("FIRECREST_CLIENT_ID"), help="OIDC Client ID")
    parser.add_argument("--client-secret", default=os.getenv("FIRECREST_CLIENT_SECRET"), help="OIDC Client Secret")
    parser.add_argument("--token-uri", default=os.getenv("AUTH_TOKEN_URL"), help="OIDC Token URL")
    parser.add_argument("--machine", default=os.getenv("FIRECREST_SYSTEM"), help="Target Machine Name")
    parser.add_argument("--root", default=os.getenv("FIRECREST_WORKDIR"), help="Remote Root Directory")
    parser.add_argument("--account", default=os.getenv("FIRECREST_ACCOUNT"), help="Slurm Account")
    parser.add_argument("--allow-other", action="store_true", help="Allow other users to access this mount (requires /etc/fuse.conf configuration)")
    parser.add_argument('--debug', action='store_true', default=False,
                        help='Enable debugging output')
    parser.add_argument('--debug-fuse', action='store_true', default=False,
                        help='Enable FUSE debugging output')

    args = parser.parse_args()

    if not os.path.exists(args.mountpoint):
        os.makedirs(args.mountpoint)

    # Configure logging
    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
    
    if args.debug:
        logging.getLogger("pyfuse3").setLevel(logging.DEBUG)
        logging.getLogger("firecrest").setLevel(logging.DEBUG) 
    else:
        logging.getLogger("pyfuse3").setLevel(logging.INFO)
        logging.getLogger("firecrest").setLevel(logging.INFO) 


    # Auth Setup
    try:
        auth = firecrest.ClientCredentialsAuth(
            args.client_id, args.client_secret, args.token_uri
        )
        # Instantiate FirecREST v2 Client
        fc_client = firecrest.v2.Firecrest(firecrest_url=args.url, authorization=auth)
    except Exception as e:
        print(f"Error initializing FirecREST client: {e}")
        sys.exit(1)

    firecrest_fs = FirecrestFS(fc_client, args.machine, args.root, account=args.account)
    
    fuse_options = set(pyfuse3.default_options)
    fuse_options.add('fsname=firecrest_v2')
    if args.allow_other:
        fuse_options.add('allow_other')
    if args.debug_fuse:
        fuse_options.add('debug')

    pyfuse3.init(firecrest_fs, args.mountpoint, fuse_options)
    
    print(f"Mounted {args.machine}:{args.root} at {args.mountpoint}")
    print(f"Using Account: {args.account}")

    try:
        logger.debug('Entering main loop..')
        trio.run(pyfuse3.main)
    except KeyboardInterrupt:
        pass
    finally:
        pyfuse3.close()

if __name__ == '__main__':
    main()