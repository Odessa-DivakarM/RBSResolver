Run the RBS Resolver deploy script to release the current working-tree files to LWPRODAPP-009.

Execute this PowerShell command and stream the output:

```powershell
powershell -ExecutionPolicy Bypass -File "D:\Projects\RBSResolver\scripts\deploy.ps1"
```

Report the final status line from the script output and its exit code: green "Deployment complete" (exit 0), or red "Deployment FAILED: …" (exit 1). The script stops at the first failure. On a failure also report the lines that follow it: whether the site was changed, which files were copied, and any "THE SITE IS DOWN" line. That one needs the user to act now: they must start the app pool on the server by hand.
