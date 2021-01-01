/*
 * Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
 * License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
 *
 * libgit2 for Inline::C
 * Avoiding Git::Raw since it doesn't guarantee a stable API,
 * while libgit2 itself seems reasonably stable.
 */
#include <git2.h>
#include <sys/uio.h>
#include <errno.h>
#include <poll.h>

static void croak_if_err(int rc, const char *msg)
{
	if (rc != GIT_OK) {
		const git_error *e = giterr_last();

		croak("%d %s (%s)", rc, msg, e ? e->message : "unknown");
	}
}

SV *new()
{
	git_odb *odb;
	SV *ref, *self;
	int rc = git_odb_new(&odb);
	croak_if_err(rc, "git_odb_new");

	ref = newSViv((IV)odb);
	self = newRV_noinc(ref);
	sv_bless(self, gv_stashpv("PublicInbox::Gcf2", GV_ADD));
	SvREADONLY_on(ref);

	return self;
}

static git_odb *odb_ptr(SV *self)
{
	return (git_odb *)SvIV(SvRV(self));
}

void DESTROY(SV *self)
{
	git_odb_free(odb_ptr(self));
}

/* needs "$GIT_DIR/objects", not $GIT_DIR */
void add_alternate(SV *self, const char *objects_path)
{
	int rc = git_odb_add_disk_alternate(odb_ptr(self), objects_path);
	croak_if_err(rc, "git_odb_add_disk_alternate");
}

#define CAPA(v) (sizeof(v) / sizeof((v)[0]))

/*
 * returns true on success, false on failure
 * this requires an unabbreviated git OID
 */
int cat_oid(SV *self, int fd, SV *oidsv)
{
	/*
	 * adjust when libgit2 gets SHA-256 support, we return the
	 * same header as git-cat-file --batch "$OID $TYPE $SIZE\n"
	 */
	char hdr[GIT_OID_HEXSZ + sizeof(" commit 18446744073709551615")];
	struct iovec vec[3];
	size_t nvec = CAPA(vec);
	git_oid oid;
	git_odb_object *object = NULL;
	int rc, err = 0;
	STRLEN oidlen;
	char *oidptr = SvPV(oidsv, oidlen);

	/* same trailer as git-cat-file --batch */
	vec[2].iov_len = 1;
	vec[2].iov_base = "\n";

	rc = git_oid_fromstrn(&oid, oidptr, oidlen);
	if (rc == GIT_OK)
		rc = git_odb_read(&object, odb_ptr(self), &oid);
	if (rc == GIT_OK) {
		vec[0].iov_base = hdr;
		vec[1].iov_base = (void *)git_odb_object_data(object);
		vec[1].iov_len = git_odb_object_size(object);

		git_oid_nfmt(hdr, GIT_OID_HEXSZ, git_odb_object_id(object));
		vec[0].iov_len = GIT_OID_HEXSZ +
				snprintf(hdr + GIT_OID_HEXSZ,
					sizeof(hdr) - GIT_OID_HEXSZ,
					" %s %zu\n",
					git_object_type2string(
						git_odb_object_type(object)),
					vec[1].iov_len);
	} else { /* caller retries */
		nvec = 0;
	}
	while (nvec && !err) {
		ssize_t w = writev(fd, vec + CAPA(vec) - nvec, nvec);

		if (w > 0) {
			size_t done = 0;
			size_t i;

			for (i = CAPA(vec) - nvec; i < CAPA(vec); i++) {
				if (w >= vec[i].iov_len) {
					/* fully written vec */
					w -= vec[i].iov_len;
					done++;
				} else { /* partially written vec */
					char *p = vec[i].iov_base;
					vec[i].iov_base = p + w;
					vec[i].iov_len -= w;
					break;
				}
			}
			nvec -= done;
		} else if (w < 0) {
			err = errno;
			switch (err) {
			case EAGAIN: {
				struct pollfd pfd;
				pfd.events = POLLOUT;
				pfd.fd = fd;
				poll(&pfd, 1, -1);
			}
				/* fall-through */
			case EINTR:
				err = 0;
			}
		} else { /* w == 0 */
			err = ENOSPC;
		}
	}
	if (object)
		git_odb_object_free(object);
	if (err)
		croak("writev error: %s", strerror(err));

	return rc == GIT_OK;
}
