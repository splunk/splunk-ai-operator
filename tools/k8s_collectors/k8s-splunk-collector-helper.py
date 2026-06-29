from __future__ import print_function
import os
import sys, getopt
import subprocess


def executeKubectlCommand(args, stdout=None):
    """Run kubectl with an argv list. Raises RuntimeError on non-zero exit.

    If stdout is an open file handle, kubectl's output is streamed directly
    into it (no in-memory buffering). Otherwise returns captured output as str.
    """
    cmd = ["kubectl"] + args
    if stdout is not None:
        proc = subprocess.Popen(cmd, shell=False, stdout=stdout,
                                stderr=subprocess.PIPE, universal_newlines=True)
        _, stderr = proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError("kubectl %s failed (rc=%d): %s" % (" ".join(args), proc.returncode, stderr.strip()))
        return ""
    else:
        proc = subprocess.Popen(cmd, shell=False, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, universal_newlines=True)
        stdout_data, stderr = proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError("kubectl %s failed (rc=%d): %s" % (" ".join(args), proc.returncode, stderr.strip()))
        return stdout_data


def runAndCollectDiag(collectDir, podDiagsDir, pod):
    output = executeKubectlCommand(["exec", "--stdin", pod, "--", "/opt/splunk/bin/splunk", "diag"])
    for line in output.splitlines():
        words = line.split()
        if len(words) > 4 and "Splunk diagnosis file created:" in line:
            diagFileFullPath = words[4]
            diagFile = os.path.basename(diagFileFullPath)
            if not diagFile:
                print("WARNING: could not extract diag filename from path: %s" % diagFileFullPath)
                continue

            dest = os.path.join(collectDir, podDiagsDir, diagFile)
            executeKubectlCommand(["cp", "%s:%s" % (pod, diagFileFullPath), dest])
            executeKubectlCommand(["exec", "--stdin", pod, "--", "rm", "-rf", diagFileFullPath])


def main(argv):
    collectDiag = ''
    collectDir = ''
    podLogsDir = "pod_data/logs"
    podDiagsDir = "pod_data/diags"

    script = os.path.basename(__file__)
    usage = "Usage: %s -f <collectFolder> [-d true]" % script

    try:
        opts, args = getopt.getopt(argv, "hd:f:", ["help", "diag=", "folder="])
    except getopt.GetoptError:
        print(usage)
        sys.exit(2)
    for opt, arg in opts:
        if opt in ("-h", "--help"):
            print(usage)
            sys.exit()
        elif opt in ("-d", "--diag"):
            collectDiag = arg
        elif opt in ("-f", "--folder"):
            collectDir = arg

    operator_log = os.path.join(collectDir, podLogsDir, "operator.log")
    with open(operator_log, "w") as f:
        executeKubectlCommand(["logs", "deployment/splunk-ai-operator-controller-manager", "manager"], stdout=f)

    splunk_log = os.path.join(collectDir, podLogsDir, "splunkEnterprisePods.log")
    with open(splunk_log, "w") as f:
        executeKubectlCommand(["logs", "-l", "app.kubernetes.io/managed-by=splunk-operator", "--tail", "-1"], stdout=f)

    output = executeKubectlCommand(["get", "pods"])
    for line in output.splitlines():
        words = line.split()
        if words and "splunk" in words[0]:
            pod = words[0]

            if "operator" in pod:
                pod_log = os.path.join(collectDir, podLogsDir, pod + ".log")
                with open(pod_log, "w") as f:
                    executeKubectlCommand(["logs", pod, "-c", "manager"], stdout=f)
                continue

            pod_log = os.path.join(collectDir, podLogsDir, pod + ".log")
            with open(pod_log, "w") as f:
                executeKubectlCommand(["logs", pod], stdout=f)

            if collectDiag == "true":
                runAndCollectDiag(collectDir, podDiagsDir, pod)


if __name__ == "__main__":
    main(sys.argv[1:])
