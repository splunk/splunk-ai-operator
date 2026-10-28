#!/usr/bin/env python3
"""Fail if an image contains non-PIE ELF executables (PSB SEC-RUN-ASLR), then smoke-test its entrypoint."""
import signal
import struct
import subprocess
import sys
import tarfile

ET_EXEC, ET_DYN = 2, 3


def elf_type(head):
    if len(head) < 18 or head[:4] != b"\x7fELF" or head[5] not in (1, 2):
        return None
    return struct.unpack_from("<H" if head[5] == 1 else ">H", head, 16)[0]


def scan(image):
    container = subprocess.run(["docker", "create", image], check=True,
                               stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()
    try:
        export = subprocess.Popen(["docker", "export", container], stdout=subprocess.PIPE)
        non_pie, dyn = [], 0
        with tarfile.open(fileobj=export.stdout, mode="r|") as tar:
            for member in tar:
                if member.isreg():
                    kind = elf_type(tar.extractfile(member).read(18))
                    if kind == ET_EXEC:
                        non_pie.append(member.name)
                    elif kind == ET_DYN:
                        dyn += 1
        if export.wait() != 0:
            sys.exit("docker export failed for %s" % image)
    finally:
        subprocess.run(["docker", "rm", "-f", container], stdout=subprocess.DEVNULL, check=False)
    return sorted(non_pie), dyn


def main():
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda signum, _frame: sys.exit(128 + signum))
    if len(sys.argv) != 2:
        sys.exit("usage: %s IMAGE" % sys.argv[0])
    image = sys.argv[1]
    non_pie, dyn = scan(image)
    if non_pie:
        sys.exit("%s contains non-PIE executables:\n  %s" % (image, "\n  ".join(non_pie)))
    smoke = subprocess.run(["docker", "run", "--rm", image, "--help"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if smoke.returncode != 0:
        sys.exit("%s entrypoint failed with --help (exit %d):\n%s" % (image, smoke.returncode, smoke.stdout[-2000:]))
    print("%s: no non-PIE executables (%d position-independent ELF files); entrypoint starts" % (image, dyn))


if __name__ == "__main__":
    main()
