# Sends the docker commands metacheck sent (calls.jsonl, from capture.R)
# through the guard's checks, and checks that the guard still refuses what it
# must. Run as root in a container where /srv/metacheck-sandbox is the capture's.
import contextlib, io, json, os, sys
from importlib.machinery import SourceFileLoader

guard = SourceFileLoader("guard", "/guard/metacheck-sandbox").load_module()
JOB = "12345678-1234-1234-1234-123456789abc"


def check(args):
    """('ok', command) or ('refused', reason)."""
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            if guard.is_install(args):
                cmd, folder = guard.check_install(JOB, args)
            else:
                cmd = guard.check_run(JOB, args)
        return "ok", cmd
    except SystemExit:
        return "refused", err.getvalue().strip()


failures = 0
calls = [json.loads(l) for l in open("/out/calls.jsonl")]
for args in calls:
    # the install folders were deleted when the install ended: made again, with
    # the install script metacheck wrote
    for i, a in enumerate(args):
        if a == "-v":
            src = args[i + 1].rsplit(":", 1)[0]
            os.makedirs(src, exist_ok=True)
            for f in ("install.R", "install.sh"):
                if args[-1].endswith(f):
                    with open("/out/" + f) as fh, open(os.path.join(src, f), "w") as out:
                        out.write(fh.read())
    status, res = check(args[1:])
    kind = "install " + args[-1] if guard.is_install(args[1:]) else "run " + args[-1]
    print("%-8s %s" % (status, kind))
    if status != "ok":
        failures += 1
        print("    ", res)
    else:
        print("    ", " ".join(res[2:]))

# What must still be refused, as changes of a run metacheck sent
run = calls[3][1:]                      # an R run in "Analysis (final)"


def changed(old, new):
    out = list(run)
    i = out.index(old)
    out[i + 1] = new
    return out


must_refuse = {
    "working folder with ..": changed("-w", "/sandbox/../etc"),
    "working folder outside /sandbox": changed("-w", "/etc"),
    "another environment variable": changed("-e", "LD_PRELOAD=/sandbox/x.so"),
    "PWD outside /sandbox": changed("-e", "PWD=/etc"),
    "the root user": changed("--user", "0:0"),
    "the internet": changed("--network", "bridge"),
    "another tmpfs": changed("--tmpfs", "/tmp:suid"),
    "a ulimit that is not a number": changed("--ulimit", "core=1;rm"),
    "a folder outside the job": changed("-v", "/etc:/sandbox"),
    "another command": run[:-2] + ["sh", run[-1]],
}
for what, args in must_refuse.items():
    status, res = check(args)
    print("%-8s (must be refused) %s" % (status, what))
    if status != "refused":
        failures += 1
pp = [a for a in calls[5] if a.startswith("PYTHONPATH=")]
print("PYTHONPATH of the Python run in a subfolder:", pp)
print("FAILURES:", failures)
sys.exit(1 if failures else 0)
