Run the RBS Resolver deploy script to release the current working-tree files to LWPRODAPP-009.

Execute this PowerShell command and stream the output:

```powershell
powershell -ExecutionPolicy Bypass -File "D:\Projects\RBSResolver\scripts\deploy.ps1"
```

Report the final status line from the script output (green "Deployment complete" or the warning if the health check timed out).
