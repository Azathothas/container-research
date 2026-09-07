/* short_write: what does archive_write_data() return when the destination
 * filesystem is full?
 *
 * The paper under review read dwarfs' "archive_error: short write: -20 != N"
 * as errno ENODEV. This reproduces the same value through the same API to show
 * that -20 is libarchive's ARCHIVE_WARN and that the underlying errno is
 * ENOSPC.
 *
 * Build: gcc -O2 -o short_write short_write.c -larchive
 * Run:   short_write <dir-on-a-small-filesystem> <bytes>
 */
#include <archive.h>
#include <archive_entry.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s DIR BYTES\n", argv[0]);
		return 2;
	}
	size_t n = strtoul(argv[2], NULL, 10);
	char *buf = malloc(n);
	if (!buf)
		return 2;
	memset(buf, 'x', n);

	char path[4096];
	snprintf(path, sizeof(path), "%s/payload.bin", argv[1]);

	struct archive *a = archive_write_disk_new();
	/* the same option set dwarfs' filesystem_extractor uses for open_disk */
	archive_write_disk_set_options(a, ARCHIVE_EXTRACT_NO_AUTODIR |
					      ARCHIVE_EXTRACT_OWNER |
					      ARCHIVE_EXTRACT_PERM |
					      ARCHIVE_EXTRACT_TIME |
					      ARCHIVE_EXTRACT_UNLINK);

	struct archive_entry *e = archive_entry_new();
	archive_entry_set_pathname(e, path);
	archive_entry_set_filetype(e, AE_IFREG);
	archive_entry_set_perm(e, 0644);
	archive_entry_set_size(e, (la_int64_t)n);

	printf("ARCHIVE_OK=%d ARCHIVE_RETRY=%d ARCHIVE_WARN=%d "
	       "ARCHIVE_FAILED=%d ARCHIVE_FATAL=%d\n",
	       ARCHIVE_OK, ARCHIVE_RETRY, ARCHIVE_WARN, ARCHIVE_FAILED,
	       ARCHIVE_FATAL);

	int rc = archive_write_header(a, e);
	printf("archive_write_header -> %d\n", rc);

	la_ssize_t rv = archive_write_data(a, buf, n);
	printf("archive_write_data(%zu) -> %zd\n", n, (ssize_t)rv);
	if ((size_t)rv != n)
		printf("dwarfs would now throw: archive_error: short write: "
		       "%zd != %zu\n",
		       (ssize_t)rv, n);
	printf("archive_errno        -> %d\n", archive_errno(a));
	printf("archive_error_string -> %s\n",
	       archive_error_string(a) ? archive_error_string(a) : "(none)");

	archive_entry_free(e);
	archive_write_free(a);
	return 0;
}
