"""Project only the two foundation units' systemd credentials into private /run custody."""

import argparse
import os
import stat
import struct
from contextlib import ExitStack

UNITS = ("atrium-resolver", "atrium-device-registration")
DEVICE = frozenset(("device-ca", "device-ca-key", "registration-cert", "registration-key"))
NATIVE = frozenset(("native-ca", "native-client-cert", "native-client-key", "native-jwks"))
MODEL = frozenset(("model-management",))
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def source_metadata(descriptor, *, directory):
    metadata = os.fstat(descriptor)
    permission = 5 if directory else 4
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    # Linux reports the named-user ACL mask in the group mode bits. Only root
    # and this service UID may read the immutable systemd input; not its group.
    acl = struct.pack("<I", 2) + b"".join(
        struct.pack("<HHI", tag, mode, identity)
        for tag, mode, identity in (
            (1, permission, 0xFFFFFFFF),
            (2, permission, os.geteuid()),
            (4, 0, 0xFFFFFFFF),
            (16, permission, 0xFFFFFFFF),
            (32, 0, 0xFFFFFFFF),
        )
    )
    if (
        not kind(metadata.st_mode)
        or metadata.st_uid != 0
        or metadata.st_gid != 0
        or stat.S_IMODE(metadata.st_mode) != (0o550 if directory else 0o440)
        or (not directory and metadata.st_nlink != 1)
        or not os.fstatvfs(descriptor).f_flag & os.ST_RDONLY
        or os.getxattr(descriptor, "system.posix_acl_access") != acl
    ):
        raise ValueError("invalid systemd credential custody")


def private_metadata(descriptor, *, directory):
    metadata = os.fstat(descriptor)
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (
        not kind(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != (0o700 if directory else 0o400)
        or (not directory and metadata.st_nlink != 1)
    ):
        raise ValueError("invalid private projection custody")


def project(unit, names):
    selected = frozenset(names)
    if (
        os.geteuid() == 0
        or unit not in UNITS
        or len(names) != len(selected)
        or not DEVICE <= selected <= DEVICE | NATIVE | MODEL
        or (selected & NATIVE and not NATIVE <= selected)
        or (unit != "atrium-resolver" and selected != DEVICE)
    ):
        raise ValueError("invalid credential selection")
    with ExitStack() as descriptors:
        def opened(path, flags, *, parent=None, mode=0o400):
            descriptor = os.open(path, flags, mode, dir_fd=parent)
            descriptors.callback(os.close, descriptor)
            return descriptor

        run = opened("/run", DIRECTORY_FLAGS)
        credentials = opened("credentials", DIRECTORY_FLAGS, parent=run)
        source = opened(unit + ".service", DIRECTORY_FLAGS, parent=credentials)
        source_metadata(source, directory=True)
        target = opened(unit + "-credentials", DIRECTORY_FLAGS, parent=run)
        private_metadata(target, directory=True)
        if os.listdir(target):
            raise ValueError("projection directory is not empty")

        os.mkdir(".pending", 0o700, dir_fd=target)
        pending = opened(".pending", DIRECTORY_FLAGS, parent=target)
        created = []
        published = False
        try:
            private_metadata(pending, directory=True)
            for name in sorted(selected):
                limit = 4096 if name == "model-management" else 32768
                with ExitStack() as files:
                    reader = os.open(
                        name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=source,
                    )
                    files.callback(os.close, reader)
                    source_metadata(reader, directory=False)
                    with os.fdopen(os.dup(reader), "rb") as stream:
                        material = stream.read(limit + 1)
                    if not material or len(material) > limit:
                        raise ValueError("invalid credential size")
                    writer = os.open(
                        name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                        0o400, dir_fd=pending,
                    )
                    created.append(name)
                    files.callback(os.close, writer)
                    private_metadata(writer, directory=False)
                    with os.fdopen(os.dup(writer), "wb") as stream:
                        stream.write(material)
                        stream.flush()
                        os.fsync(stream.fileno())
            os.fsync(pending)
            os.rename(".pending", "material", src_dir_fd=target, dst_dir_fd=target)
            published = True
            os.fsync(target)
        finally:
            if not published:
                for name in created:
                    os.unlink(name, dir_fd=pending)
                os.rmdir(".pending", dir_fd=target)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("unit", choices=UNITS)
    parser.add_argument("credentials", nargs="+", choices=sorted(DEVICE | NATIVE | MODEL))
    args = parser.parse_args()
    try:
        project(args.unit, args.credentials)
    except (OSError, ValueError):
        raise SystemExit("atrium_credential_projection_rejected") from None


if __name__ == "__main__":
    main()
