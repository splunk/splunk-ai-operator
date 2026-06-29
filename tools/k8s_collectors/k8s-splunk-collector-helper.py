from __future__ import print_function
import os
import sys, getopt
import subprocess

def executeKubectlCommand(args):
    result = subprocess.run(["kubectl"] + args, shell=False, capture_output=True, text=True)
    return result.stdout


def runAndCollectDiag(collectDir, podDiagsDir, pod):
    output = executeKubectlCommand(["exec", "--stdin", pod, "--", "/opt/splunk/bin/splunk", "diag"])
    for line in output.splitlines():
        words = line.split()
        if len(words) > 4 and "Splunk diagnosis file created:" in line:
            #Extract diag file name and full path
            diagFileFullPath = words[4]
            diagFile = ""
            dirs = diagFileFullPath.split('/')
            if len(dirs) >= 2 and len(dirs[3]) > 0:
                diagFile = dirs[3]

            #Copy the diag over
            dest = os.path.join(collectDir, podDiagsDir, diagFile)
            executeKubectlCommand(["cp", "%s:%s" % (pod, diagFileFullPath), dest])

            #Delete the diag
            executeKubectlCommand(["exec", "--stdin", pod, "--", "rm", "-rf", diagFileFullPath])

def main(argv):
    #Define required variables
    collectDiag = ''
    collectDir = ''
    podLogsDir = "pod_data/logs"
    podDiagsDir = "pod_data/diags"

    try:
        opts, args = getopt.getopt(argv,"d:f:",["diag=","folder="])
    except getopt.GetoptError:
        print ("Use the format collect_logs_and_diags.py -d <diag> -f <collectFolder>")
        sys.exit(2)
    for opt, arg in opts:
        if opt == '-h':
            print ("Use the format collect_logs_and_diags.py -d <diag> -f <collectFolder>")
            sys.exit()
        elif opt in ("-d", "--diag"):
            collectDiag = arg
        elif opt in ("-f", "--folder"):
            collectDir = arg

    # Collect logs from the operator
    operator_log = os.path.join(collectDir, podLogsDir, "operator.log")
    with open(operator_log, "w") as f:
        f.write(executeKubectlCommand(["logs", "deployment/splunk-ai-operator-controller-manager", "manager"]))

    splunk_log = os.path.join(collectDir, podLogsDir, "splunkEnterprisePods.log")
    with open(splunk_log, "w") as f:
        f.write(executeKubectlCommand(["logs", "-l", "app.kubernetes.io/managed-by=splunk-operator", "--tail", "-1"]))

    output = executeKubectlCommand(["get", "pods"])
    for line in output.splitlines():
        words = line.split()
        if "splunk" in words[0]:
            pod = words[0]

            #ensure container is specified for the operator
            if "operator" in pod:
                pod_log = os.path.join(collectDir, podLogsDir, pod + ".log")
                with open(pod_log, "w") as f:
                    f.write(executeKubectlCommand(["logs", pod, "-c", "manager"]))
                continue

            # Collect logs from pod
            pod_log = os.path.join(collectDir, podLogsDir, pod + ".log")
            with open(pod_log, "w") as f:
                f.write(executeKubectlCommand(["logs", pod]))

            # Collect diag and save diag from all Splunk Instances
            if collectDiag == "true":
                runAndCollectDiag(collectDir, podDiagsDir, pod)

if __name__ == "__main__":
    main(sys.argv[1:])