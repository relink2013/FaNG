#ifndef CLINUXFS_H
#define CLINUXFS_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/* lgetxattr / lsetxattr (Swift's Glibc module leaves out sys/xattr.h). */
ssize_t fang_lgetxattr(const char *path, const char *name, void *value, size_t size);
int fang_lsetxattr(const char *path, const char *name, const void *value, size_t size);
int fang_lremovexattr(const char *path, const char *name);
/* Sets an xattr only if the entry doesn't have it yet (EEXIST otherwise). */
int fang_lsetxattr_create(const char *path, const char *name, const void *value, size_t size);
/* The entry's extended attribute names, NUL-separated (llistxattr). */
ssize_t fang_llistxattr(const char *path, char *names, size_t size);

/* Copies every user.* xattr of `from` onto `to`, except `skip` (Finder tags, comments and other client
 * metadata follow new contents). Returns 0, or -1 with errno. */
int fang_copy_xattrs(const char *from, const char *to, const char *skip);

/* Swaps two names atomically (renameat2 RENAME_EXCHANGE). Returns 0, or -1 with errno. */
int fang_exchange(const char *a, const char *b);

/* Renames `from` to `to`, failing with EEXIST instead of replacing what's there, and with EXDEV across
 * filesystems (renameat2 RENAME_NOREPLACE). Returns 0, or -1 with errno. */
int fang_rename_noreplace(const char *from, const char *to);

/* Sets the modification time (nanoseconds since 1970), leaving the access time. Returns 0, or -1 with errno. */
int fang_set_mtime(const char *path, int64_t mtime_ns);

/* Makes `to` (created, mode 0600) a copy of `from`: a reflink where the filesystem can, a copy otherwise.
 * Returns 0, or -1 with errno. */
int fang_clone(const char *from, const char *to);

/* One filesystem change reported by fanotify, with its directories resolved to paths. Events are hints:
 * the receiver looks at the named entries on disk to find out what actually happened. */
struct fang_event {
    uint64_t mask;           /* FAN_* bits */
    const char *dir;         /* directory the entry is in (for a rename: the new one), or NULL */
    const char *name;        /* entry name, or NULL for an event on the directory itself */
    const char *old_dir;     /* rename only: the old directory and name */
    const char *old_name;
};

/* Bits of fang_event.mask. */
extern const uint64_t FANG_EV_CREATE, FANG_EV_DELETE, FANG_EV_MOVED_FROM, FANG_EV_MOVED_TO, FANG_EV_RENAME,
    FANG_EV_CLOSE_WRITE, FANG_EV_ATTRIB, FANG_EV_ONDIR, FANG_EV_OVERFLOW;

/* A fanotify group that reports directory handles and names. Returns the fd, or -1 with errno. */
int fang_fanotify_open(void);

/* Watches the whole filesystem that `path` is on. Returns a descriptor of `path` (used to resolve the
 * handles events carry; keep it open), or -1 with errno. */
int fang_fanotify_watch(int fan, const char *path);

typedef void (*fang_event_handler)(const struct fang_event *event, void *context);

/* Waits up to `timeout_ms` for events and passes each to `handler`. Returns the number of events, 0 on
 * timeout, or -1 with errno. Directories that can't be resolved (gone by now) arrive as NULL. */
/* The filesystem ID of an open file (what fanotify reports with each event). */
int fang_fsid(int fd, uint64_t *fsid);
/* Reads events; each event's handles are resolved against the mount whose filesystem ID matches. */
int fang_fanotify_read(int fan, const int *mount_fds, const uint64_t *fsids, int mounts, int timeout_ms,
                       fang_event_handler handler, void *context);

#endif
