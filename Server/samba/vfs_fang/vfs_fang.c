/*
 * vfs_fang: FaNG's Samba module.
 *
 * NT ACLs come from FaNG, not from the filesystem, once "fang:acl socket" names FaNG's ACL service.
 * Until then, "fang:default acl" (SDDL) is every item's ACL, so the host's file modes (often without
 * group write) never decide access; setting an ACL from a client changes nothing. With neither, the ACL
 * hooks pass through and Samba derives ACLs from the modes.
 *
 * fget_nt_acl / fset_nt_acl ask the FaNG ACL service over a Unix socket, one line per request:
 *   GET <share> <path>          -> "OK <sddl>" or "NONE"
 *   SET <share> <path> <sddl>   -> "OK" or an error line
 * Fields are tab-separated; paths are share-relative ("." is the share root). Anything other than an
 * answer from the daemon denies access (fail closed). Nothing is written to the filesystem.
 *
 * With "fang:root io = yes", deleting a file moves it into the share's trash instead
 * (".fang-trash/<time>/<path in the share>"), where FaNG picks it up by its ID; folders and FaNG's own
 * files (".fang-*") are deleted for real.
 *
 * With "fang:root io = yes", openat/mkdirat/unlinkat/renameat run as root, so the ACL from FaNG is
 * the only gate and the kernel's file modes don't get a say. Host ownership stays the host's: new files
 * and folders get "fang:uid"/"fang:gid" (Unraid: 99:100) and exactly the share's "create mask" /
 * "directory mask", whatever the client asked for. Existing files keep their owner and mode, and
 * client chmod/chown requests change nothing.
 */

#include "includes.h"
#include "smbd/smbd.h"
#include "system/filesys.h"
#include "passdb.h"
#include "auth.h"
#include "libcli/security/security.h"
#include "libcli/security/sddl.h"
#include <sys/un.h>

#undef DBGC_CLASS
#define DBGC_CLASS DBGC_VFS

#define FANG_MODULE "fang"

struct fang_config {
	const char *acl_socket;  /* NULL: default_acl, or pass through */
	const char *default_acl; /* SDDL, or NULL */
	bool root_io;
	uid_t uid;
	gid_t gid;
	mode_t file_mode;
	mode_t dir_mode;
};

/* One connection per smbd process, kept open and reused: a listing asks for every entry's ACL, and a new
 * connection per request made plain-SMB listings 60% slower. Reopened after a fork (the fd belongs to the
 * process that opened it) and after any failure (one retry). */
static int fang_fd = -1;
static pid_t fang_fd_pid = 0;

static int fang_connect_socket(const char *socket_path)
{
	struct sockaddr_un addr = { .sun_family = AF_UNIX };
	struct timeval tv = { .tv_sec = 2 };
	int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0) {
		return -1;
	}
	strlcpy(addr.sun_path, socket_path, sizeof(addr.sun_path));
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static char *fang_request_once(TALLOC_CTX *mem_ctx, const char *socket_path, const char *line)
{
	char buf[16384];
	size_t used = 0, len = strlen(line);
	char *nl;

	if (fang_fd >= 0 && fang_fd_pid != getpid()) {
		fang_fd = -1;  /* inherited from the parent: not ours to use */
	}
	if (fang_fd < 0) {
		fang_fd = fang_connect_socket(socket_path);
		fang_fd_pid = getpid();
		if (fang_fd < 0) {
			return NULL;
		}
	}
	if (write(fang_fd, line, len) != (ssize_t)len) {
		goto fail;
	}
	while (used < sizeof(buf) - 1) {
		ssize_t n = read(fang_fd, buf + used, sizeof(buf) - 1 - used);
		if (n <= 0) {
			goto fail;
		}
		used += n;
		if (memchr(buf, '\n', used) != NULL) {
			break;
		}
	}
	buf[used] = '\0';
	nl = strchr(buf, '\n');
	if (nl == NULL || nl[1] != '\0') {
		goto fail;  /* no answer, or more than one: start over on a fresh connection */
	}
	*nl = '\0';
	return talloc_strdup(mem_ctx, buf);
fail:
	close(fang_fd);
	fang_fd = -1;
	return NULL;
}

static char *fang_request(TALLOC_CTX *mem_ctx, const char *socket_path, const char *line)
{
	char *reply = fang_request_once(mem_ctx, socket_path, line);
	if (reply == NULL) {
		reply = fang_request_once(mem_ctx, socket_path, line);  /* the daemon restarted, or the connection dropped */
	}
	return reply;
}

static const char *fang_share(vfs_handle_struct *handle, TALLOC_CTX *mem_ctx)
{
	const struct loadparm_substitution *lp_sub = loadparm_s3_global_substitution();
	/* [Home] is each user's own home folder: inside FaNG, the share ~user. */
	if (lp_parm_bool(SNUM(handle->conn), "fang", "home", false) && handle->conn->session_info != NULL &&
	    handle->conn->session_info->unix_info != NULL && handle->conn->session_info->unix_info->unix_name != NULL) {
		return talloc_asprintf(mem_ctx, "~%s", handle->conn->session_info->unix_info->unix_name);
	}
	return lp_servicename(mem_ctx, lp_sub, SNUM(handle->conn));
}

static const char *fang_path(const files_struct *fsp)
{
	if (fsp->base_fsp != NULL) {
		fsp = fsp->base_fsp;  /* a stream has its file's ACL */
	}
	return fsp->fsp_name->base_name;
}

static struct fang_config *fang_config(vfs_handle_struct *handle)
{
	struct fang_config *config;
	SMB_VFS_HANDLE_GET_DATA(handle, config, struct fang_config, return NULL);
	return config;
}

/* The descriptor FaNG holds for fsp, or NULL with *status set (never a permissive default). */
static struct security_descriptor *fang_get_sd(vfs_handle_struct *handle, const char *socket_path,
					       files_struct *fsp, TALLOC_CTX *mem_ctx, NTSTATUS *status)
{
	TALLOC_CTX *frame = talloc_stackframe();
	struct security_descriptor *sd = NULL;
	const char *line = talloc_asprintf(frame, "GET\t%s\t%s\n", fang_share(handle, frame),
					   fang_path(fsp));
	char *reply = fang_request(frame, socket_path, line);

	if (reply == NULL) {
		DBG_ERR("FaNG ACL daemon unreachable for %s: denying\n", fsp_str_dbg(fsp));
		*status = NT_STATUS_ACCESS_DENIED;
	} else if (strncmp(reply, "OK\t", 3) != 0) {
		DBG_NOTICE("no FaNG ACL for %s (%s): denying\n", fsp_str_dbg(fsp), reply);
		*status = NT_STATUS_ACCESS_DENIED;
	} else {
		sd = sddl_decode(mem_ctx, reply + 3, get_global_sam_sid());
		*status = sd != NULL ? NT_STATUS_OK : NT_STATUS_ACCESS_DENIED;
		if (sd == NULL) {
			DBG_ERR("bad SDDL from FaNG for %s: %s\n", fsp_str_dbg(fsp), reply + 3);
		}
	}
	TALLOC_FREE(frame);
	return sd;
}

static NTSTATUS fang_fget_nt_acl(vfs_handle_struct *handle, files_struct *fsp,
				 uint32_t security_info, TALLOC_CTX *mem_ctx,
				 struct security_descriptor **ppdesc)
{
	struct fang_config *config = fang_config(handle);
	struct security_descriptor *sd;
	NTSTATUS status;

	if (config == NULL) {
		return NT_STATUS_ACCESS_DENIED;
	}
	if (config->acl_socket == NULL && config->default_acl == NULL) {
		return SMB_VFS_NEXT_FGET_NT_ACL(handle, fsp, security_info, mem_ctx, ppdesc);
	}
	if (config->acl_socket == NULL) {
		sd = sddl_decode(mem_ctx, config->default_acl, get_global_sam_sid());
		if (sd == NULL) {
			DBG_ERR("bad fang:default acl: %s\n", config->default_acl);
			return NT_STATUS_ACCESS_DENIED;
		}
	} else {
		sd = fang_get_sd(handle, config->acl_socket, fsp, mem_ctx, &status);
		if (sd == NULL) {
			return status;
		}
	}
	if (!(security_info & SECINFO_OWNER)) {
		sd->owner_sid = NULL;
	}
	if (!(security_info & SECINFO_GROUP)) {
		sd->group_sid = NULL;
	}
	if (!(security_info & SECINFO_DACL)) {
		sd->dacl = NULL;
		sd->type &= ~SEC_DESC_DACL_PRESENT;
	}
	sd->sacl = NULL;
	sd->type &= ~SEC_DESC_SACL_PRESENT;
	*ppdesc = sd;
	return NT_STATUS_OK;
}

static NTSTATUS fang_fset_nt_acl(vfs_handle_struct *handle, files_struct *fsp,
				 uint32_t security_info_sent,
				 const struct security_descriptor *psd)
{
	struct fang_config *config = fang_config(handle);
	TALLOC_CTX *frame;
	NTSTATUS status;
	struct security_descriptor *sd;
	const char *sddl, *line, *reply;

	if (config == NULL) {
		return NT_STATUS_ACCESS_DENIED;
	}
	if (config->acl_socket == NULL && config->default_acl == NULL) {
		return SMB_VFS_NEXT_FSET_NT_ACL(handle, fsp, security_info_sent, psd);
	}
	if (config->acl_socket == NULL) {
		DBG_INFO("ignoring ACL change on %s (default ACL in force)\n", fsp_str_dbg(fsp));
		return NT_STATUS_OK;
	}
	frame = talloc_stackframe();
	sd = fang_get_sd(handle, config->acl_socket, fsp, frame, &status);
	if (sd == NULL) {
		sd = security_descriptor_initialise(frame);
	}
	if (security_info_sent & SECINFO_OWNER) {
		sd->owner_sid = psd->owner_sid;
	}
	if (security_info_sent & SECINFO_GROUP) {
		sd->group_sid = psd->group_sid;
	}
	if (security_info_sent & SECINFO_DACL) {
		sd->dacl = psd->dacl;
		sd->type &= ~(SEC_DESC_DACL_PROTECTED | SEC_DESC_DACL_AUTO_INHERITED);
		sd->type |= SEC_DESC_DACL_PRESENT |
			    (psd->type & (SEC_DESC_DACL_PROTECTED | SEC_DESC_DACL_AUTO_INHERITED));
	}
	sddl = sddl_encode(frame, sd, get_global_sam_sid());
	if (sddl == NULL) {
		TALLOC_FREE(frame);
		return NT_STATUS_NO_MEMORY;
	}
	line = talloc_asprintf(frame, "SET\t%s\t%s\t%s\n", fang_share(handle, frame),
			       fang_path(fsp), sddl);
	reply = fang_request(frame, config->acl_socket, line);
	status = reply != NULL && strcmp(reply, "OK") == 0 ? NT_STATUS_OK : NT_STATUS_ACCESS_DENIED;
	DBG_NOTICE("set FaNG ACL for %s: %s (%s)\n", fsp_str_dbg(fsp), sddl, nt_errstr(status));
	TALLOC_FREE(frame);
	return status;
}

static int fang_connect(vfs_handle_struct *handle, const char *service, const char *user)
{
	struct fang_config *config;
	int snum = SNUM(handle->conn);
	int ret = SMB_VFS_NEXT_CONNECT(handle, service, user);

	if (ret < 0) {
		return ret;
	}
	config = talloc_zero(handle->conn, struct fang_config);
	if (config == NULL) {
		SMB_VFS_NEXT_DISCONNECT(handle);
		errno = ENOMEM;
		return -1;
	}
	config->acl_socket = lp_parm_const_string(snum, FANG_MODULE, "acl socket", NULL);
	config->default_acl = lp_parm_const_string(snum, FANG_MODULE, "default acl", NULL);
	config->root_io = lp_parm_bool(snum, FANG_MODULE, "root io", false);
	config->uid = lp_parm_int(snum, FANG_MODULE, "uid", 99);
	config->gid = lp_parm_int(snum, FANG_MODULE, "gid", 100);
	config->file_mode = lp_create_mask(snum) & 07777;
	config->dir_mode = lp_directory_mask(snum) & 07777;
	SMB_VFS_HANDLE_SET_DATA(handle, config, NULL, struct fang_config, return -1);
	return 0;
}

static bool fang_root_io(vfs_handle_struct *handle, struct fang_config **config)
{
	*config = fang_config(handle);
	return *config != NULL && (*config)->root_io;
}

static int fang_openat(vfs_handle_struct *handle, const struct files_struct *dirfsp,
		       const struct smb_filename *smb_fname, struct files_struct *fsp,
		       const struct vfs_open_how *how)
{
	struct fang_config *config;
	bool created = false;
	int fd, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_OPENAT(handle, dirfsp, smb_fname, fsp, how);
	}
	become_root();
	/* Only a file this open creates gets the host owner and mode; existing ones are left alone. An
	 * exclusive create says for certain whether this open made it, even with another client creating
	 * the same name at the same moment; if the name exists, the file is opened as asked. */
	if ((how->flags & O_CREAT) && smb_fname->stream_name == NULL) {
		struct vfs_open_how exclusive = *how;
		exclusive.flags |= O_EXCL;
		fd = SMB_VFS_NEXT_OPENAT(handle, dirfsp, smb_fname, fsp, &exclusive);
		created = fd >= 0;
		if (fd < 0 && errno == EEXIST && !(how->flags & O_EXCL)) {
			fd = SMB_VFS_NEXT_OPENAT(handle, dirfsp, smb_fname, fsp, how);
		}
	} else {
		fd = SMB_VFS_NEXT_OPENAT(handle, dirfsp, smb_fname, fsp, how);
	}
	err = errno;
	if (created) {
		if (fchown(fd, config->uid, config->gid) != 0 || fchmod(fd, config->file_mode) != 0) {
			DBG_WARNING("owner/mode for %s: %s\n", smb_fname_str_dbg(smb_fname), strerror(errno));
		}
	}
	unbecome_root();
	errno = err;
	return fd;
}

static int fang_mkdirat(vfs_handle_struct *handle, struct files_struct *dirfsp,
			const struct smb_filename *smb_fname, mode_t mode)
{
	struct fang_config *config;
	int ret, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_MKDIRAT(handle, dirfsp, smb_fname, mode);
	}
	become_root();
	ret = SMB_VFS_NEXT_MKDIRAT(handle, dirfsp, smb_fname, mode);
	err = errno;
	if (ret == 0 &&
	    (fchownat(fsp_get_pathref_fd(dirfsp), smb_fname->base_name, config->uid, config->gid,
		      AT_SYMLINK_NOFOLLOW) != 0 ||
	     fchmodat(fsp_get_pathref_fd(dirfsp), smb_fname->base_name, config->dir_mode, 0) != 0)) {
		DBG_WARNING("owner/mode for %s: %s\n", smb_fname_str_dbg(smb_fname), strerror(errno));
	}
	unbecome_root();
	errno = err;
	return ret;
}

static bool fang_is_internal(const char *path)
{
	return strncmp(path, ".fang-", 6) == 0 || strstr(path, "/.fang-") != NULL;
}

/* Creates every missing folder of `path` (absolute) as the host owner with `mode`. */
static void fang_make_folders(const char *path, struct fang_config *config)
{
	char built[PATH_MAX];
	size_t i, len = strlcpy(built, path, sizeof(built));
	for (i = 1; i <= len; i++) {
		if (built[i] == '/' || built[i] == '\0') {
			char c = built[i];
			built[i] = '\0';
			if (mkdir(built, config->dir_mode) == 0) {
				chown(built, config->uid, config->gid);
				chmod(built, config->dir_mode);
			}
			built[i] = c;
		}
	}
}

/* Moves a deleted file into the trash. Returns 0, or -1 with errno. */
static int fang_trash(vfs_handle_struct *handle, struct fang_config *config, const char *relative)
{
	const char *root = handle->conn->connectpath;
	char stamp[32], from[PATH_MAX], folder[PATH_MAX], to[PATH_MAX];
	const char *slash = strrchr(relative, '/');
	time_t now = time(NULL);
	struct tm tm;
	int attempt;

	gmtime_r(&now, &tm);
	strftime(stamp, sizeof(stamp), "%Y-%m-%d %H.%M.%S", &tm);
	snprintf(from, sizeof(from), "%s/%s", root, relative);
	if (slash != NULL) {
		snprintf(folder, sizeof(folder), "%s/.fang-trash/%s/%.*s", root, stamp, (int)(slash - relative), relative);
	} else {
		snprintf(folder, sizeof(folder), "%s/.fang-trash/%s", root, stamp);
	}
	fang_make_folders(folder, config);
	for (attempt = 0; attempt < 100; attempt++) {
		const char *name = slash != NULL ? slash + 1 : relative;
		if (attempt == 0) {
			snprintf(to, sizeof(to), "%s/%s", folder, name);
		} else {
			snprintf(to, sizeof(to), "%s/%s (%d)", folder, name, attempt + 1);
		}
		if (renameat2(AT_FDCWD, from, AT_FDCWD, to, RENAME_NOREPLACE) == 0) {
			return 0;
		}
		if (errno != EEXIST) {
			return -1;
		}
	}
	errno = EEXIST;
	return -1;
}

static int fang_unlinkat(vfs_handle_struct *handle, struct files_struct *dirfsp,
			 const struct smb_filename *smb_fname, int flags)
{
	struct fang_config *config;
	const char *dir = dirfsp->fsp_name->base_name;
	char relative[PATH_MAX];
	int ret, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_UNLINKAT(handle, dirfsp, smb_fname, flags);
	}
	if (strcmp(dir, ".") == 0 || dir[0] == '\0') {
		strlcpy(relative, smb_fname->base_name, sizeof(relative));
	} else {
		snprintf(relative, sizeof(relative), "%s/%s", dir, smb_fname->base_name);
	}
	become_root();
	if ((flags & AT_REMOVEDIR) || smb_fname->stream_name != NULL || fang_is_internal(relative)) {
		ret = SMB_VFS_NEXT_UNLINKAT(handle, dirfsp, smb_fname, flags);
	} else {
		ret = fang_trash(handle, config, relative);
	}
	err = errno;
	unbecome_root();
	errno = err;
	return ret;
}

static int fang_renameat(vfs_handle_struct *handle, struct files_struct *srcdir_fsp,
			 const struct smb_filename *smb_fname_src, struct files_struct *dstdir_fsp,
			 const struct smb_filename *smb_fname_dst, const struct vfs_rename_how *how)
{
	struct fang_config *config;
	int ret, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_RENAMEAT(handle, srcdir_fsp, smb_fname_src, dstdir_fsp,
					     smb_fname_dst, how);
	}
	become_root();
	ret = SMB_VFS_NEXT_RENAMEAT(handle, srcdir_fsp, smb_fname_src, dstdir_fsp, smb_fname_dst,
				    how);
	err = errno;
	unbecome_root();
	errno = err;
	return ret;
}

/* Looking entries up, as root behind Samba's check: the host's modes (a folder without group access, a
 * file only its owner may read) don't decide what a FaNG user may see. */
static int fang_stat(vfs_handle_struct *handle, struct smb_filename *smb_fname)
{
	struct fang_config *config;
	int ret, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_STAT(handle, smb_fname);
	}
	become_root();
	ret = SMB_VFS_NEXT_STAT(handle, smb_fname);
	err = errno;
	unbecome_root();
	errno = err;
	return ret;
}

static int fang_lstat(vfs_handle_struct *handle, struct smb_filename *smb_fname)
{
	struct fang_config *config;
	int ret, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_LSTAT(handle, smb_fname);
	}
	become_root();
	ret = SMB_VFS_NEXT_LSTAT(handle, smb_fname);
	err = errno;
	unbecome_root();
	errno = err;
	return ret;
}

static int fang_fstatat(vfs_handle_struct *handle, const struct files_struct *dirfsp,
			const struct smb_filename *smb_fname, SMB_STRUCT_STAT *sbuf, int flags)
{
	struct fang_config *config;
	int ret, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_FSTATAT(handle, dirfsp, smb_fname, sbuf, flags);
	}
	become_root();
	ret = SMB_VFS_NEXT_FSTATAT(handle, dirfsp, smb_fname, sbuf, flags);
	err = errno;
	unbecome_root();
	errno = err;
	return ret;
}

/* Hard links and symlinks, as root; a new symlink gets the host owner. */
static int fang_linkat(vfs_handle_struct *handle, struct files_struct *srcfsp,
		       const struct smb_filename *old_smb_fname, struct files_struct *dstfsp,
		       const struct smb_filename *new_smb_fname, int flags)
{
	struct fang_config *config;
	int ret, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_LINKAT(handle, srcfsp, old_smb_fname, dstfsp, new_smb_fname, flags);
	}
	become_root();
	ret = SMB_VFS_NEXT_LINKAT(handle, srcfsp, old_smb_fname, dstfsp, new_smb_fname, flags);
	err = errno;
	unbecome_root();
	errno = err;
	return ret;
}

static int fang_symlinkat(vfs_handle_struct *handle, const struct smb_filename *link_contents,
			  struct files_struct *dirfsp, const struct smb_filename *new_smb_fname)
{
	struct fang_config *config;
	int ret, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_SYMLINKAT(handle, link_contents, dirfsp, new_smb_fname);
	}
	become_root();
	ret = SMB_VFS_NEXT_SYMLINKAT(handle, link_contents, dirfsp, new_smb_fname);
	err = errno;
	if (ret == 0 && fchownat(fsp_get_pathref_fd(dirfsp), new_smb_fname->base_name, config->uid,
				 config->gid, AT_SYMLINK_NOFOLLOW) != 0) {
		DBG_WARNING("owner for %s: %s\n", smb_fname_str_dbg(new_smb_fname), strerror(errno));
	}
	unbecome_root();
	errno = err;
	return ret;
}

/* xattrs (named streams, Finder tags and info, resource forks, DOS attributes) and timestamps, as root
 * behind Samba's check like the file I/O itself: a user may tag or re-date a file they don't own. */
static ssize_t fang_fgetxattr(vfs_handle_struct *handle, struct files_struct *fsp, const char *name,
			      void *value, size_t size)
{
	struct fang_config *config;
	ssize_t ret;
	int err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_FGETXATTR(handle, fsp, name, value, size);
	}
	become_root();
	ret = SMB_VFS_NEXT_FGETXATTR(handle, fsp, name, value, size);
	err = errno;
	unbecome_root();
	errno = err;
	return ret;
}

static int fang_fsetxattr(vfs_handle_struct *handle, struct files_struct *fsp, const char *name,
			  const void *value, size_t size, int flags)
{
	struct fang_config *config;
	int ret, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_FSETXATTR(handle, fsp, name, value, size, flags);
	}
	if (strcmp(name, "user.fang.id") == 0) {
		errno = EACCES;  /* FaNG's ID is FaNG's. */
		return -1;
	}
	become_root();
	ret = SMB_VFS_NEXT_FSETXATTR(handle, fsp, name, value, size, flags);
	err = errno;
	unbecome_root();
	errno = err;
	return ret;
}

static int fang_fremovexattr(vfs_handle_struct *handle, struct files_struct *fsp, const char *name)
{
	struct fang_config *config;
	int ret, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_FREMOVEXATTR(handle, fsp, name);
	}
	if (strcmp(name, "user.fang.id") == 0) {
		errno = EACCES;
		return -1;
	}
	become_root();
	ret = SMB_VFS_NEXT_FREMOVEXATTR(handle, fsp, name);
	err = errno;
	unbecome_root();
	errno = err;
	return ret;
}

static int fang_fntimes(vfs_handle_struct *handle, files_struct *fsp, struct smb_file_time *ft)
{
	struct fang_config *config;
	int ret, err;

	if (!fang_root_io(handle, &config)) {
		return SMB_VFS_NEXT_FNTIMES(handle, fsp, ft);
	}
	become_root();
	ret = SMB_VFS_NEXT_FNTIMES(handle, fsp, ft);
	err = errno;
	unbecome_root();
	errno = err;
	return ret;
}

/* Host owner and modes are FaNG's to keep; permissions are FaNG's ACLs. Clients can't change them. */
static int fang_fchmod(vfs_handle_struct *handle, struct files_struct *fsp, mode_t mode)
{
	DBG_INFO("ignoring chmod %o on %s\n", (unsigned)mode, fsp_str_dbg(fsp));
	return 0;
}

static int fang_fchown(vfs_handle_struct *handle, struct files_struct *fsp, uid_t uid, gid_t gid)
{
	DBG_INFO("ignoring chown %d:%d on %s\n", (int)uid, (int)gid, fsp_str_dbg(fsp));
	return 0;
}

static struct vfs_fn_pointers vfs_fang_fns = {
	.connect_fn = fang_connect,
	.fget_nt_acl_fn = fang_fget_nt_acl,
	.fset_nt_acl_fn = fang_fset_nt_acl,
	.openat_fn = fang_openat,
	.mkdirat_fn = fang_mkdirat,
	.unlinkat_fn = fang_unlinkat,
	.renameat_fn = fang_renameat,
	.fchmod_fn = fang_fchmod,
	.fchown_fn = fang_fchown,
	.stat_fn = fang_stat,
	.lstat_fn = fang_lstat,
	.fstatat_fn = fang_fstatat,
	.linkat_fn = fang_linkat,
	.symlinkat_fn = fang_symlinkat,
	.fgetxattr_fn = fang_fgetxattr,
	.fsetxattr_fn = fang_fsetxattr,
	.fremovexattr_fn = fang_fremovexattr,
	.fntimes_fn = fang_fntimes,
};

static_decl_vfs;
NTSTATUS vfs_fang_init(TALLOC_CTX *ctx)
{
	return smb_register_vfs(SMB_VFS_INTERFACE_VERSION, FANG_MODULE, &vfs_fang_fns);
}
