/* fanotify for fang-storaged (Linux 5.17+). On other systems every call fails with ENOSYS, so the
 * package still builds for development on macOS. */

#ifdef __linux__
#define _GNU_SOURCE
#endif

#include "clinuxfs.h"
#include <errno.h>

#ifdef __linux__
#include <sys/xattr.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <linux/fs.h>
#include <stdlib.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/fanotify.h>
#include <sys/syscall.h>
#include <sys/vfs.h>
#include <unistd.h>

ssize_t fang_lgetxattr(const char *path, const char *name, void *value, size_t size)
{
    return lgetxattr(path, name, value, size);
}

int fang_lsetxattr(const char *path, const char *name, const void *value, size_t size)
{
    return lsetxattr(path, name, value, size, 0);
}

int fang_lremovexattr(const char *path, const char *name)
{
    return lremovexattr(path, name);
}

int fang_lsetxattr_create(const char *path, const char *name, const void *value, size_t size)
{
    return lsetxattr(path, name, value, size, XATTR_CREATE);
}

ssize_t fang_llistxattr(const char *path, char *names, size_t size)
{
    return llistxattr(path, names, size);
}

int fang_copy_xattrs(const char *from, const char *to, const char *skip)
{
    char names[64 * 1024];
    ssize_t length = llistxattr(from, names, sizeof(names));
    if (length < 0) {
        return -1;
    }
    for (char *name = names; name < names + length; name += strlen(name) + 1) {
        char value[64 * 1024];
        ssize_t size;
        if (strncmp(name, "user.", 5) != 0 || (skip != NULL && strcmp(name, skip) == 0)) {
            continue;
        }
        size = lgetxattr(from, name, value, sizeof(value));
        if (size >= 0 && lsetxattr(to, name, value, (size_t)size, 0) != 0) {
            return -1;
        }
    }
    return 0;
}

int fang_exchange(const char *a, const char *b)
{
    return (int)syscall(SYS_renameat2, AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE);
}

int fang_rename_noreplace(const char *from, const char *to)
{
    return (int)syscall(SYS_renameat2, AT_FDCWD, from, AT_FDCWD, to, RENAME_NOREPLACE);
}

int fang_set_mtime(const char *path, int64_t mtime_ns)
{
    struct timespec times[2];
    times[0].tv_sec = times[1].tv_sec = (time_t)(mtime_ns / 1000000000);
    times[0].tv_nsec = times[1].tv_nsec = (long)(mtime_ns % 1000000000);
    times[0].tv_nsec = UTIME_OMIT;
    return utimensat(AT_FDCWD, path, times, AT_SYMLINK_NOFOLLOW);
}

int fang_clone(const char *from, const char *to)
{
    int in = open(from, O_RDONLY | O_CLOEXEC), out, err;
    struct stat st;
    if (in < 0) {
        return -1;
    }
    out = open(to, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (out < 0) {
        err = errno;
        close(in);
        errno = err;
        return -1;
    }
    if (ioctl(out, FICLONE, in) != 0) {
        /* No reflinks here (or across filesystems): copy, still in the kernel. */
        off_t left;
        if (fstat(in, &st) != 0) {
            goto fail;
        }
        for (left = st.st_size; left > 0;) {
            ssize_t n = copy_file_range(in, NULL, out, NULL, (size_t)left, 0);
            if (n <= 0) {
                goto fail;
            }
            left -= n;
        }
    }
    close(in);
    return close(out);
fail:
    err = errno;
    close(in);
    close(out);
    unlink(to);
    errno = err;
    return -1;
}

const uint64_t FANG_EV_CREATE = FAN_CREATE, FANG_EV_DELETE = FAN_DELETE, FANG_EV_MOVED_FROM = FAN_MOVED_FROM,
    FANG_EV_MOVED_TO = FAN_MOVED_TO, FANG_EV_RENAME = FAN_RENAME, FANG_EV_CLOSE_WRITE = FAN_CLOSE_WRITE,
    FANG_EV_ATTRIB = FAN_ATTRIB, FANG_EV_ONDIR = FAN_ONDIR, FANG_EV_OVERFLOW = FAN_Q_OVERFLOW;

int fang_fanotify_open(void)
{
    return (int)syscall(SYS_fanotify_init,
                        FAN_CLASS_NOTIF | FAN_UNLIMITED_QUEUE | FAN_CLOEXEC | FAN_REPORT_DFID_NAME_TARGET,
                        O_RDONLY | O_LARGEFILE);
}

int fang_fanotify_watch(int fan, const char *path)
{
    uint64_t mask = FAN_CREATE | FAN_DELETE | FAN_MOVED_FROM | FAN_MOVED_TO | FAN_RENAME | FAN_CLOSE_WRITE |
                    FAN_ATTRIB | FAN_ONDIR;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    if (syscall(SYS_fanotify_mark, fan, FAN_MARK_ADD | FAN_MARK_FILESYSTEM, mask, AT_FDCWD, path) != 0) {
        int err = errno;
        close(fd);
        errno = err;
        return -1;
    }
    return fd;
}

/* The path of the directory a file handle names, or NULL if it's gone. */
static const char *resolve_dir(int mount_fd, struct file_handle *handle, char *out, size_t size)
{
    char link[64];
    ssize_t n;
    int fd = open_by_handle_at(mount_fd, handle, O_PATH | O_CLOEXEC);
    if (fd < 0) {
        return NULL;
    }
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    n = readlink(link, out, size - 1);
    close(fd);
    if (n <= 0) {
        return NULL;
    }
    out[n] = '\0';
    return out;
}

int fang_fsid(int fd, uint64_t *fsid)
{
    struct statfs st;
    if (fstatfs(fd, &st) != 0) {
        return -1;
    }
    memcpy(fsid, &st.f_fsid, sizeof(*fsid));
    return 0;
}

int fang_fanotify_read(int fan, const int *mount_fds, const uint64_t *fsids, int mounts, int timeout_ms,
                       fang_event_handler handler, void *context)
{
    char buf[64 * 1024] __attribute__((aligned(__alignof__(struct fanotify_event_metadata))));
    char dir[PATH_MAX], old_dir[PATH_MAX];
    struct pollfd pfd = { .fd = fan, .events = POLLIN };
    ssize_t len;
    int count = 0;

    int ready = poll(&pfd, 1, timeout_ms);
    if (ready <= 0) {
        return ready;
    }
    len = read(fan, buf, sizeof(buf));
    if (len < 0) {
        return errno == EAGAIN ? 0 : -1;
    }
    for (struct fanotify_event_metadata *m = (void *)buf; FAN_EVENT_OK(m, len); m = FAN_EVENT_NEXT(m, len)) {
        struct fang_event event = { .mask = m->mask };
        char *p = (char *)m + m->metadata_len, *end = (char *)m + m->event_len;
        while (p < end) {
            struct fanotify_event_info_header *h = (void *)p;
            if (h->len == 0) {
                break;
            }
            if (h->info_type == FAN_EVENT_INFO_TYPE_DFID_NAME || h->info_type == FAN_EVENT_INFO_TYPE_NEW_DFID_NAME ||
                h->info_type == FAN_EVENT_INFO_TYPE_OLD_DFID_NAME || h->info_type == FAN_EVENT_INFO_TYPE_DFID) {
                struct fanotify_event_info_fid *fid = (void *)h;
                struct file_handle *handle = (void *)fid->handle;
                /* Each watched filesystem resolves its own handles (shares on several pools or datasets). */
                uint64_t fs;
                int mount_fd = mount_fds[0];
                memcpy(&fs, &fid->fsid, sizeof(fs));
                for (int i = 0; i < mounts; i++) {
                    if (fsids[i] == fs) {
                        mount_fd = mount_fds[i];
                        break;
                    }
                }
                const char *name = h->info_type == FAN_EVENT_INFO_TYPE_DFID ? NULL
                                   : (const char *)handle->f_handle + handle->handle_bytes;
                if (h->info_type == FAN_EVENT_INFO_TYPE_OLD_DFID_NAME) {
                    event.old_dir = resolve_dir(mount_fd, handle, old_dir, sizeof(old_dir));
                    event.old_name = name;
                } else {
                    event.dir = resolve_dir(mount_fd, handle, dir, sizeof(dir));
                    event.name = (name != NULL && strcmp(name, ".") != 0) ? name : NULL;
                }
            }
            p += h->len;
        }
        if (m->fd >= 0) {
            close(m->fd);
        }
        handler(&event, context);
        count++;
    }
    return count;
}

#else

const uint64_t FANG_EV_CREATE = 0, FANG_EV_DELETE = 0, FANG_EV_MOVED_FROM = 0, FANG_EV_MOVED_TO = 0,
    FANG_EV_RENAME = 0, FANG_EV_CLOSE_WRITE = 0, FANG_EV_ATTRIB = 0, FANG_EV_ONDIR = 0, FANG_EV_OVERFLOW = 0;

ssize_t fang_lgetxattr(const char *path, const char *name, void *value, size_t size)
{
    (void)path; (void)name; (void)value; (void)size;
    errno = ENOSYS;
    return -1;
}

int fang_lsetxattr(const char *path, const char *name, const void *value, size_t size)
{
    (void)path; (void)name; (void)value; (void)size;
    errno = ENOSYS;
    return -1;
}

int fang_lremovexattr(const char *path, const char *name) { (void)path; (void)name; errno = ENOSYS; return -1; }
int fang_lsetxattr_create(const char *path, const char *name, const void *value, size_t size) { (void)path; (void)name; (void)value; (void)size; errno = ENOSYS; return -1; }
ssize_t fang_llistxattr(const char *path, char *names, size_t size) { (void)path; (void)names; (void)size; errno = ENOSYS; return -1; }
int fang_copy_xattrs(const char *from, const char *to, const char *skip) { (void)from; (void)to; (void)skip; errno = ENOSYS; return -1; }
int fang_exchange(const char *a, const char *b) { (void)a; (void)b; errno = ENOSYS; return -1; }
int fang_rename_noreplace(const char *from, const char *to) { (void)from; (void)to; errno = ENOSYS; return -1; }
int fang_set_mtime(const char *path, int64_t mtime_ns) { (void)path; (void)mtime_ns; errno = ENOSYS; return -1; }
int fang_clone(const char *from, const char *to) { (void)from; (void)to; errno = ENOSYS; return -1; }
int fang_fanotify_open(void) { errno = ENOSYS; return -1; }
int fang_fanotify_watch(int fan, const char *path) { (void)fan; (void)path; errno = ENOSYS; return -1; }
int fang_fsid(int fd, uint64_t *fsid) { (void)fd; (void)fsid; errno = ENOSYS; return -1; }
int fang_fanotify_read(int fan, const int *mount_fds, const uint64_t *fsids, int mounts, int timeout_ms,
                       fang_event_handler handler, void *context)
{
    (void)fan; (void)mount_fds; (void)fsids; (void)mounts; (void)timeout_ms; (void)handler; (void)context;
    errno = ENOSYS;
    return -1;
}

#endif
