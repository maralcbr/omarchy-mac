# SPDX-License-Identifier: MIT
"""Bounded image writes and diagnostic timings outside the contract journal."""

from contextlib import contextmanager
import fcntl
import hashlib
import json
import logging
import os
import re
import stat
import struct
import sys
import time

CHUNK_BYTES = 4 * 1024 * 1024
WRITE_VERIFICATION = "source-sha256-write-flushed-v1"
PARTITION = re.compile(r"^disk[0-9]+s[0-9]+$")


@contextmanager
def timing(phase, **fields):
    start = time.monotonic()
    outcome = "failed"
    try:
        yield
        outcome = "completed"
    finally:
        record = dict(phase=phase, seconds=time.monotonic() - start,
                      outcome=outcome, **fields)
        logging.info("PERFORMANCE %s", json.dumps(record, sort_keys=True))
        path = os.environ.get("OMARCHY_PERFORMANCE_LOG")
        if path:
            try:
                fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT
                             | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "a") as stream:
                    stream.write(json.dumps(record, sort_keys=True) + "\n")
            except OSError:
                logging.warning("Performance record could not be saved")


def flush_device(target):
    target.flush()
    fd = target.fileno()
    if sys.platform == "darwin" and stat.S_ISCHR(os.fstat(fd).st_mode):
        # sys/disk.h: _IOW('d', 22, dk_synchronize_t); no barrier-only option.
        fcntl.ioctl(fd, 0x80186416, struct.pack("=QQI4x", 0, 0, 0))
    else:
        os.fsync(fd)


def open_target(name):
    if not PARTITION.fullmatch(name):
        raise ValueError("invalid image target")
    fd = os.open("/dev/r" + name, os.O_RDWR | os.O_NOFOLLOW)
    if not stat.S_ISCHR(os.fstat(fd).st_mode):
        os.close(fd)
        raise ValueError("image target is not a raw device")
    return os.fdopen(fd, "r+b", buffering=0)


def write_image(package, image, info, *, opener=open_target, flush=flush_device):
    member = package.getinfo(image)
    size = member.file_size
    if (not PARTITION.fullmatch(info.name) or size <= 0 or size % 4096
            or size > info.size):
        raise ValueError("image does not fit approved partition")
    digest = hashlib.sha256()
    copied = 0
    with timing("image_write", image=image, bytes=size):
        with package.open(member) as source, opener(info.name) as target:
            while copied < size:
                chunk = source.read(min(CHUNK_BYTES, size - copied))
                if not chunk or len(chunk) > size - copied:
                    raise ValueError("image stream length changed")
                digest.update(chunk)
                remaining = memoryview(chunk)
                while remaining:
                    written = target.write(remaining)
                    if (not isinstance(written, int) or written <= 0
                            or written > len(remaining)):
                        raise OSError("image write made invalid progress")
                    remaining = remaining[written:]
                copied += len(chunk)
            # Reach EOF so the archive reader finishes its CRC validation.
            if source.read(1):
                raise ValueError("image stream exceeds declared length")
            with timing("image_flush", image=image, bytes=size):
                flush(target)
    return {
        "partition_identifier": info.name,
        "partition_uuid": info.uuid.lower(),
        "partition_size_bytes": info.size,
        "installed_bytes": copied,
        "content_sha256": digest.hexdigest(),
        "verification": WRITE_VERIFICATION,
    }


def hash_target(opener, name, size):
    digest = hashlib.sha256()
    remaining = size
    with timing("image_readback", partition=name, bytes=size):
        with opener(name) as target:
            while remaining:
                chunk = target.read(min(CHUNK_BYTES, remaining))
                if not chunk or len(chunk) > remaining:
                    raise ValueError("installed image is truncated")
                digest.update(chunk)
                remaining -= len(chunk)
    return digest.hexdigest()
